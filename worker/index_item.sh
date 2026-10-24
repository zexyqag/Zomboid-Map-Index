#!/bin/bash
# Prints the index entry of a downloaded Workshop item. Per mod folder, each folder the game may read the mod's
# files from (the mod folder itself as "", its version folders and common/) with its mod.info, whether its zone
# loader fails, the maps in it and the English titles of the item's maps in its translations, from
# Translate/EN/<map>.json and Translate/EN/<map>/title.txt. Per map: its cells as runs [y, first x, last x], spawn
# points [x, y, z] (null without spawnpoints.lua), the buildings of its own cells that hold them, the line of the
# zone the game stops at in each zone file, its map.info and its title. The cell headers are read with the jar
# ROOMS_READER.
# Usage: index_item.sh <item folder> <workshop id> <title> <Workshop update time>
set -euo pipefail
# shellcheck source=ci/lib.sh
. "$(dirname "$0")/../ci/lib.sh"

# True while the zone loader still builds its error messages and water zone bounds from x, y, z, width and
# height, which fails on a zone without them (Build 42's metazoneHandler.lua).
zone_loader_fails() {
  # $1 = metazoneHandler.lua
  grep -qF "'..v.x..','..v.y..','..v.z" "$1" && grep -qF 'v.x + v.width' "$1"
}

