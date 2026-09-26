# Backups and restore

## When a backup is taken

**Before every Apply and every Restore that changes `input.lua`**, and **whenever you press Back up now**, the current file is copied, byte for byte, to:

```
~/.config/omarchy/keyboard-layout/backups/input.lua.YYYYmmdd-HHMMSS[-N]
```

- The folder is created as `0700`, and each backup as `0600`.
- An Apply that wouldn't change anything writes nothing and takes no backup.
- If the newest backup already holds exactly the current bytes, no duplicate is made.
- The **10 newest** backups are kept, and older ones are removed. Names sort oldest to newest, and a same-second collision gets `-1`, `-2`, … that always sorts after the ones already there. Pruning can therefore only ever remove older states.
- If the backup can't be written, the Apply or Restore stops and `input.lua` isn't touched.

## Manual backups

**Back up now** in the panel, or `omarchy-shell lef.keyboard-layout backup`, adds a backup of the current `input.lua` to the same rotating folder. It is useful before editing the file by hand.

- Same rules as automatic backups: exact bytes, `0600`, the newest 10 kept, no duplicate when the newest backup already matches (the panel then says *Unchanged since the newest backup*).
- It refuses if `input.lua` doesn't exist or isn't valid UTF-8.
- `input.lua` itself is never touched.

## Opening the folder

**Open folder** in the panel, or `omarchy-shell lef.keyboard-layout folder`, creates the folder if needed (`0700`) and opens it with your default file manager through `xdg-open`, the handler for `inode/directory`. The panel closes so the file manager is in front.

## Original backups from 1.1.x

Version 1.1.x made one backup next to the file: `~/.config/hypr/input.lua.bak.<unix-time>`. These **originals** are:

- listed together with the rotating backups (marked `orig` in the panel, `"kind": "original"` in IPC);
- restorable;
- never modified, pruned or created again.

## Listing

In the panel, the **Backups** column shows each backup as:

```
orig 2026-08-22 23:57 · defaults
2026-09-26 14:26 · us,gr(polytonic)
```

The summary is the layouts that backup would activate. `defaults` means the file has no live `kb_layout`, so Omarchy's defaults apply. `unreadable` marks a backup that can't be parsed safely; it can't be restored.

Over IPC:

```sh
omarchy-shell lef.keyboard-layout backups
```

```json
[{"id":"input.lua.20260926-142602","kind":"rotating","time":1790421962,"size":1790,"layouts":"us,gr","valid":true},
 {"id":"input.lua.bak.1787432230","kind":"original","time":1787432230,"size":2118,"layouts":"","valid":true}]
```

`backups` returns the list the service last read, and starts a fresh read. Call it twice if you've just changed `input.lua` from outside the plugin.

## Restoring

In the panel, press **Restore** on a row and confirm. Over IPC:

```sh
omarchy-shell lef.keyboard-layout restore input.lua.20260926-142602
```

A restore:

1. accepts only ids that match `input.lua.YYYYmmdd-HHMMSS[-N]` (looked up in the backups folder) or `input.lua.bak.<digits>[.N]` (looked up next to `input.lua`). Paths, `..` and anything else are refused (exit 12). IPC also requires the id to be in the current list and restorable;
2. opens the backup without following symlinks, requires a regular file within the size limit that is valid UTF-8, and parses it with the same scanner as `read`. A backup that doesn't parse is refused (exit 11);
3. backs up the **current** `input.lua` into the rotating folder, so a restore can always be undone;
4. replaces `input.lua` atomically (same checks against concurrent changes as Apply) and keeps its permissions;
5. reloads Hyprland.

## By hand

The backups are plain copies. You can also restore one yourself:

```sh
cp ~/.config/omarchy/keyboard-layout/backups/input.lua.20260926-142602 ~/.config/hypr/input.lua
hyprctl reload
```
