# Underkeep Sprite Swap

[日本語](README.ja.md)

A small local tool for replacing character portraits and other sprites in **Underkeep** (Steam) with your own images.
Browse every sprite in your browser, drop in an image, crop and resize it to fit, and write it into the game. The tool backs up the original atlases automatically.

> Unofficial fan tool. Not affiliated with or endorsed by the developers or publisher of Underkeep.
> This repository contains **no game assets**. Everything extracted from your installation stays on your PC.

## Features

- Browse all ~3,800 sprites: hero portraits, companions, creatures and NPCs
- Drag and drop, paste (Ctrl+V) or choose an image
- Automatic crop and resize to the sprite's exact size. Drag to reposition, scroll to zoom, "fit" or "fill" presets
- Optional nearest-neighbour scaling for pixel art
- Hero portraits have a blink frame; it is replaced along with the portrait by default
- Changes are staged as drafts first and written to the game only when you press **Write to game**
- Automatic backups, one-click restore for a single sprite or for everything
- Detects when Steam file verification or a game update has reverted your changes, and re-applies them with one click
- English and Japanese UI
- Nothing to install: plain PowerShell 5.1+ (built into Windows) and your browser

## Quick start

1. Download this repository (Code → Download ZIP) and extract it anywhere.
2. Double-click **`uksprite-web.bat`**. Your browser opens `http://localhost:18093/`.
3. Click a portrait (or drop an image onto it), adjust the crop, then press **Stage**.
4. Press **Write to game**. If the game is running, restart it.

Press Ctrl+C in the console window to stop the server.

Tile borders show the state of each sprite:

| Border | Meaning |
|---|---|
| Dashed orange | Staged draft, not in the game yet |
| Green | Written to the game |
| Red | Was written, but the game reverted it (Steam verification or update). **Write to game** puts it back |

## Backups and safety

- Before an atlas is written for the first time, the original is copied to `backup\` next to the scripts.
- Every image written to the game is also kept in `applied\`, so it can be re-applied after Steam restores the files.
- On start-up the tool compares the game's atlases with its records:
  - **Reverted** (the atlas matches the backup again): the affected sprites are marked red and can be re-applied.
  - **Updated by the game** (the atlas matches neither): the backup is replaced with the new atlas. Restoring the old one would undo the update.
- **Restore all** puts every original pixel back and deletes the backups once nothing is left to restore.
- Steam's *Verify integrity of game files* always gives you the untouched game.

Changes only affect local files on your PC.

## Command line

```powershell
.\uksprite.ps1 list '^face_3'               # name, atlas, position, size, status
.\uksprite.ps1 export '^face_300' .\work    # writes .\work\face_300.png and face_300_blink.png
# edit the PNGs without changing their size
.\uksprite.ps1 import .\work                # stage them as drafts
.\uksprite.ps1 commit                       # write drafts to the game
.\uksprite.ps1 restore                      # undo everything (or pass a name regex)
```

If PowerShell refuses to run the scripts, use `powershell -ExecutionPolicy Bypass -File .\uksprite.ps1 ...`.

### Options

| Option | Default | |
|---|---|---|
| `-GameDir` | `C:\Program Files (x86)\Steam\steamapps\common\Underkeep` | Game folder, if installed elsewhere |
| `-Port` (web only) | `18093` | Local port. The server listens on `localhost` only |
| `-NoOpen` (web only) | | Do not open the browser |
| `-Lang` | Windows display language | `en` or `ja` for console messages. The web UI follows the browser and has its own switch |

## How it works

Underkeep keeps its sprites packed into plain PNG atlases (`base\atlas*.atlas_N.texture.png`, 2048×2048).
`base\_sprite.db` maps each sprite name to an atlas and a rectangle. The tool reads that database and copies pixels in and out of the atlases. It never changes the database, so a replacement must have the same size as the original sprite. The editor takes care of that.

The `.db` files use a small binary format:

- Header: `FF 'Def' 01`, then a uint32 offset to the string table, then 8 zero bytes
- The root value starts at offset 16. Each value is a one-byte tag followed by its payload:

  | Tag | Payload |
  |---|---|
  | `00` | null |
  | `01` / `02` / `03` | int8 / int16 / int32 |
  | `04` | float32 |
  | `05` | string index (uint8) |
  | `06` | string index (LEB128) |
  | `07` | array: uint32 count, then values |
  | `08` | map: uint32 count, then key/value pairs |

- String table: uint32 count, then length-prefixed (uint8) UTF-8 strings

Each sprite entry has `name` and `metadata` with `texture` (atlas name), `rect` (x, y, w, h) and `pivot`.

## License

[MIT](LICENSE). Underkeep and its assets belong to their respective owners. Please do not redistribute extracted game images.
