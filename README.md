# Keyboard Layout for Omarchy

An [Omarchy](https://omarchy.org/) shell plugin that shows your active keyboard layout in the bar and switches layouts on demand — for any language pair, not just one.

The bar glyph is your live layout abbreviation (`EN`, `GR`, `PT`…):

- **Left-click** — panel: live layout state, placement, layout pair and switch-hotkey settings.
- **Right-click** — switch to the next layout immediately.
- **Hover** — tooltip with the full keymap name.

## Features

- **Language agnostic**: pick any two layouts from xkb's own table (`us`, `gr`, `de`, `jp`, `ara`, …) with short labels read from `xkbcli list --load-exotic`.
- **Placement choice**: on first run the plugin asks where the widget should live — `center` (parked right after the clock) or `right`. The left section is never offered. Change it any time from the panel; moving triggers a Hyprland + shell reload so the bar settles cleanly.
- **Switches the keyboard you actually type on**: reads `hyprctl devices -j`, filters out virtual/injected keyboards (fcitx5's seat keyboard, ACPI buttons), and follows the furthest-advanced typed device — the same logic as Omarchy's first-party widget.
- **Caps LED indicator** when using Caps Lock as the toggle (`grp_led:caps`).
- **Owns its config honestly**: settings are written to `~/.config/hypr/input.lua` only when you press *Apply* in the panel; a one-time timestamped backup (`input.lua.bak.<ts>`) is kept before the first write. Nothing is overwritten without an explicit click.

## Install

```sh
omarchy plugin add https://github.com/Somnius/Keyboard-Layout-for-Omarchy.git --enable
```

The widget starts on the right side of the bar; the first-run panel asks whether to keep it there or move it next to the clock.

### From a local checkout (development)

If you already have a copy of this repository on disk, link it into the plugins folder:

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/lef.keyboard-layout
omarchy-shell shell rescanPlugins
```

> **Dev loop caveat:** Quickshell's file watcher does not follow symlinks; after edits run `omarchy restart shell`.

Validate at any time with:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/lef.keyboard-layout
```

## Configuration

Panel changes are persisted by the plugin itself.

Target file: `~/.config/hypr/input.lua`

| Key | Values | Notes |
|---|---|---|
| `input.kb_layout` | comma-separated xkb layouts | e.g. `"us,gr"` |
| `input.kb_options` | `grp:caps_toggle` \| `grp:alt_shift_toggle` \| `grp:ctrl_shift_toggle` (+ `grp_led:caps`) | Super+Space is deliberately not offered — Omarchy reserves it for the launcher |

Plugin state: `~/.config/omarchy/keyboard-layout/config.json`

| Key | Values | Default |
|---|---|---|
| `asked` | boolean | `false` — set once you answer the placement question |
| `placement` | `center` \| `right` | `right` |

## IPC & keybindings

```sh
omarchy-shell lef.keyboard-layout status          # full JSON state
omarchy-shell lef.keyboard-layout next            # switch to next layout
omarchy-shell lef.keyboard-layout place center    # or right — moves + reloads
omarchy-shell lef.keyboard-layout toggle          # open/close the panel
```

Hyprland binding example (`~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + ALT + K", "Next keyboard layout", "omarchy-shell lef.keyboard-layout next")
```

## External dependencies

Ships with Omarchy: `hyprctl`, `xkbcli`, the `omarchy` CLI, and `bash`.

## Uninstall

```sh
omarchy plugin remove lef.keyboard-layout
```

(If installed via symlink, remove the symlink instead. Your last-applied `input.lua` settings stay in place.)

## License

[MIT](LICENSE)
