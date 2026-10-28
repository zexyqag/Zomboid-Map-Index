#!/bin/bash
# Builds the site in the folder $1: index.json, every entry of items/ by Workshop ID as {"items": [...]}, the grid
# script as grid-<major version>.js, workshop.json, the Workshop's figures of the items as workshop.sh printed them to
# the file $2, for each build of the game in vanilla/ build-<major version>.json: what of each item loads on the
# version read there, with its figures, which of those maps share cells, and the game's own maps, and builds.json:
# those builds and their versions, newest first.
set -euo pipefail
out="$(realpath -m "${1:?usage: site.sh <folder> <workshop figures>}")"
workshop="$(realpath "${2:?usage: site.sh <folder> <workshop figures>}")"
cd "$(dirname "$0")/.."
# shellcheck source=ci/mod_info.sh
. ci/mod_info.sh

shopt -s nullglob
games=(vanilla/*.json)
versions=()
for game in "${games[@]}"; do
  build="$(basename "${game}" .json)"
  versions+=("$(jq -r '.gameVersion' "${game}")")
  if ! [[ "${versions[-1]}" =~ ^${build}\.[0-9]+ ]]; then
    echo "${game} has the version ${versions[-1]}, which is not one of Build ${build}" >&2
    exit 1
  fi
done
major="$(sed -n "s/^export const VERSION = '\([0-9][0-9]*\)\.[0-9][0-9]*\.[0-9][0-9]*';$/\1/p" site/grid.js)"
if [ -z "${major}" ]; then
  echo "site/grid.js has no VERSION like '1.0.0'" >&2
  exit 1
fi

mkdir -p "${out}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
files=(items/*.json)
if [ "${#files[@]}" -gt 0 ]; then
  jq -c -s 'sort_by(.id | tonumber) | {items: .}' "${files[@]}" > "${out}/index.json"
else
  echo '{"items":[]}' > "${out}/index.json"
fi
cp site/grid.js "${out}/grid-${major}.js"
jq -c . "${workshop}" > "${out}/workshop.json"

# The entries' mod.info files at <id>/mods/<folder>/<path>, for the game's rules to read. Entries of the first format
# have none. A folder name no folder can have would put them elsewhere, and the reader takes tabs and line breaks for
# the ends of names.
entries='
  def plain: test("^[^/\u0000-\u001f]+$") and . != "." and . != "..";
  def placeable: all(.mods[]; (.folder | plain) and all(.roots[]; .path == "" or (.path | plain)));
  .items[] | select(.format >= 2)'
jq -c "${entries}"' | select(placeable)' "${out}/index.json" > "${tmp}/entries"
jq -r "${entries}"' | select(placeable | not) | "Warning: item \(.id) has a folder name no folder can have, so the builds leave it out"' \
  "${out}/index.json" >&2
mkdir -p "${tmp}/items"
jq -c '.id as $id | .mods[] | .folder as $folder | .roots[] | {dir: ($id + "/mods/" + $folder + (if .path == "" then "" else "/" + .path end)), modInfo}' \
  "${tmp}/entries" | while IFS= read -r root; do
  dir="${tmp}/items/$(jq -r '.dir' <<< "${root}")"
  mkdir -p "${dir}"
  if jq -e '.modInfo | type == "array"' <<< "${root}" > /dev/null; then
    jq -r '.modInfo[] | tostring' <<< "${root}" > "${dir}/mod.info"
  fi
done

# Of the folders a mod that loads reads (its version folder, then common/), the first with a map gives the map's
# cells, the first with a zone file where that file's zones stop, the first with spawnpoints.lua its spawn points and
# the first with map.info its title, which the English translation of the file the version reads replaces.
for i in "${!games[@]}"; do
  mod_info_rows "${versions[$i]}" "${tmp}/items"/*/mods > "${tmp}/rows"
  jq -s -c --arg version "${versions[$i]}" --rawfile rows "${tmp}/rows" --slurpfile game "${games[$i]}" --slurpfile workshop "${workshop}" '
    def first_of(f): [f] | if length > 0 then .[0] else null end;
    def text: if . == "" then null else . end;
    # Build 42.20 and later read Translate/EN/<map>.json, earlier versions <map>/title.txt (42.14 to 42.19 are not
    # checked).
    ($version | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)") | (.major | tonumber) * 1000 + (.minor | tonumber)
      | if . >= 42020 then "json" else "txt" end) as $reads
    | (map({key: .id, value: .}) | from_entries) as $by_id
    | ($rows | split("\n") | map(select(length > 0) | split("\t") | .[0] as $item | .[1] as $folder | .[2] as $files
        | first_of($by_id[$item].mods[] | select(.folder == $folder) | .roots) as $roots
        | (if .[3] != "1" then [] elif $files == "." then [""] elif $files == "common" then ["common"] else [$files, "common"] end) as $order
        | [$order[] as $path | $roots[] | select(.path == $path)] as $chosen
        | {item: $item, folder: $folder, id: .[4], name: (.[5] | text),
           versionFolder: (if $files == "" then null elif $files == "." then "" else $files end),
           loads: (.[3] == "1"), error: (.[18] | text), require: (.[13] | split(",")), incompatible: (.[16] | split(",")),
           zoneLoader: first_of($chosen[] | select(.zoneLoader != null) | .zoneLoader),
           maps: ([$chosen[].maps[].name] | unique | map(. as $name
             | [$chosen[].maps[] | select(.name == $name)] as $all
             | first_of($all[] | select(.spawns != null)) as $spawned
             | first_of($all[] | select(.mapInfo != null)) as $info
             | {item: $item, folder: $folder, name: $name,
                title: (if $info == null then null
                  else first_of($chosen[].translations[] | select(.name == $name and .[$reads] != null) | .[$reads]) // $info.title end),
                cells: $all[0].cells, spawns: (if $spawned then $spawned.spawns | length else null end),
                zones: (reduce ("objects.lua", "regions.lua", "roomtones.lua") as $file ({};
                  first_of($all[] | select(.zones | has($file))) as $map | if $map then . + {($file): $map.zones[$file]} else . end))}))})
        | sort_by((.item | tonumber), .folder)) as $mods
    | [$mods[].maps[]] as $maps
    # Each mod lists its maps by their place in maps.
    | (reduce $mods[] as $mod ({mods: [], at: 0}; .mods += [$mod + {maps: [range(.at; .at + ($mod.maps | length))]}] | .at += ($mod.maps | length))
      | .mods | group_by(.item) | map({key: .[0].item, value: map(del(.item))}) | from_entries) as $item_mods
    | {gameVersion: $version, vanilla: $game[0].maps,
       items: map({id, title, timeUpdated, workshop: $workshop[0][.id], mods: ($item_mods[.id] // [])}),
       maps: $maps,
       conflicts: ([$maps | to_entries[] | .key as $at | .value.cells[] | .[0] as $y | range(.[1]; .[2] + 1) | [., $y, $at]]
         | group_by(.[0:2]) | map(map(.[2]) | . as $here | range(0; length) as $a | range($a + 1; length) as $b | [$here[$a], $here[$b]])
         | group_by(.) | map(.[0] + [length])),
       providers: ([$mods[] | select(.loads)] | group_by(.id) | map({key: .[0].id, value: (map(.item) | unique | sort_by(tonumber))})
         | from_entries)}' "${tmp}/entries" > "${out}/build-$(basename "${games[$i]}" .json).json"
done
for i in "${!games[@]}"; do
  printf '%s\t%s\n' "$(basename "${games[$i]}" .json)" "${versions[$i]}"
done | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t") | {build: (.[0] | tonumber), gameVersion: .[1]}]
  | sort_by(-.build) | {builds: .}' > "${out}/builds.json"
