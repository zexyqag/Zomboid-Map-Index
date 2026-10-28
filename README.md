# Zomboid Map Index

An index of Project Zomboid maps on the Steam Workshop: which cells each map covers, so tools can show where maps meet or overlap without having the maps installed.

## Asking for a map

Open an issue with the **Add a map** form and give the map's Workshop link or ID. A check confirms that the item is a Project Zomboid item tagged Map on the Workshop, or one that an item in the index requires there, such as a tile pack, and queues it, or closes the issue with the reason. The issue closes when the index has the item.

## Updates

Once a day a check asks the Workshop which maps in the index changed or were removed since they were indexed, and queues each in an issue of its own. An item without map folders, such as a tile pack, is read again at most every 90 days; ask for it with the form to have it read sooner.

Once a week a check installs the game's dedicated server from each of its Steam branches for Build 41 and Build 42 and reads which version it is and which cells the game's own maps cover.

## Required items and every map

Every hour a check also queues, a few at a time, what the index doesn't have yet: first the items that its items require on the Workshop, such as tile packs, so it knows which item provides each mod a map needs, then every other map on the Workshop, for any build of the game, most subscribed first.

## How it works

The checks run on GitHub Actions and only read public information from the Workshop; nothing in an issue is ever run. A worker in this repository, run by the maintainer, downloads the queued maps, reads their files and adds them to `items/`, one file per Workshop item.

## Using the index

The repository's GitHub Pages publish the whole index as `index.json`, `{"items": [...]}` with every entry of `items/` by Workshop ID, and the grid script as `grid-1.js`: an ES module that works out which maps are on each cell in `Map=` order and draws the cells on a canvas, for pages that show maps. A change to how pages call it comes as `grid-2.js`.

`workshop.json` has the Workshop's figures of each item by Workshop ID, read every day: `subscribers` and `favorites` now and their `lifetimeSubscribers` and `lifetimeFavorites`, unique `visitors`, `votesUp`, `votesDown` and Steam's `score` from them, public `comments`, `fileSize` in bytes, `timeCreated` and `timeUpdated`, the `preview` image and the Workshop IDs it `requires`. A value Steam doesn't give is `null`; an item Steam no longer has is left out.

`builds.json` lists the builds that have a file, newest first, as `{"builds": [{"build": 42, "gameVersion": "42.21.0"}, ...]}`.

`build-41.json` and `build-42.json` say what of each item the current version of that build loads, as the game reads the mods' `mod.info` files:

- `gameVersion`: the version.
- `vanilla`: the game's own map folders, with their `name` and `cells`.
- `items`: by Workshop ID, with `id`, `title`, `timeUpdated`, `workshop` (its figures from `workshop.json`, or `null`) and `mods`, one per mod folder with a `mod.info`:
  - `folder`, and `id` and `name` from the `mod.info` the game reads.
  - `versionFolder`: the folder its files come from besides `common/`, `""` for the mod folder itself, `null` when the game doesn't find the mod on this version.
  - `loads`, and `error`: why the game doesn't find or load the mod or, for one that loads, why it doesn't load what it requires by itself. When a mod doesn't load and has no error, its `versionMin` or `versionMax` keeps it out.
  - `require` and `incompatible`: mod IDs.
  - `zoneLoader`: as in the entries, from the first folder it reads with one.
  - `maps`: its maps by their place in `maps`. Only mods that load have maps.
- `maps`: the maps of the mods that load, with their `item`, `folder` and `name`, and the rest from the first of the mod's folders (its version folder, then `common/`) that has it: `cells`, `spawns` (how many spawn points, `null` without `spawnpoints.lua`), `zones`, and `title`, the English title the game shows for a map with a `map.info`, from the translation this version reads, else from `map.info` (`null` without one).
- `conflicts`: `[map, map, cells]` for each two maps that share cells, by their place in `maps`, with how many they share.
- `providers`: by mod ID, the Workshop IDs of the items with a mod of that ID that loads.

They leave out entries of the first format, which are read again soon, and entries with a folder name no folder can have.

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

`vanilla/<build>.json` holds the game's own maps on one build: `gameVersion` (as the server logs it), `branch` (the Steam branch it was read from) and `maps`, each folder in the game's `media/maps` with its `name` and `cells`.

## Licences

The code is under the GNU Affero General Public License, version 3 or any later version ([LICENSE](LICENSE)). The data in `items/` is under the Creative Commons Attribution-ShareAlike 4.0 International licence ([items/LICENSE](items/LICENSE)): credit the Zomboid Map Index when you use it, and share changed versions of it under the same licence.
