# IPC reference

The target is `lef.keyboard-layout`. The plugin's service owns it, so it answers as soon as the shell is up, whether or not a bar currently shows the widget.

```sh
omarchy-shell lef.keyboard-layout <command> [argument]
```

| Command | Argument | Returns | Does |
|---|---|---|---|
| `status` | — | JSON (below) | The full current state |
| `next` | — | `ok`, or a reason | Next layout, on every typed keyboard |
| `prev` | — | `ok`, or a reason | Previous layout |
| `set` | index, layout, or `layout(variant)` | `switching to <spec>` / `unknown layout: …` | Jumps to one layout |
| `toast` | `on` \| `off` | `toast on` | Turns the top-center toast on or off (saved) |
| `highlight` | `on` \| `off` | `highlight on` | Turns the accent label on or off (saved) |
| `backup` | — | `backing up` / `busy` | Backs up `input.lua` now (skipped if unchanged since the newest backup) |
| `backups` | — | JSON list | Backups ([BACKUPS.md](BACKUPS.md)) |
| `folder` | — | `opening <path>` | Opens the backups folder in the default file manager (`xdg-open`) |
| `restore` | backup id | `restoring <id>` / reason | Restores a backup and reloads Hyprland |
| `place` | `center` \| `right` | `moving to …` | Moves the bar widget (applies live) |
| `open` / `close` / `toggle` | — | `ok` / `no bar widget` | The panel, on the focused monitor's bar |

## `set`

- `set 0` … `set 3`: by position in `kb_layout` (0 is the main layout).
- `set gr`: the first layout whose name is `gr`, unless one entry is exactly `gr` with no variant, in which case that one is chosen.
- `set 'gr(polytonic)'`: that exact layout and variant.

Anything else, including names with spaces or `;`, returns `unknown layout: …` and switches nothing.

## `status`

```json
{
  "keyboard": "cx-2.4g-wireless-receiver",
  "keyboards": ["cx-2.4g-wireless-receiver", "roccat-roccat-burst-pro-keyboard"],
  "keymap": "English (US)",
  "abbr": "EN",
  "index": 0,
  "layouts": ["us", "gr(polytonic)"],
  "options": ["compose:ralt", "grp:caps_toggle", "grp_led:caps"],
  "hotkey": "grp:caps_toggle",
  "led": true,
  "toast": false,
  "highlight": false,
  "placement": "center",
  "askedState": 1,
  "lastError": ""
}
```

- `keyboard` is the keyboard being typed on (the one the latest `activelayout` event named). `keyboards` lists every typed keyboard that switching affects.
- `hotkey` is an xkb option name, or `"none"`.
- `askedState`: `1` means the placement question was answered, `-1` means not yet, `0` means still loading.

## Keybinding examples

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + ALT + K", "Next keyboard layout", "omarchy-shell lef.keyboard-layout next")
o.bind("SUPER + ALT + J", "Main keyboard layout", "omarchy-shell lef.keyboard-layout set 0")
o.bind("SUPER + ALT + G", "Greek layout",         "omarchy-shell lef.keyboard-layout set gr")
```

These work best with the **None** switch key, so that no xkb key combination competes with them.
