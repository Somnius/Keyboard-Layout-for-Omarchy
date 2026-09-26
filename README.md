# Keyboard Layout for Omarchy

An [Omarchy](https://omarchy.org/) shell plugin that shows your active keyboard layout in the bar, switches layouts on demand, and manages the layout part of `~/.config/hypr/input.lua` for you. It works with any language, and with up to four layouts at once.

The bar label is the active layout's short code (`EN`, `GR`, `DE`, `PT`…):

| On the bar label | Does |
|---|---|
| **Left-click** | Opens the settings panel |
| **Right-click** | Switches to the next layout |
| **Scroll down / up** | Switches to the next / previous layout |
| **Middle-click** | Goes back to the main layout (layout 1) |
| **Hover** | Shows a tooltip with the full keymap name (`Greek (polytonic)`) |

<img width="930" alt="Keyboard Layout panel" src="preview.png" />

The panel is laid out in columns: **Layouts**, **Switch key + Display**, and **Backups**. That keeps it short enough for small screens. On a narrow screen the columns wrap to two or one, and the panel scrolls only if nothing else fits.

## Features

- **Any layouts, with variants.** Choose up to four (xkb's limit) from xkb's own table of 750+ layout/variant pairs, e.g. `us`, `gr(polytonic)`, `de(nodeadkeys)`. Each picker is searchable, and rows can be reordered or removed. Layout 1 is the *main* layout.
- **Warns about passwords.** If layout 1 is anything other than English (US) `us`, the panel shows a warning, and Apply asks you to confirm. Password prompts that start on the main layout, such as hyprlock or a new session, type with that layout's characters, so a password you normally type on English (US) may be rejected.
- **Switches every keyboard you type on, together.** Receivers, laptop keyboards and macro pads each appear as separate "keyboards" in Hyprland. The plugin sets all of the real ones to the same layout in a single `hyprctl --batch` call, so they can't drift apart. Virtual and ACPI "keyboards" (fcitx5's injector, power button, lid switch) are never touched.
- **The label follows the keyboard you actually type on.** It takes the name from Hyprland's `activelayout` event, the same logic as Omarchy's own widget, and updates instantly from the event without starting any process.
- **More switch keys:** Caps Lock, Shift+Caps, Alt+Caps, Alt+Shift, Left Alt+Left Shift, Ctrl+Shift, Left Ctrl+Left Shift, Ctrl+Alt, both Shifts, both Alts, Menu, Right Ctrl, Right Alt, Right Shift, Scroll Lock. There's also **None**, for switching only from the bar or a Hyprland keybinding. Super and Space combinations are never offered because Omarchy uses them. A `grp:` option you set by hand is shown as *Custom* and kept.
- **Caps LED indicator.** With Caps Lock as the switch key, the LED can light while you're on any layout other than the main one (`grp_led:caps`).
- **Keeps your other `kb_options`.** Only the layout-switch options (`grp:*`, `grp_led:*`) are ever rewritten. `compose:ralt`, `caps:escape` and the rest stay as they are.
- **Edits `input.lua` precisely.** Lua comments and strings are understood, so a commented example like `-- kb_variant = "intl"` is never mistaken for a real setting. Only the live values change. Your comments and layout stay untouched, and an Apply that changes nothing doesn't write anything.
- **Backups and restore.** `input.lua` is copied to a private folder before every Apply or Restore. **Back up now** does the same whenever you like, and the newest 10 are kept. **Open folder** shows them in your default file manager. Any backup, including the original `input.lua.bak.*` from earlier versions, can be restored from the panel or over IPC. See [docs/BACKUPS.md](docs/BACKUPS.md).
- **Optional toast (off by default).** A short notice at the **top center** of the focused screen, just below the bar, whenever the layout changes: from the switch key, the bar or IPC. It never takes focus or clicks.
- **Optional accent label (off by default).** The bar label takes your theme's accent colour while you're off the main layout.
- **Placement choice.** On first run the plugin asks whether the widget lives in the `center` section (right after the clock) or on the `right`. Moving it applies live, with no shell restart. The left section is never offered.
- **Size-limited, validated input.** `input.lua`, the plugin config, `hyprctl` device data, `xkbcli` output and the backup list are read with byte limits and checked for the expected shape. Anything malformed is rejected and never replaces the last good state.

## Install

```sh
omarchy plugin add https://github.com/Somnius/Keyboard-Layout-for-Omarchy.git --enable
```

The widget starts on the right side of the bar. The first-run panel asks whether to keep it there or move it next to the clock.

### From a local checkout (development)

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/lef.keyboard-layout
omarchy-shell shell rescanPlugins
```

> **Dev loop caveat:** Quickshell's file watcher doesn't follow symlinks, and the service is `keepLoaded`. After editing, run `omarchy restart shell`.

Validate the manifest with:

```sh
omarchy plugin validate "$PWD"
```

## Usage

1. Left-click the label to open the panel.
2. Under **Layouts**, pick layout 1 (the main one) and add up to three more. Type in a picker to search, e.g. `greek`, `polytonic` or `de(`.
3. Under **Switch key**, choose how to cycle layouts, and turn the Caps LED on or off.
4. Press **Apply & reload Hyprland**. The plugin backs up `input.lua`, writes only the changed values, and reloads Hyprland.

To undo, use **Restore** on any row under **Backups**. Use **Back up now** before editing `input.lua` by hand, and **Open folder** to see the backup files.

## Configuration

Everything is set from the panel. Details on every key and file are in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

**`~/.config/hypr/input.lua`**. Changed only when you press Apply or Restore:

| Key | Written as | Example |
|---|---|---|
| `kb_layout` | comma-separated layouts, 1–4 | `"us,gr"` |
| `kb_variant` | variants lined up with the layouts. Only written when some layout has a variant, or the key already exists. | `",polytonic"` |
| `kb_options` | your other options, followed by the chosen `grp:` switch key and optionally `grp_led:caps` | `"compose:ralt,grp:caps_toggle,grp_led:caps"` |

**`~/.config/omarchy/keyboard-layout/config.json`**. The plugin's own settings:

| Key | Values | Default |
|---|---|---|
| `asked` | boolean. Set once you answer the placement question. | `false` |
| `placement` | `center` \| `right` | `right` |
| `toast` | boolean. Top-center toast on layout change. | `false` |
| `highlight` | boolean. Accent label while off the main layout. | `false` |

Backups go to `~/.config/omarchy/keyboard-layout/backups/`.

## IPC & keybindings

```sh
omarchy-shell lef.keyboard-layout status            # full JSON state
omarchy-shell lef.keyboard-layout next              # next layout (all keyboards)
omarchy-shell lef.keyboard-layout prev              # previous layout
omarchy-shell lef.keyboard-layout set 0             # by index…
omarchy-shell lef.keyboard-layout set gr            # …by layout…
omarchy-shell lef.keyboard-layout set 'gr(polytonic)'  # …or by layout(variant)
omarchy-shell lef.keyboard-layout toast on          # or off
omarchy-shell lef.keyboard-layout highlight on      # or off
omarchy-shell lef.keyboard-layout backup            # back up input.lua now
omarchy-shell lef.keyboard-layout backups           # JSON list of backups
omarchy-shell lef.keyboard-layout folder            # open the backups folder in the file manager
omarchy-shell lef.keyboard-layout restore <id>      # restore one, then reload Hyprland
omarchy-shell lef.keyboard-layout place center      # or right; applies live
omarchy-shell lef.keyboard-layout toggle            # open/close the panel (also open, close)
```

Hyprland binding example (`~/.config/hypr/bindings.lua`). This pairs well with the **None** switch key:

```lua
o.bind("SUPER + ALT + K", "Next keyboard layout", "omarchy-shell lef.keyboard-layout next")
o.bind("SUPER + ALT + J", "Main keyboard layout", "omarchy-shell lef.keyboard-layout set 0")
```

Every command, its return values and its edge cases are in [docs/IPC.md](docs/IPC.md).

## How it works

A service loaded once per shell holds all the state and owns the IPC target. It reads `input.lua` through `InputLua.pl` (a size-limited parser that understands Lua comments), follows Hyprland's `activelayout` and `configreloaded` events, and switches with `hyprctl --batch`. The bar widget and panel only display that state. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture: data flow, safety measures and why each piece exists.

## Tests

```sh
tests/run.sh
```

This runs the QML logic suite (`tests/tst_ServiceLogic.qml`, through Qt 6's `qmltestrunner`, offscreen) and the Perl I/O suites (`tests/input_lua.t`, `tests/security_io.t`, through `prove`).

## External dependencies

All ship with Omarchy: `hyprctl`, `xkbcli`, Perl (core modules only: `JSON::PP`, `Encode`, `Fcntl`, `POSIX`), the `omarchy` CLI, and `bash`. The tests also use Qt 6's `qmltestrunner` and `prove`.

## Upgrading from 1.1.x

- Layout rows replace the old *Primary / Second* pair. Existing settings are read as they are.
- Switch keys are now stored as xkb option names (`grp:caps_toggle`). The IPC `status` output reports `hotkey` in that form, and adds `layouts` as `layout(variant)` specs.
- The one-time `input.lua.bak.<timestamp>` next to `input.lua` is no longer created. Existing ones are kept, listed and restorable. New backups go to the rotating backup folder.
- Moving the widget no longer restarts the shell or reloads Hyprland.

## Uninstall

```sh
omarchy plugin remove lef.keyboard-layout
```

If you installed via symlink, remove the symlink instead. Your last-applied `input.lua` settings stay in place. Remove `~/.config/omarchy/keyboard-layout/` too if you don't want to keep the backups.

## License

[MIT](LICENSE)
