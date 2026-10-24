#!/bin/bash
# Prints the index entry of a downloaded Workshop item. Per mod folder, each folder the game may read the mod's
# files from (the mod folder itself as "", its version folders and common/) with the maps in it: their cells as
# runs [y, first x, last x], spawn points [x, y, z] (null without spawnpoints.lua), whether they have a map.info
# and its title, and the English titles of the item's maps in its translations, from Translate/EN/<map>.json
# and Translate/EN/<map>/title.txt.
# Usage: index_item.sh <item folder> <workshop id> <title> <Workshop update time>
set -euo pipefail

item="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# "<mod folder>\t<folder>\t<path>" for every folder with a mod.info or media/, the path last as it can be empty.
for mod in "${item}"/mods/*/; do
  mod="${mod%/}"
  for root in "${mod}" "${mod}"/*/; do
    root="${root%/}"
    if [ -d "${root}/media" ] || [ -f "${root}/mod.info" ]; then
      path="${root#"${mod}"}"
      printf '%s\t%s\t%s\n' "${mod##*/}" "${root}" "${path#/}"
    fi
  done
done > "${tmp}/roots"

# "map\t<mod folder>\t<map>\t<folder>\t<path>".
while IFS=$'\t' read -r mod root path; do
  for map in "${root}"/media/maps/*/; do
    [ -d "${map}" ] || continue
    map="${map%/}"
    printf 'map\t%s\t%s\t%s\t%s\n' "${mod}" "${map##*/}" "${map}" "${path}"
  done
done < "${tmp}/roots" > "${tmp}/maps"

# The cells of each map folder, by y and x.
awk -F '\t' '{ print $4 }' "${tmp}/maps" | while IFS= read -r map; do
  find -L "${map}" -maxdepth 1 -name '*.lotheader' -printf '%H\t%f\n' 2> /dev/null || true
done | LC_ALL=C awk -F '\t' '$2 ~ /^-?[0-9]+_-?[0-9]+\.lotheader$/ { split($2, at, /[_.]/); print $1 "\t" at[2] "\t" at[1] }' \
  | LC_ALL=C sort -t $'\t' -k1,1 -k2,2n -k3,3n | LC_ALL=C awk -F '\t' '
    function flush() { if (n) printf "%s[%d,%d,%d]", (runs++ ? "," : ""), y, first, last }
    $1 != folder {
      if (folder != "") { flush(); print "]" }
      folder = $1
      printf "%s\t[", folder
      runs = n = 0
    }
    n && $2 == y && $3 == last + 1 { last = $3; next }
    { flush(); y = $2; first = last = $3; n = 1 }
    END { if (folder != "") { flush(); print "]" } }
  ' > "${tmp}/cells"

# Spawn points as SpawnPoints.parsePoint reads them: worldX and worldY count cells of 300 squares on both builds,
# posX and posY squares within them, or squares of the world without them; posZ is the level, 0 when missing.
# Points are read from one-line tables, as the game and WorldEd write them; points named by position and points
# made by code aren't.
awk -F '\t' '{ print $4 "/spawnpoints.lua" }' "${tmp}/maps" | while IFS= read -r file; do
  [ ! -f "${file}" ] || printf '%s\n' "${file}"
done | LC_ALL=C awk '
  function num(t, key) {
    if (!match(t, "[^A-Za-z0-9_]" key "[ \t]*=[ \t]*-?[0-9]+(\\.[0-9]+)?")) return ""
    t = substr(t, RSTART, RLENGTH)
    sub(/^[^=]*=[ \t]*/, "", t)
    return t
  }
  {
    path = $0
    printf "%s", path
    while ((getline line < path) > 0) {
      sub(/\r$/, "", line)
      sub(/--.*/, "", line)
      while (match(line, /\{[^{}]*\}/)) {
        t = " " substr(line, RSTART + 1, RLENGTH - 2) " "
        line = substr(line, RSTART + RLENGTH)
        px = num(t, "posX")
        py = num(t, "posY")
        if (px == "" || py == "") continue
        wx = num(t, "worldX")
        wy = num(t, "worldY")
        if (wx == "" && wy == "") {
          x = int(px)
          y = int(py)
        } else if (wx != "" && wy != "") {
          x = int(wx) * 300 + int(px)
          y = int(wy) * 300 + int(py)
        } else continue
        z = num(t, "posZ")
        z = z == "" ? 0 : int(z)
        if (!((path, x, y, z) in seen)) {
          seen[path, x, y, z]
          printf "\t%d,%d,%d", x, y, z
        }
      }
    }
    close(path)
    print ""
  }
