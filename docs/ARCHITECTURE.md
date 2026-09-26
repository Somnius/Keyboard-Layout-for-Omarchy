# Architecture

This page covers how the plugin is put together, how data moves through it, and the reasons behind the design decisions that aren't obvious.

## Files

| File | Kind | Role |
|---|---|---|
| `manifest.json` | manifest | Declares a `service` (kept loaded) and a `bar-widget`. |
| `Service.qml` | service | Holds all the state, starts every process, listens to Hyprland events, and owns the IPC target. Loaded once per shell. |
| `ServiceLogic.js` | pure JS library | Parsers, validators and decision functions, with no I/O. Everything the service decides is tested here. |
| `BarWidget.qml` | bar widget | The label on the bar, mouse handling, and hosting the panel. One instance per bar that carries it. |
| `Panel.qml` | panel | The settings panel: a top strip plus three columns. Keeps an editable draft of the settings. |
| `Toast.qml` | overlay window | The optional top-center toast. |
| `InputLua.pl` | helper | The only code that reads or writes `input.lua`. Subcommands: `read`, `write`, `backup`, `backups`, `restore`. `write` takes the complete planned `kb_options` plus the value it was planned from, and refuses if the file has changed since. |
| `BoundedRead.pl` | helper | Reads a regular file with a byte limit, used for `config.json`. |
| `BoundedExec.pl` | helper | Runs a command and passes on its stdout only if it stays under a byte limit, exits 0 and is valid UTF-8. Used for `hyprctl`, `xkbcli` and the backup list. |

## Data flow

```
                ┌──────────── Hyprland socket2 events ────────────┐
                │ activelayout>>kbd,Keymap   configreloaded>>      │
                ▼                                                  │
  ┌─────────────────────────── Service.qml ───────────────────────┴──┐
  │ label ← event data (instant, no process)                         │
  │ index ← hyprctl -j devices   (merged: 150 ms after events)       │
  │ layouts/options ← InputLua.pl read  (on input.lua change)        │
  │ catalog ← xkbcli list --load-exotic (once)                       │
  │ effective ← hyprctl getoption kb_layout/variant/options          │
  │ settings ← config.json (BoundedRead.pl, on change)               │
  │                                                                  │
  │ switch  → hyprctl --batch "switchxkblayout <kbd> N ; …"          │
  │ apply   → InputLua.pl write  → hyprctl reload                    │
  │ restore → InputLua.pl restore → hyprctl reload                   │
  │ backup  → InputLua.pl backup    folder → xdg-open (detached)     │
  │ place   → omarchy bar move (applies live)                        │
  │ IPC target lef.keyboard-layout                                   │
  └──────────────┬──────────────────────────────┬────────────────────┘
                 │ properties                   │ layoutSwitched signal
                 ▼                              ▼
        BarWidget.qml ── Panel.qml         Toast.qml (only while shown)
```

## Choosing the keyboard and switching

Hyprland lists every input device that has a keymap as a "keyboard". On a typical desktop that includes several USB receiver interfaces, headset control interfaces, the ACPI power button, the lid switch, and fcitx5's virtual keyboard. They all carry the same layout list, but only the keyboard you type on moves through it.

- **Reading.** Devices that nobody types on are dropped:
  - Omarchy's exclusions: `hl-virtual-keyboard`, `power-button`, `sleep-button`, `lid-switch`, `video-bus`;
  - names ending in `-hid-events`, `-extra-buttons`, `-consumer-control`, `-system-control` or `-wireless-radio-control`. These are laptop hotkey devices such as a ThinkPad's `intel-hid-events`, and receiver media interfaces. Device capability bits can't tell them apart from real keyboards.

  Among the rest, the keyboard named by the most recent `activelayout` event wins, because that is the one being typed on. Before any event, the keyboard Hyprland flags as `main` is used, and after that the highest layout index. Picking by highest index alone reads the wrong keyboard as soon as the typed keyboard wraps from its last layout back to the first. (This was a bug in 1.1.x.)
