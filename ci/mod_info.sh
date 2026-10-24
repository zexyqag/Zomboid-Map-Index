#!/bin/bash
# Mod folders as the game reads them.

# Reads the mods in the given mods folders the way the game does (ChooseGameInfo, ZomboidFileSystem).
# Build 41 reads mod.info in the mod folder itself. Build 42 picks the folder with the highest
# version name (42, 42.12, ...) that isn't newer than the game, whether or not it holds a mod.info,
# reads its mod.info or else the one in common/, and compares versions only by major.minor. A
# mod.info in the mod folder itself is read with the Build 41 rules, any other with the Build 42 ones.
mod_info_rows() {
  # $1 = game version ("" when unknown), then the mods folders (<item>/mods, Zomboid/mods).
  # Prints per mod folder, in the order the game lists them: item (the name of the folder above the
  # mods folder), folder, the folder its files come from besides common/ ("." for the mod folder
  # itself, "common" when there is none, "" when the game finds no mod.info, in which case the fields
  # come from another mod.info in it), state (1 when the game finds the mod and it can load on this
  # version, 0 when it finds it but versionMin, versionMax or an empty require entry stop it, - when
  # it doesn't find it, ? for an unknown version), id, name, description, author, modversion, url,
  # category, versionMin, versionMax, the mod IDs of require, loadModAfter, loadModBefore and
  # incompatible, separated by commas, the path of the mod folder, why the game rejects the mod or,
  # when versionMin and versionMax let it load, why it can't load it by itself ("" when nothing), and
  # the require entries as the game looks them up: untrimmed, each followed by a comma.
  local version="$1" dir
  local -a dirs=()
  shift
  for dir in "$@"; do
    [ -d "${dir}" ] && dirs+=("${dir}")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  # Entries come in directory order, like the game's File.list(), which decides between equal
  # versions. The game follows symbolic links, and reads on past a loop of them, where find fails.
  { find -L "${dirs[@]}" -mindepth 1 -maxdepth 3 -printf '%H\t%P\t%y\n' 2> /dev/null || true; } \
    | LC_ALL=C awk -F '\t' -v version="${version}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # Java Integer.parseInt of the trimmed string, with 0 for anything else (PZMath.tryParseInt)
    function number(s) {
      s = trim(s)
      return s ~ /^[+-]?[0-9]+$/ && s + 0 >= -2147483648 && s + 0 <= 2147483647 ? s + 0 : 0
    }
    # Version folder names: the first part times 1000 plus the second, at most 999
    function folder_version(name,   n, p, minor) {
      n = split(name, p, ".")
      if (n == 1) return number(p[1]) * 1000
      minor = number(p[2])
      return number(p[1]) * 1000 + (minor > 999 ? 999 : minor)
    }
    # versionMin, versionMax and the game version: major.minor, -1 when the game cannot parse it
    # (GameVersion.parse)
    function game_version(s,   p) {
      if (!match(s, /^[0-9]+\.[0-9]+/)) return -1
      split(substr(s, 1, RLENGTH), p, ".")
      return number(p[2]) > 999 ? -1 : number(p[1]) * 1000 + number(p[2])
    }
    # Java String.replace(key, ""): every occurrence goes
    function remove(s, key,   out, i) {
      out = ""
      while ((i = index(s, key)) > 0) {
        out = out substr(s, 1, i - 1)
        s = substr(s, i + length(key))
      }
      return out s
    }
    # Build 42 drops every backslash; both split on commas and trim each mod ID.
    function mod_ids(s,   n, parts, i, id, out, seen) {
      if (!old_rules) gsub(/\\/, "", s)
      n = split(s, parts, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        id = trim(parts[i])
        if (id == "" || (id in seen)) continue
        seen[id] = 1
        out = out (out == "" ? "" : ",") id
      }
      return out
    }
    function field(key,   v) { v = trim(info[key]); gsub(/\t/, " ", v); return v }
    # The first line that makes the game reject the whole mod.info (readModInfoAux returns null)
    function reject(why) { if (!("rejected" in info)) info["rejected"] = why }
    # pack=<file> or pack=<file> type=<type>: the game cuts the second at the first space, and fails
    # without one.
    function pack(v) {
      v = trim(v)
      if (v == "") reject("its mod.info has an empty pack= line")
      else if (index(v, "type=") && !index(v, " ")) reject("its mod.info has pack=" v ", which needs a space before type=")
    }
    # tiledef=<file> <number from 100 to highest>
    function tiledef(v, highest,   parts) {
      v = trim(v)
      if (split(v, parts, /[ \t]+/) != 2 || parts[2] !~ /^[+-]?[0-9]+$/ || parts[2] + 0 < 100 || parts[2] + 0 > highest) {
        reject("its mod.info has tiledef=" v ", which needs a file name and a number from 100 to " highest)
      }
    }
    # An empty value leaves the one of an earlier line.
    function bound(key, line,   v) {
      v = remove(line, key "=")
      if (trim(v) == "") return
      info[tolower(key)] = v
      v = field(tolower(key))
      if (game_version(v) < 0) reject("its mod.info has " key "=" v ", which is not a major.minor version like 42.13")
    }
    # The keys are tested in the game'"'"'s order, so a line counts for the first key it contains. Like
    # Java'"'"'s readLine, lines also end at a lone \r, and a byte order mark stays part of the first line.
    function read_info(path, default_id,   text, lines, n, i, line) {
      split("", info)
      info["id"] = default_id
      while ((getline text < path) > 0) {
        n = split(text, lines, "\r")
        for (i = 1; i <= n; i++) {
          line = lines[i]
          if (old_rules) {
            if (index(line, "name=")) info["name"] = remove(line, "name=")
            else if (index(line, "poster=")) continue
            else if (index(line, "description=")) info["description"] = info["description"] remove(line, "description=")
            else if (index(line, "require=")) info["require"] = remove(line, "require=")
            else if (index(line, "id=")) info["id"] = remove(line, "id=")
            else if (index(line, "url=")) info["url"] = remove(line, "url=")
            else if (index(line, "pack=")) pack(remove(line, "pack="))
            else if (index(line, "tiledef=")) tiledef(remove(line, "tiledef="), 16382)
            else if (index(line, "versionMax=") == 1) bound("versionMax", line)
            else if (index(line, "versionMin=") == 1) bound("versionMin", line)
          } else {
            if (index(line, "name=")) { if (trim(remove(line, "name=")) != "") info["name"] = remove(line, "name=") }
            else if (index(line, "poster=")) continue
            else if (index(line, "description=")) info["description"] = info["description"] remove(line, "description=")
            else if (index(line, "require=")) info["require"] = remove(line, "require=")
            else if (index(line, "incompatible=")) info["incompatible"] = remove(line, "incompatible=")
            else if (index(line, "loadModAfter=")) info["loadmodafter"] = remove(line, "loadModAfter=")
            else if (index(line, "loadModBefore=")) info["loadmodbefore"] = remove(line, "loadModBefore=")
            else if (index(line, "id=") == 1) { if (trim(remove(line, "id=")) != "") info["id"] = remove(line, "id=") }
            else if (index(line, "author=")) info["author"] = remove(line, "author=")
            else if (index(line, "modversion=")) info["modversion"] = remove(line, "modversion=")
            else if (index(line, "icon=")) continue
            else if (index(line, "category=")) info["category"] = remove(line, "category=")
            else if (index(line, "url=")) info["url"] = remove(line, "url=")
            else if (index(line, "pack=")) pack(remove(line, "pack="))
            else if (index(line, "tiledef=")) tiledef(remove(line, "tiledef="), 8189)
            else if (index(line, "versionMax=") == 1) bound("versionMax", line)
            else if (index(line, "versionMin=") == 1) bound("versionMin", line)
          }
        }
      }
      close(path)
    }
    # The game checks that the trimmed require entries name mods that can load, then loads them as
    # written (Mod.isAvailableRequired, ZomboidFileSystem.loadModAndRequired), so an empty entry stops
    # the mod and one with spaces around it is never found. Java'"'"'s split drops empty entries only at
    # the end, and "require=" alone is one empty entry.
    function read_require(   s, n, parts, i) {
      require = ""
      empty = 0
      spaced = ""
      if (!("require" in info)) return
      s = info["require"]
      if (!old_rules) gsub(/\\/, "", s)
      gsub(/\t/, " ", s)
      n = split(s, parts, ",")
      while (n > 0 && parts[n] == "") n--
      if (s == "") n = 1
      for (i = 1; i <= n; i++) {
        require = require parts[i] ","
        if (trim(parts[i]) == "") empty = 1
        else if (spaced == "" && parts[i] != trim(parts[i])) spaced = trim(parts[i])
      }
    }
    BEGIN { game = game_version(version) }
    # <mods folder> TAB <path below it> TAB <type>: mod folders, what is in them, and the mod.info
    # files one level further down.
    {
      dir = $1
      sub(/\/+$/, "", dir)
      n = split($2, part, "/")
      key = dir "/" part[1]
      if (n == 1) {
        if ($3 != "d" || tolower(part[1]) == "examplemod") next
        keys[++count] = key
        item[key] = dir
        sub(/\/[^\/]*$/, "", item[key])
        sub(/.*\//, "", item[key])
        folder[key] = part[1]
        best[key] = 42000
        chosen[key] = "42.0"
        next
      }
      if (n == 2) {
        entry[key, part[2]] = 1
        names[key, ++entries[key]] = part[2]
        if (part[2] == "mod.info") info_in[key, "."] = 1
        v = folder_version(part[2])
        if (game >= 0 && v >= best[key] && v <= game) {
          best[key] = v
          chosen[key] = part[2]
        }
        next
      }
      if (part[3] == "mod.info") info_in[key, part[2]] = 1
    }
    END {
      for (i = 1; i <= count; i++) {
        key = keys[i]
        if (game < 0) {
          files = ""
        } else if (game < 42000) {
          files = ((key, ".") in info_in) ? "." : ""
        } else if ((key, chosen[key]) in info_in) {
          files = chosen[key]
          info_dir = chosen[key]
        } else if ((key, "common") in info_in) {
          files = ((key, chosen[key]) in entry) ? chosen[key] : "common"
          info_dir = "common"
        } else {
          files = ""
        }
        if (files == ".") info_dir = "."
        if (files == "") {
          # Not a mod the game sees on this version: show the mod.info most likely meant for it, from
          # common/, the newest version folder that has one, or the mod folder itself.
          info_dir = ""
          if ((key, "common") in info_in) {
            info_dir = "common"
          } else {
            for (j = 1; j <= entries[key]; j++) {
              name = names[key, j]
              if (name ~ /^[0-9]+(\.[0-9]+)*$/ && ((key, name) in info_in) && (info_dir == "" || folder_version(name) > folder_version(info_dir))) info_dir = name
            }
          }
          if (info_dir == "" && ((key, ".") in info_in)) info_dir = "."
          if (info_dir == "") continue
        }
        old_rules = info_dir == "."
        read_info(key "/" info_dir "/mod.info", old_rules ? folder[key] : "")
        read_require()
        # Build 41 keeps spaces around the ID.
        id = info["id"]
        if (old_rules) gsub(/\t/, " ", id)
        else id = field("id")
        error = ""
        if (game < 0) {
          state = "?"
        } else if (files == "") {
          state = "-"
          error = "no mod.info for this game version"
        } else if ("rejected" in info) {
          state = "-"
          error = info["rejected"]
        } else {
          low = game_version(field("versionmin"))
          high = game_version(field("versionmax"))
          # The game checks versionMin and versionMax before the require entries.
          if (low > game || (high >= 0 && high < game)) {
            state = 0
          } else if (empty) {
            state = 0
            error = "its require= has an empty entry"
          } else {
            state = 1
            if (spaced != "") error = "its require= has spaces around " spaced
          }
        }
        print item[key] "\t" folder[key] "\t" files "\t" state "\t" id "\t" field("name") "\t" field("description") "\t" \
          field("author") "\t" field("modversion") "\t" field("url") "\t" field("category") "\t" field("versionmin") "\t" \
          field("versionmax") "\t" mod_ids(info["require"]) "\t" mod_ids(info["loadmodafter"]) "\t" \
          mod_ids(info["loadmodbefore"]) "\t" mod_ids(info["incompatible"]) "\t" key "\t" error "\t" require
      }
    }
  '
}