' > "${tmp}/spawns"

# Titles: of map.info its last title= line (whether it has one, then the title); of a translation for one of the
# item's maps its "title" as a JSON string, or the first line of title.txt.
{
  awk -F '\t' '{ print "info\t" $4 "\t" $4 "/map.info" }' "${tmp}/maps"
  while IFS=$'\t' read -r mod root path; do
    translate="${root}/media/lua/shared/Translate/EN"
    while IFS= read -r name; do
      [ ! -f "${translate}/${name}.json" ] || printf 'json\t%s\t%s\n' "${root}" "${translate}/${name}.json"
      [ ! -f "${translate}/${name}/title.txt" ] || printf 'txt\t%s\t%s\n' "${root}" "${translate}/${name}/title.txt"
    done < <(awk -F '\t' '{ print $3 }' "${tmp}/maps" | sort -u)
  done < "${tmp}/roots"
} | LC_ALL=C awk -F '\t' -v OFS='\t' '
  { name = $3; sub(/\/(map\.info|title\.txt)$/, "", name); sub(/\.json$/, "", name); sub(/.*\//, "", name) }
  $1 == "info" {
    if ((getline line < $3) <= 0) next
    has = 0
    title = ""
    do {
      sub(/\r$/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (substr(line, 1, 6) == "title=") {
        has = 1
        title = line
        gsub(/title=/, "", title)
      }
    } while ((getline line < $3) > 0)
    close($3)
    print "info", $2, has, title
  }
  $1 == "json" {
    text = ""
    while ((getline line < $3) > 0) text = text line "\n"
    close($3)
    if (match(text, /"title"[ \t\r\n]*:[ \t\r\n]*"([^"\\]|\\.)*"/)) {
      title = substr(text, RSTART, RLENGTH)
      sub(/^"title"[ \t\r\n]*:[ \t\r\n]*/, "", title)
      print "json", $2, name, title
    }
  }
  $1 == "txt" {
    line = ""
    if ((getline line < $3) > 0) {
      sub(/\r$/, "", line)
      sub(/^\357\273\277/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
    }
    close($3)
    if (line != "") print "txt", $2, name, line
  }
' > "${tmp}/titles"

jq -n -c --arg id "$2" --arg title "$3" --argjson updated "$4" \
  --rawfile roots "${tmp}/roots" --rawfile maps "${tmp}/maps" --rawfile cells "${tmp}/cells" \
  --rawfile spawns "${tmp}/spawns" --rawfile titles "${tmp}/titles" '
  def rows: split("\n") | map(select(length > 0) | split("\t"));
  ($cells | rows | map({key: .[0], value: (.[1] | fromjson)}) | from_entries) as $cells
  | ($spawns | rows | map({key: (.[0] | rtrimstr("/spawnpoints.lua")), value: (.[1:] | map(split(",") | map(tonumber)))}) | from_entries) as $spawns
  | ($titles | rows) as $titles
  | ($titles | map(select(.[0] == "info") | {key: .[1], value: (if .[2] == "1" then .[3] // "" else null end)}) | from_entries) as $info
  | ($maps | rows) as $maps
  | {id: $id, title: $title, timeUpdated: $updated,
     mods: ($roots | rows | group_by(.[0]) | map({folder: .[0][0], roots: map(.[0] as $mod | .[1] as $root | (.[2] // "") as $path | {path: $path,
       maps: [$maps[] | select(.[1] == $mod and (.[4] // "") == $path) | .[3] as $map
         | {name: .[2], cells: ($cells[$map] // []), spawns: $spawns[$map], mapInfo: ($info | has($map)), title: $info[$map]}],
       translations: ($titles | map(select(.[1] == $root and (.[0] == "json" or .[0] == "txt"))) | group_by(.[2])
         | map({name: .[0][2],
             json: (first(.[] | select(.[0] == "json") | .[3] | try fromjson catch null | select(type == "string" and length > 0)) // null),
             txt: (first(.[] | select(.[0] == "txt") | .[3]) // null)})
         | map(select(.json != null or .txt != null)))})}))}'