# The game loads the zones of the maps in Map= from the last map to the first, from each map's
# objects.lua, regions.lua and roomtones.lua, and stops at the first zone it fails on (doMapZones in
# media/lua/server/metazones/metazoneHandler.lua). It puts x, y and z of a water zone, water flow,
# mannequin or room tone without the properties it needs into an error message, and adds up x, y,
# width and height of a water zone with them, which fails on a missing one, as on a polygon. For an
# animal zone without geometry it calls a method that IsoWorld doesn't have, and Java fails on a
# Direction property other than N, NW, W, SW, S, SE, E or NE of a vehicle, parking stall or mannequin
# zone. Numbers missing where the game passes them to Java aren't counted,
# nor other errors in Java, such as an unknown geometry. WorldEd writes one zone
# per line. Only lines that hold a whole zone are read, after the line that sets the table the game
# takes the zones from. The game can't compile a file that starts with a UTF-8 byte order mark and
# reads none of its zones, so those files are skipped; other files Lua can't compile are read as they
# are.
zone_stops() {
  # stdin = paths of objects.lua, regions.lua and roomtones.lua files. Prints "<path>\t<line>" for each
  # file the game stops in, with the line of the zone it fails on.
  LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function text_of(value) { return value ~ /^\$[0-9]+$/ ? str[substr(value, 2) + 0] : "" }
    # The code of a line without comments, with each string replaced by $<n> and its text in str[n].
    # closing is the end of the long comment or string the next line starts in.
    function code(line,   out, t, i) {
      gsub(/\\./, "", line)
      split("", str)
      nstr = 0
      out = ""
      while (1) {
        if (closing != "") {
          if (!(i = index(line, closing))) return out
          line = substr(line, i + length(closing))
          closing = ""
          out = out " "
        }
        if (!match(line, token)) return out line
        out = out substr(line, 1, RSTART - 1)
        t = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (t == "--") {
          if (!match(line, /^\[=*\[/)) return out
          closing = substr(line, 1, RLENGTH)
          line = substr(line, RLENGTH + 1)
          gsub(/\[/, "]", closing)
        } else {
          gsub(/\[/, "]", t)
          if (!(i = index(line, t))) {
            if (t ~ /\]/) closing = t
            return out
          }
          str[++nstr] = substr(line, 1, i - 1)
          out = out "$" nstr
          line = substr(line, i + length(t))
        }
      }
    }
    # The fields of a Lua table that aren'"'"'t nil, from its code without nested tables
    function fields(text, into,   n, parts, i, key, value) {
      split("", into)
      n = split(text, parts, /[,;]/)
      for (i = 1; i <= n; i++) {
        if (match(parts[i], /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/)) key = trim(substr(parts[i], 1, RLENGTH - 1))
        else if (match(parts[i], /^[ \t]*\[[ \t]*\$[0-9]+[ \t]*\][ \t]*=/)) {
          key = substr(parts[i], 1, RLENGTH)
          gsub(/[^0-9]/, "", key)
          key = str[key + 0]
        } else continue
        value = trim(substr(parts[i], RLENGTH + 1))
        if (value == "nil") delete into[key]
        else into[key] = value
      }
    }
    # Reads the code of a line. Returns 1 when it holds a whole zone, with its fields in f, its type in
    # type and the fields of its properties table in p; props is 1 when it has one.
    function zone(line,   before, inner) {
      if (line !~ /^[ \t]*\{.*\}[ \t]*[,;]?[ \t]*$/) return 0
      sub(/^[ \t]*\{/, "", line)
      sub(/\}[ \t]*[,;]?[ \t]*$/, "", line)
      props = 0
      split("", p)
      while (match(line, /\{[^{}]*\}/)) {
        before = substr(line, 1, RSTART - 1)
        inner = substr(line, RSTART + 1, RLENGTH - 2)
        line = before "T" substr(line, RSTART + RLENGTH)
        if (before !~ /\{/ && before ~ /(^|[,;])[ \t]*properties[ \t]*=[ \t]*$/) {
          props = 1
          fields(inner, p)
        }
      }
      if (line ~ /[{}]/) return 0
      fields(line, f)
      type = text_of(f["type"])
      return 1
    }
    function has(key) { return key in f }
    function stops(file,   xyz) {
      xyz = has("x") && has("y") && has("z")
      if (file == "roomtones.lua") return type == "RoomTone" && !props && !xyz
      if ((type == "Vehicle" || type == "ParkingStall" || type == "Mannequin" && props) && ("Direction" in p) \
        && p["Direction"] ~ /^\$/ && !(text_of(p["Direction"]) in directions)) return 1
      if (type == "Mannequin") return !props && !xyz
      if (file == "regions.lua") return 0
      if (type == "Animal") return !has("geometry")
      if (type == "WaterFlow") return !(("WaterDirection" in p) && ("WaterSpeed" in p)) && !xyz
      if (type == "WaterZone") {
        if (("WaterGround" in p) && ("WaterShore" in p)) return !(has("x") && has("y") && has("width") && has("height"))
        return !xyz
      }
      return 0
    }
    BEGIN {
      token = "[\"\047]|--|\\[=*\\["
      split("N NW W SW S SE E NE", d, " ")
      for (i in d) directions[d[i]]
    }
    {
      path = $0
      file = path
      sub(/.*\//, "", file)
      global = file == "regions.lua" ? "regions" : "objects"
      closing = ""
      inside = 0
      n = 0
      while ((getline line < path) > 0) {
        if (++n == 1 && substr(line, 1, 3) == "\357\273\277") break
        sub(/\r$/, "", line)
        if (closing == "" && line !~ /Water|Mannequin|RoomTone|Animal|Vehicle|ParkingStall|objects|regions|\[/) continue
        line = code(line)
        if (!inside) inside = line ~ "^[ \t]*" global "[ \t]*="
        else if (zone(line) && stops(file)) {
          print path "\t" n
          break
        }
      }
      close(path)
    }
  '
}

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

# Titles of the item's maps in translations: "title" as a JSON string, or the first line of title.txt.
{
  while IFS=$'\t' read -r mod root path; do
    translate="${root}/media/lua/shared/Translate/EN"
    while IFS= read -r name; do
      [ ! -f "${translate}/${name}.json" ] || printf 'json\t%s\t%s\n' "${root}" "${translate}/${name}.json"
      [ ! -f "${translate}/${name}/title.txt" ] || printf 'txt\t%s\t%s\n' "${root}" "${translate}/${name}/title.txt"
    done < <(awk -F '\t' '{ print $3 }' "${tmp}/maps" | sort -u)
  done < "${tmp}/roots"
} | LC_ALL=C awk -F '\t' -v OFS='\t' '
  { name = $3; sub(/\/title\.txt$/, "", name); sub(/\.json$/, "", name); sub(/.*\//, "", name) }
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

# The buildings that hold each map's spawn points, from the map's own cell headers: of 300 squares in the mod
# folder itself (Build 41), of 256 in the others (Build 42). "<map>\t<x>\t<y>\t<z>\t<building x>\t<building y>",
# or "?\t<map>\t<x>\t<y>\t<z>" for a point a header that can't be read could hold.
while IFS=$'\t' read -r _ _ _ map path; do
  awk -F '\t' -v file="${map}/spawnpoints.lua" '$1 == file { for (i = 2; i <= NF; i++) { gsub(/,/, "\t", $i); print $i } }' \
    "${tmp}/spawns" > "${tmp}/points"
  [ -s "${tmp}/points" ] || continue
  java -jar "${ROOMS_READER:?}" "$([ -z "${path}" ] && echo 300 || echo 256)" "${map}" < "${tmp}/points"
done < "${tmp}/maps" > "${tmp}/held"
awk -F '\t' '$1 == "!" { print "Warning: " $2 "/" $3 " could not be read (" $4 "), so the buildings on its cell are unknown" > "/dev/stderr" }
  $1 != "!"' "${tmp}/held" > "${tmp}/rooms"

# Zones: "<map>\t<file>" for each zone file of each map, and "<path>\t<line>" for each the game stops in.
while IFS=$'\t' read -r _ _ _ map _; do
  for file in objects.lua regions.lua roomtones.lua; do
    [ ! -f "${map}/${file}" ] || printf '%s\t%s\n' "${map}" "${file}"
  done
done < "${tmp}/maps" > "${tmp}/zones"
awk -F '\t' '{ print $1 "/" $2 }' "${tmp}/zones" | zone_stops > "${tmp}/stops"
# "<folder>\t<true|false>" for each folder with a zone loader.
while IFS=$'\t' read -r _ root _; do
  handler="${root}/media/lua/server/metazones/metazoneHandler.lua"
  if [ -f "${handler}" ]; then
    printf '%s\t%s\n' "${root}" "$(zone_loader_fails "${handler}" && echo true || echo false)"
  fi
done < "${tmp}/roots" > "${tmp}/loaders"

# mod.info of each folder and map.info of each map as lines (ending at \n, \r\n or a lone \r, as Java's readLine
# reads them), without blank lines and those that start with description=: "<kind>\t<owner>" for each file, then
# "<kind>\t<owner>\t<line>".
{
  awk -F '\t' '{ print "mod.info\t" $2 "\t" $2 "/mod.info" }' "${tmp}/roots"
  awk -F '\t' '{ print "map.info\t" $4 "\t" $4 "/map.info" }' "${tmp}/maps"
} | while IFS=$'\t' read -r kind owner file; do
  [ ! -f "${file}" ] || printf '%s\t%s\t%s\n' "${kind}" "${owner}" "${file}"
done | LC_ALL=C awk -F '\t' '
  {
    print $1 "\t" $2
    text = ""
    while ((getline line < $3) > 0) text = text line "\n"
    close($3)
    gsub(/\r\n/, "\n", text)
    gsub(/\r/, "\n", text)
    n = split(text, lines, "\n")
    for (i = 1; i <= n; i++) {
      t = lines[i]
      gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t != "" && substr(t, 1, 12) != "description=") print $1 "\t" $2 "\t" lines[i]
    }
  }
' > "${tmp}/lines"

jq -n -c --argjson format "${INDEX_FORMAT}" --arg id "$2" --arg title "$3" --argjson updated "$4" \
  --rawfile roots "${tmp}/roots" --rawfile maps "${tmp}/maps" --rawfile cells "${tmp}/cells" \
  --rawfile spawns "${tmp}/spawns" --rawfile titles "${tmp}/titles" --rawfile rooms "${tmp}/rooms" \
  --rawfile zones "${tmp}/zones" --rawfile stops "${tmp}/stops" --rawfile loaders "${tmp}/loaders" --rawfile lines "${tmp}/lines" '
  def rows: split("\n") | map(select(length > 0) | split("\t"));
  ($cells | rows | map({key: .[0], value: (.[1] | fromjson)}) | from_entries) as $cells
  | ($spawns | rows | map({key: (.[0] | rtrimstr("/spawnpoints.lua")), value: (.[1:] | map(split(",") | map(tonumber)))}) | from_entries) as $spawns
  | ($rooms | rows | map(if .[0] == "?" then .[1:] else . end) | group_by(.[0])
      | map({key: .[0][0], value: map(.[1:] | map(tonumber))}) | from_entries) as $rooms
  | ($stops | rows | map({key: .[0], value: (.[1] | tonumber)}) | from_entries) as $stops
  | ($zones | rows | group_by(.[0]) | map({key: .[0][0], value: (map({key: .[1], value: $stops[.[0] + "/" + .[1]]}) | from_entries)})
      | from_entries) as $zones
  | ($loaders | rows | map({key: .[0], value: (.[1] == "true")}) | from_entries) as $loaders
  | ($lines | rows | group_by(.[0] + "\t" + .[1])
      | map({key: (.[0][0] + "\t" + .[0][1]), value: map(select(length > 2) | .[2:] | join("\t"))}) | from_entries) as $lines
  | ($titles | rows) as $titles
  | ($maps | rows) as $maps
  | {format: $format, id: $id, title: $title, timeUpdated: $updated,
     mods: ($roots | rows | group_by(.[0]) | map({folder: .[0][0], roots: map(.[0] as $mod | .[1] as $root | (.[2] // "") as $path | {path: $path,
       modInfo: $lines["mod.info\t" + $root], zoneLoader: $loaders[$root],
       maps: [$maps[] | select(.[1] == $mod and (.[4] // "") == $path) | .[3] as $map
         | {name: .[2], cells: ($cells[$map] // []), spawns: $spawns[$map], rooms: ($rooms[$map] // []), zones: ($zones[$map] // {}),
            mapInfo: $lines["map.info\t" + $map],
            title: ([$lines["map.info\t" + $map][]? | gsub("^[ \t]+|[ \t]+$"; "") | select(startswith("title=")) | gsub("title="; "")] | last)}],
       translations: ($titles | map(select(.[1] == $root)) | group_by(.[2])
         | map({name: .[0][2],
             json: (first(.[] | select(.[0] == "json") | .[3] | try fromjson catch null | select(type == "string" and length > 0)) // null),
             txt: (first(.[] | select(.[0] == "txt") | .[3]) // null)})
         | map(select(.json != null or .txt != null)))})}))}'
