# Zomboid Map Index

An index of Project Zomboid maps on the Steam Workshop: which cells each map covers, so tools can show where maps meet or overlap without having the maps installed.

## Asking for a map

Open an issue with the **Add a map** form and give the map's Workshop link or ID. A check confirms that the item is a Project Zomboid item tagged Map on the Workshop and queues it, or closes the issue with the reason. The issue closes when the index has the map.

## Updates

Once a day a check asks the Workshop which maps in the index changed or were removed since they were indexed, and queues each in an issue of its own.

## Popular maps

Once a day a check also queues the most subscribed maps on the Workshop that the index doesn't have yet, a few at a time.

## How it works

The checks run on GitHub Actions and only read public information from the Workshop; nothing in an issue is ever run. A worker in this repository, run by the maintainer, downloads the queued maps, reads their files and adds them to `items/`, one file per Workshop item.

## Data

`items/<workshop id>.json` holds one Workshop item: `format` (the version of this format, now 2; entries of an older one are read again), `id`, `title`, `timeUpdated` (the Workshop's update time it was read at) and `mods`, one per folder in the item's `mods/`:

- `folder`: the mod folder's name.
- `roots`: each folder the game may read the mod's files from, with a `path` relative to the mod folder: `""` for the mod folder itself (the Build 41 layout), a version folder such as `"42"`, or `"common"`. Which of them the game reads depends on its version.
  - `modInfo`: the lines of its `mod.info` as the game reads them (ending at `\n`, `\r\n` or a lone `\r`), without blank lines and lines that start with `description=`; `null` without one.
  - `zoneLoader`: whether its `media/lua/server/metazones/metazoneHandler.lua` is one that fails on zones without x, y, z, width or height, as Build 42's does; `null` without one.
  - `maps`: the map folders in its `media/maps`:
    - `name`, and `cells` as runs `[y, first x, last x]` of the `<x>_<y>.lotheader` files.
    - `spawns`: `[x, y, z]` squares from `spawnpoints.lua` (`null` without one).
    - `rooms`: the buildings in the map's own cells that hold its spawn points, read from the cell headers as the game reads them (cells of 300 squares in the mod folder itself, 256 in the others): `[x, y, z, building x, building y]` per point and building, the building's x and y being the least of its rooms, or `[x, y, z]` for a point a header that can't be read could hold.
    - `zones`: for each of `objects.lua`, `regions.lua` and `roomtones.lua` the map has, the line of the zone the game stops loading zones at, or `null` when it reads the whole file.
    - `mapInfo`: the lines of its `map.info`, like `modInfo`; `null` without one. `title`: its last `title=` line, `null` without one.
  - `translations`: the English titles of the item's maps in it, by `name`: `json` from `Translate/EN/<map>.json`, which Build 42.20 and later read, and `txt` from `Translate/EN/<map>/title.txt`, which earlier versions read.

An item without maps stays in the index, so it isn't asked for again.

## Licences

The code is under the GNU Affero General Public License, version 3 or any later version ([LICENSE](LICENSE)). The data in `items/` is under the Creative Commons Attribution-ShareAlike 4.0 International licence ([items/LICENSE](items/LICENSE)): credit the Zomboid Map Index when you use it, and share changed versions of it under the same licence.