- **Switching.** `next`, `prev` and `set` first re-read the devices, so a Caps Lock toggle a moment ago can't make "next" land on the layout that is already active. They then send one `hyprctl --batch` call that sets **every** typed keyboard to the same **absolute** index. That keeps several physical keyboards in step, and it never touches the virtual and ACPI devices, which is why `switchxkblayout all` isn't used. Only keyboard names matching `^[A-Za-z0-9_.:-]+$` go into the batch string, because `;` and whitespace mean something to `--batch`.
- **Our own events.** A batch switch raises one `activelayout` per keyboard. For 500 ms after the plugin's own switch, those events update the label but don't change which keyboard counts as "typed on".
- **Merging.** The label changes from the event data immediately. One `hyprctl -j devices` read (150 ms after the last event) then updates the index. Several events in a row cause one process, not one per event.

## The `input.lua` scanner (`InputLua.pl`)

A single tokenizer serves both reading and writing, so the two can never disagree about which line is the live setting.

- Skipped: `-- line comments`, `--[[ block ]]` and `--[==[ level ]==]` comments. Strings are skipped as well: `"…"` and `'…'` with escapes, and `[[long]]` strings.
- An assignment is `identifier = "string"` in live code, for the keys `kb_layout`, `kb_variant` and `kb_options`.
- **The last live assignment wins**, the same way a later `hl.config()` call overrides an earlier one.
- Values are checked: no control characters, escapes or long-bracket strings. Layouts must match `[A-Za-z0-9_+-]{1,64}` and variants `[A-Za-z0-9_+-]{0,64}`. Every `kb_options` token must look like `name:value`. Anything else makes `read` fail (exit 11), and `write` refuses to edit the file rather than guess.

**Writing:**

1. The live values are replaced where they are, working back from the end of the file so the offsets stay valid.
2. A key that doesn't exist yet goes on its own line right after a live sibling (`kb_layout` or `kb_options`) that ends its line with a comma. That keeps it inside the same `input = { }` table, with the same indentation. Only if there is no such sibling is a separate `hl.config({ input = { … } })` block appended.
3. `kb_variant` is written only when some layout has a variant, or the key already exists (in which case it may be emptied).
4. In `kb_options`, only `grp:*` and `grp_led:*` tokens are removed. The rest are kept in their order, and the new switch key and LED option are appended.
5. If the result matches the file byte for byte, nothing is written and no backup is made.

## File safety

Every read and write of `input.lua` and of backups:

- opens with `O_NOFOLLOW` (a final symlink is never followed) and `O_NONBLOCK` (a FIFO can't hang it), then requires a regular file;
- enforces the byte limit before and while reading, and requires valid UTF-8.

Writes also:

- go to an exclusive temp file (`O_EXCL`), keep the original mode, are `fsync`ed, and are `rename`d into place atomically;
- re-read the source just before the rename and check that its bytes, inode and mode haven't changed. If they have, the write stops with exit 10 and the file is left alone;
- back up the current bytes first. If the backup fails, the write stops and `input.lua` is left untouched.

The helpers get arguments as an argument vector from QML, never through a shell. The writer checks its arguments again in Perl, independently of the JS checks.

## Settings and persistence

`config.json` is written by the service with atomic writes and read back through `BoundedRead.pl`. Unknown keys are ignored and wrong types are rejected. A rejected file never replaces the last good state; before any good state exists, the plugin falls back to defaults.

Omarchy's convention is to store settings inside `shell.json`. This plugin keeps its own small file because it has done so since 1.0, which means no migration is needed.

## Toast

`Toast.qml` is a Quickshell `PanelWindow` on the overlay layer:

- no keyboard focus, and an empty input `mask`, so clicks pass through;
- `ExclusionMode.Normal` with `exclusiveZone: 0`, so it sits below the bar instead of over it, without reserving space;
- anchored to the top edge and centred.

It is created lazily (`LazyLoader`) only while a toast is on screen, on the focused Hyprland monitor. It is shown when the service emits `layoutSwitched`, which happens only when the active keymap really changes: never at startup, and never on a refresh that finds the same layout.

## IPC ownership

The IPC target lives in the service because the service exists exactly once. Bar widgets exist once per bar and are re-created whenever they move, and a handler in the widget would compete with the one in the next copy. Widgets register themselves as panel hosts, and `open` / `toggle` go to the widget on the focused monitor.

## Panel layout

The panel uses a top strip (title, active layout, Previous/Next) and a grid of columns: Layouts / Switch key + Display / Backups. The column count is `min(3, what fits the available card width)`. The whole panel sits in a `Flickable` that only scrolls when even one column can't fit the screen height. Search dropdowns take over the keyboard while open (`PanelKeyCatcher.blocked`), and confirm dialogs handle Escape and Enter through the key catcher.
