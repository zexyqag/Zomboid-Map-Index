# Zomboid Map Index

An index of Project Zomboid maps on the Steam Workshop: which cells each map covers, so tools can show where maps meet or overlap without having the maps installed.

## Asking for a map

Open an issue with the **Add a map** form and give the map's Workshop link or ID. A check confirms that the item is a Project Zomboid item tagged Map on the Workshop and queues it, or closes the issue with the reason. The issue closes when the index has the map.

## Updates

Once a day a check asks the Workshop which maps in the index changed or were removed since they were indexed, and queues each in an issue of its own.

## How it works

The checks run on GitHub Actions and only read the Workshop's public details of each item; nothing in an issue is ever run. A worker in this repository, run by the maintainer, downloads the queued maps, reads their files and adds them to `items/`, one file per Workshop item.

## Licences

The code is under the GNU Affero General Public License, version 3 or any later version ([LICENSE](LICENSE)). The data in `items/` is under the Creative Commons Attribution-ShareAlike 4.0 International licence ([items/LICENSE](items/LICENSE)): credit the Zomboid Map Index when you use it, and share changed versions of it under the same licence.
