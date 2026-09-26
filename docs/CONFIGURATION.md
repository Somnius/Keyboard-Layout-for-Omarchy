# Configuration

Everything here can be set from the panel. This page documents what the panel changes, so you can check it, script it, or edit it by hand.

## `~/.config/hypr/input.lua`

This is Omarchy's user input file. The plugin reads it whenever it changes, and writes it **only** when you press Apply or Restore.

### What is read

- The **last live** assignment of `kb_layout`, `kb_variant` and `kb_options`. Anything inside `--` or `--[[ ]]` comments or inside other strings is ignored.
- `kb_layout` may list more than four layouts, but xkb uses only the first four. The panel shows four and warns about the rest.
- `kb_variant` entries line up with the layouts. Missing entries count as empty.
- If `input.lua` doesn't exist, the plugin shows no layouts and uses defaults. The first Apply creates the file (mode `0600`).
- If the live values contain something unsafe (control characters, escapes, `[[long strings]]`, or options that aren't in `name:value` form), the plugin shows `Invalid input.lua: …` and keeps its last good reading. Apply is refused rather than risk damaging the file.

### What is written

| Key | Written | Notes |
|---|---|---|
| `kb_layout` | always | 1–4 layouts, comma-separated |
| `kb_variant` | when any layout has a variant, or the key already exists | lined up with the layouts, e.g. `",polytonic"` |
| `kb_options` | always | Your non-switch options first (unchanged, same order), then the switch key, then `grp_led:caps` if chosen |

Keys that already exist are changed where they are. A missing key is added on the line after the live `kb_layout` / `kb_options` in the same table. If there's no such line, a small `hl.config({ input = { … } })` block is appended.

### The main layout and passwords

Layout 1 is the one Hyprland starts on after a reload and in a new session, and many lock screens and password prompts (such as hyprlock) start on it. If it isn't English (US) (`us`, with no variant), a password you normally type on a US layout may produce different characters and be rejected.

For that reason the panel:

- shows a warning whenever layout 1 isn't `us`;
- asks you to confirm on Apply when the change *newly* makes a non-US layout the main one.

Keeping `us` first and switching to your other layouts with the switch key avoids the problem entirely.

### Switch keys

| Panel label | xkb option |
|---|---|
| Caps Lock | `grp:caps_toggle` |
| Shift+Caps Lock | `grp:shift_caps_toggle` |
| Alt+Caps Lock | `grp:alt_caps_toggle` |
| Alt+Shift | `grp:alt_shift_toggle` |
| Left Alt+Left Shift | `grp:lalt_lshift_toggle` |
| Ctrl+Shift | `grp:ctrl_shift_toggle` |
| Left Ctrl+Left Shift | `grp:lctrl_lshift_toggle` |
| Ctrl+Alt | `grp:ctrl_alt_toggle` |
| Both Shifts together | `grp:shifts_toggle` |
| Both Alts together | `grp:alts_toggle` |
| Menu key | `grp:menu_toggle` |
| Right Ctrl | `grp:rctrl_toggle` |
| Right Alt | `grp:toggle` |
| Right Shift | `grp:rshift_toggle` |
| Scroll Lock | `grp:sclk_toggle` |
| None (keybinding / bar only) | *(no `grp:` option)* |

- Super/Win and Space combinations (`grp:win_space_toggle`, `grp:alt_space_toggle`, …) are left out on purpose, because Omarchy binds Super+Space and similar keys.
- If `input.lua` already has a `grp:` option that isn't in this list, the panel shows it as **Custom (…) — keep**, and Apply keeps it. You can't pick a new unlisted option from the panel.
- **Caps LED** (`grp_led:caps`) is only offered with `grp:caps_toggle`. With any other key, Caps Lock still works as Caps Lock, and its LED shouldn't mean two things.

## `~/.config/omarchy/keyboard-layout/config.json`

The plugin's own settings, written by the panel and IPC (atomic write). Example:

```json
{"asked":true,"placement":"center","toast":false,"highlight":false}
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `asked` | boolean | `false` | The first-run placement question has been answered. While `false`, the panel opens by itself once. |
| `placement` | `"center"` \| `"right"` | `"right"` | Bar section. `center` means right after `omarchy.clock`. |
| `toast` | boolean | `false` | Show the top-center toast on every layout change. |
| `highlight` | boolean | `false` | Show the bar label in the accent colour while off the main layout. |

- Files from 1.1.x (without `toast` / `highlight`) are read as they are, and those settings are off.
- A key with the wrong type makes the whole file be rejected. The last good settings stay in effect, and the panel shows the error.
- The file is limited to 16 KiB.

## Backups

See [BACKUPS.md](BACKUPS.md).

## Size limits

| Input | Limit |
|---|---|
| `input.lua` | 256 KiB |
| `config.json` | 16 KiB |
| `hyprctl -j devices` output | 256 KiB, 128 keyboards |
| `xkbcli list --load-exotic` output | 512 KiB, 4096 layout rows |
| backup list | 64 KiB, 64 rows |
