#!/bin/bash
# Tests the request and freshness checks against a fake Steam and a fake gh. Run: bash test/run.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILED=0

fail() { echo "FAIL [${TEST}]: $*" >&2; FAILED=1; }
expect_eq() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

# Steam answers from FAKE_ITEMS ({"<id>": details}); an ID it doesn't have gets result 9, and it leaves out
# FAKE_STEAM_SKIP. Its Workshop query ranks FAKE_RANKED (IDs separated by spaces), 100 a page, and logs its
# parameters. GitHub lists FAKE_ISSUES, then FAKE_ISSUES_2 as the second page.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/curl" <<'EOF'
#!/bin/bash
if [[ "${*: -1}" == https://api.github.com/* ]]; then
  printf '%s\n' "${*: -1}" >> "${WORK}/github-calls"
  case "${*: -1}" in
    *'&page=1') printf '%s\n' "${FAKE_ISSUES:-[]}" ;;
    *'&page=2') printf '%s\n' "${FAKE_ISSUES_2:-[]}" ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
if [ "${*: -1}" = https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/ ]; then
  page=1 params=()
  for arg; do
    [[ "${arg}" == page=* ]] && page="${arg#page=}"
    [[ "${arg}" == *=* ]] && params+=("${arg}")
  done
  echo "${params[*]}" >> "${WORK}/query-calls"
  [ -n "${FAKE_QUERY_DOWN:-}" ] && exit 22
  [ -n "${FAKE_QUERY_BAD:-}" ] && { echo '{"response": {}}'; exit 0; }
  read -r -a ranked <<< "${FAKE_RANKED:-}"
  printf '%s\n' "${ranked[@]:$(((page - 1) * 100)):100}" | jq -R . | jq -s -c --argjson total "${#ranked[@]}" \
    'map(select(length > 0)) | {response: {total: $total, publishedfiledetails: map({publishedfileid: .})}}'
  exit 0
fi
[ -n "${FAKE_STEAM_DOWN:-}" ] && exit 7
ids=()
for arg; do
  [[ "${arg}" =~ ^publishedfileids\[[0-9]+\]=(.*)$ ]] && [ "${BASH_REMATCH[1]}" != "${FAKE_STEAM_SKIP:-}" ] && ids+=("${BASH_REMATCH[1]}")
done
printf '%s\n' "${ids[@]}" | jq -R . | jq -s -c --argjson items "${FAKE_ITEMS:-{\}}" \
  '{response: {publishedfiledetails: map(. as $id | $items[$id] // {publishedfileid: $id, result: 9})}}'
EOF
# gh logs each call on a line, its arguments joined by " | ", lists FAKE_OPEN as the open issues and numbers the
# issues it creates from 20.
cat > "${WORK}/bin/gh" <<'EOF'
#!/bin/bash
(IFS='|'; printf '%s\n' "$*" | sed 's/|/ | /g') >> "${WORK}/gh-calls"
[ "$1 $2" = "issue list" ] && printf '%s\n' "${FAKE_OPEN:-[]}"
if [ "$1 $2" = "issue create" ]; then
  echo "https://github.com/owner/index/issues/$((20 + $(grep -c '^issue | create' "${WORK}/gh-calls") - 1))"
fi
exit 0
EOF
# sleep logs what it is asked to wait, and doesn't.
cat > "${WORK}/bin/sleep" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${WORK}/sleep-calls"
EOF
chmod +x "${WORK}/bin/curl" "${WORK}/bin/gh" "${WORK}/bin/sleep"
export WORK PATH="${WORK}/bin:${PATH}"

# The room reader, built as the worker image builds it.
if ! javac -Xlint:all,-serial -Werror -d "${WORK}/rooms" "${REPO}/worker/ReadSpawnRooms.java" \
  || ! jar --create --file "${WORK}/read_spawn_rooms.jar" --main-class ReadSpawnRooms -C "${WORK}/rooms" .; then
  echo "The room reader did not compile (the tests need a JDK)" >&2
  exit 1
fi
export ROOMS_READER="${WORK}/read_spawn_rooms.jar"

# Writes a cell header the way the game's map tools do: $1 = file, $2 = 42 (version 1, with the magic),
# 42.0 (version 0, without) or 41, then one argument per room, "room <name> <level> <objects> <x> <y> <w> <h>...",
# or per building, "building <room index>...".
lotheader() {
  local file="$1" layout="$2" item i
  shift 2
  local -a rooms=() buildings=() words
  for item; do
    case "${item}" in
      room\ *) rooms+=("${item}") ;;
      building\ *) buildings+=("${item}") ;;
    esac
  done
  int() {
    local v=$(( $1 & 0xFFFFFFFF ))
    # shellcheck disable=SC2059 # the format is the bytes
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( v & 255 )) $(( v >> 8 & 255 )) $(( v >> 16 & 255 )) $(( v >> 24 & 255 )))"
  }
  {
    if [ "${layout}" = 42 ]; then printf LOTH; int 1; else int 0; fi
    int 2
    printf 'tile_one\r\ntile_two\n'
    [ "${layout}" = 42 ] || printf '\001'
    if [ "${layout}" = 41 ]; then int 10; int 10; else int 8; int 8; fi
    if [ "${layout}" = 42 ]; then int -1; int 2; else int 3; fi
    int "${#rooms[@]}"
    for item in "${rooms[@]}"; do
      read -r -a words <<< "${item}"
      printf '%s\n' "${words[1]}"
      int "${words[2]}"
      int $(( (${#words[@]} - 4) / 4 ))
      for ((i = 4; i < ${#words[@]}; i++)); do int "${words[i]}"; done
      int "${words[3]}"
      for ((i = 0; i < words[3] * 3; i++)); do int 7; done
    done
    int "${#buildings[@]}"
    for item in "${buildings[@]}"; do
      read -r -a words <<< "${item}"
      int $(( ${#words[@]} - 1 ))
      for ((i = 1; i < ${#words[@]}; i++)); do int "${words[i]}"; done
    done
    head -c "$([ "${layout}" = 41 ] && echo 900 || echo 1024)" /dev/zero
  } > "${file}"
}

LABELS='label | create | add | --color | 1d76db | --description | A map to add to the index | --force
label | create | update | --color | fbca04 | --description | A map that changed since it was indexed | --force
label | create | gone | --color | b60205 | --description | A map the Workshop no longer has | --force
label | create | ready | --color | 0e8a16 | --description | Checked, waiting for the worker | --force'

details() {
  # $1 = id, $2 = title, $3 = updated, then: app, banned, tags (comma separated)
  jq -n -c --arg id "$1" --arg title "$2" --argjson updated "$3" --argjson app "${4:-108600}" --argjson banned "${5:-0}" --arg tags "${6-Build 42,Map}" \
    '{publishedfileid: $id, result: 1, consumer_app_id: $app, title: $title, time_updated: $updated, file_size: "120169463", banned: $banned,
      tags: ($tags | split(",") | map(select(length > 0) | {tag: .}))}'
}
RAVEN="$(details 3484263516 "Raven Creek B42" 1789883053)"

# Runs the request check, from a copy with an index of its own (${WORK}/request/items), on an issue: $1 = body,
# $2 = number, $3 = state, $4 = title, $5 = labels (comma separated).
request() {
  jq -n --arg body "$1" --argjson number "${2:-9}" --arg state "${3:-open}" --arg title "${4:-Add a map}" --arg labels "${5-add}" \
    '{issue: {number: $number, state: $state, title: $title, body: $body, labels: ($labels | split(",") | map(select(length > 0) | {name: .}))}}' \
    > "${WORK}/event.json"
  rm -f "${WORK}/gh-calls"
  GITHUB_EVENT_PATH="${WORK}/event.json" bash "${WORK}/request/ci/request.sh"
}
calls() { cat "${WORK}/gh-calls" 2> /dev/null; }
form() { printf '### Workshop item\n\n%s\n' "$1"; }

test_request() {
  TEST=request
  mkdir -p "${WORK}/request/items"
  cp -r "${REPO}/ci" "${WORK}/request/"
  export FAKE_ITEMS
  FAKE_ITEMS="$(jq -n -c --argjson raven "${RAVEN}" --argjson other "$(details 111 "Other App" 1 999)" \
    --argjson banned "$(details 222 "Banned Map" 1 108600 1)" --argjson untagged "$(details 333 "Not a Map" 1 108600 0 "Build 42,Items")" \
    '{"3484263516": $raven, "111": $other, "222": $banned, "333": $untagged}')"
  local queued
  queued="Queued: Raven Creek B42, about 115 MB, updated on the Workshop on $(date -u -d @1789883053 +%Y-%m-%d). This issue closes when the index has it."

  # Issues that aren't requests, and closed ones, are left alone.
  request 'Something else'; expect_eq "$(calls)" ""
  request "$(form 3484263516)" 9 closed; expect_eq "$(calls)" ""

  # A link, with more after the ID, or the ID alone, with the form's carriage returns.
  for field in 'https://steamcommunity.com/sharedfiles/filedetails/?id=3484263516&searchtext=raven' '  3484263516 '; do
    request "$(form "${field}" | sed 's/$/\r/')"
    expect_eq "$(calls)" "${LABELS}
issue | list | --state | open | --limit | 1000 | --json | number,title
issue | edit | 9 | --title | Add Raven Creek B42 (3484263516) | --add-label | add,ready
issue | comment | 9 | --body | ${queued}"
  done

  # What the index can't take is closed with the reason.
  while IFS='|' read -r field reason; do
    request "$(form "${field}")"
    expect_eq "$(calls)" "${LABELS}
issue | comment | 9 | --body | ${reason}
issue | close | 9 | --reason | not planned"
  done <<'EOF'
Raven Creek B42|This needs a Workshop link (https://steamcommunity.com/sharedfiles/filedetails/?id=...) or the item's ID. Edit it in and reopen the issue.
Raven Creek 42|This needs a Workshop link (https://steamcommunity.com/sharedfiles/filedetails/?id=...) or the item's ID. Edit it in and reopen the issue.
?id=123456789012345678901|This needs a Workshop link (https://steamcommunity.com/sharedfiles/filedetails/?id=...) or the item's ID. Edit it in and reopen the issue.
444|Steam has no public Workshop item with the ID 444.
111|Workshop item 111 isn't for Project Zomboid.
222|Steam has banned Workshop item 222.
333|Workshop item 333 isn't tagged Map on the Workshop, so the index doesn't take it.
EOF

  # Queued in another open issue already; this issue's own title doesn't count.
  FAKE_OPEN='[{"number": 7, "title": "Add Raven Creek B42 (3484263516)"}, {"number": 8, "title": "Add Other (13484263516)"}]' request "$(form 3484263516)"
  expect_eq "$(calls | tail -n 2)" "issue | comment | 9 | --body | Raven Creek B42 is queued in #7 already.
issue | close | 9 | --reason | not planned"
  FAKE_OPEN='[{"number": 9, "title": "Add Raven Creek B42 (3484263516)"}, {"number": 6, "title": "Add Town (3484263516) (555)"}]' \
    request "$(form 3484263516)" 9 open 'Add a map'
  expect_eq "$(calls | tail -n 1)" "issue | comment | 9 | --body | ${queued}"
  # An edit that changes nothing.
  request "$(form 3484263516)" 9 open 'Add Raven Creek B42 (3484263516)' add,ready
  expect_eq "$(calls)" "${LABELS}
issue | list | --state | open | --limit | 1000 | --json | number,title"

  # In the index: current, or older than the Workshop's.
  printf '{"format": 2, "id": "3484263516", "title": "Raven Creek B42", "timeUpdated": 1789883053}\n' > "${WORK}/request/items/3484263516.json"
  request "$(form 3484263516)"
  expect_eq "$(calls | tail -n 2)" "issue | comment | 9 | --body | Raven Creek B42 is in the index already, from its update of $(date -u -d @1789883053 +%Y-%m-%d).
issue | close | 9 | --reason | completed"
  printf '{"format": 2, "id": "3484263516", "title": "Raven Creek B42", "timeUpdated": 1700000000}\n' > "${WORK}/request/items/3484263516.json"
  request "$(form 3484263516)"
  expect_eq "$(calls | tail -n 2)" "issue | edit | 9 | --title | Update Raven Creek B42 (3484263516) | --add-label | update,ready | --remove-label | add
issue | comment | 9 | --body | Queued: the index has Raven Creek B42 from its update of $(date -u -d @1700000000 +%Y-%m-%d); it changed on $(date -u -d @1789883053 +%Y-%m-%d). This issue closes when the index has it."
  # Current, but of an older format.
  for entry in '"format": 1, ' ''; do
    printf '{%s"id": "3484263516", "title": "Raven Creek B42", "timeUpdated": 1789883053}\n' "${entry}" > "${WORK}/request/items/3484263516.json"
    request "$(form 3484263516)"
    expect_eq "$(calls | tail -n 2)" "issue | edit | 9 | --title | Update Raven Creek B42 (3484263516) | --add-label | update,ready | --remove-label | add
issue | comment | 9 | --body | Queued: the index has Raven Creek B42 in an older format, so it is read again. This issue closes when the index has it."
  done

  # Without Steam the check fails and leaves the issue as it is.
  FAKE_STEAM_DOWN=1 request "$(form 3484263516)" > /dev/null && fail "the check passed without Steam"
  expect_eq "$(calls)" "${LABELS}"
}

test_freshness() {
  TEST=freshness
  local repo="${WORK}/fresh"
  mkdir -p "${repo}/items"
  cp -r "${REPO}/ci" "${repo}/"
  # Nothing indexed asks nothing.
  rm -f "${WORK}/gh-calls"
  bash "${repo}/ci/freshness.sh" || fail "the check failed without items"
  expect_eq "$(calls)" ""

  # Items with a map, and items without map folders: 8 and 9 changed on the Workshop since a version the index has
  # from 89 and 90 days ago, 10 since one from a day ago.
  local now day=86400 map='[{"folder": "M", "roots": [{"path": "", "maps": [{"name": "M"}]}]}]'
  now="$(date +%s)"
  for item in "1 Current 100 2 ${map}" "2 Changed 100 2 ${map}" "3 Removed 100 2 []" "4 Banned 100 2 []" "5 Queued 100 2 []" \
    "6 Elsewhere 100 2 []" "7 Older 100 1 ${map}" "8 Tiles $((now - 89 * day)) 2 []" "9 Tools $((now - 90 * day - 60)) 2 []" \
    "10 Fresh $((now - day)) 2 ${map}"; do
    read -r id title updated format mods <<< "${item}"
    printf '{"format": %s, "id": "%s", "title": "%s", "timeUpdated": %s, "mods": %s}\n' "${format}" "${id}" "${title}" "${updated}" "${mods}" \
      > "${repo}/items/${id}.json"
  done
  export FAKE_ITEMS
  FAKE_ITEMS="$(jq -n -c --argjson current "$(details 1 Current 100)" --argjson changed "$(details 2 "Changed Again" 200)" \
    --argjson banned "$(details 4 Banned 100 108600 1)" --argjson queued "$(details 5 Queued 300)" --argjson elsewhere "$(details 6 Elsewhere 100 999)" \
    --argjson older "$(details 7 "Older Format" 100)" --argjson tiles "$(details 8 Tiles "${now}")" --argjson tools "$(details 9 Tools "${now}")" \
    --argjson fresh "$(details 10 Fresh "${now}")" \
    '{"1": $current, "2": $changed, "4": $banned, "5": $queued, "6": $elsewhere, "7": $older, "8": $tiles, "9": $tools, "10": $fresh}')"
  rm -f "${WORK}/gh-calls" "${WORK}/sleep-calls"
  FAKE_OPEN='[{"number": 3, "title": "Update Queued (5)"}]' bash "${repo}/ci/freshness.sh" || fail "the check failed"
  expect_eq "$(calls)" "${LABELS}
issue | list | --state | open | --limit | 1000 | --json | number,title
issue | create | --title | Update Fresh (10) | --label | update,ready | --body | Fresh changed on the Workshop on $(date -u -d "@${now}" +%Y-%m-%d); the index has it from $(date -u -d "@$((now - day))" +%Y-%m-%d). https://steamcommunity.com/sharedfiles/filedetails/?id=10
issue | create | --title | Update Changed Again (2) | --label | update,ready | --body | Changed Again changed on the Workshop on $(date -u -d @200 +%Y-%m-%d); the index has it from $(date -u -d @100 +%Y-%m-%d). https://steamcommunity.com/sharedfiles/filedetails/?id=2
issue | create | --title | Gone Removed (3) | --label | gone,ready | --body | The Workshop no longer has Removed as a Project Zomboid item (removed). https://steamcommunity.com/sharedfiles/filedetails/?id=3
issue | create | --title | Gone Banned (4) | --label | gone,ready | --body | The Workshop no longer has Banned as a Project Zomboid item (banned). https://steamcommunity.com/sharedfiles/filedetails/?id=4
issue | create | --title | Gone Elsewhere (6) | --label | gone,ready | --body | The Workshop no longer has Elsewhere as a Project Zomboid item (not for Project Zomboid). https://steamcommunity.com/sharedfiles/filedetails/?id=6
issue | create | --title | Update Older Format (7) | --label | update,ready | --body | The index has Older Format in an older format, so the worker reads it again. https://steamcommunity.com/sharedfiles/filedetails/?id=7
issue | create | --title | Update Tools (9) | --label | update,ready | --body | Tools changed on the Workshop on $(date -u -d "@${now}" +%Y-%m-%d); the index has it from $(date -u -d "@$((now - 90 * day - 60))" +%Y-%m-%d). https://steamcommunity.com/sharedfiles/filedetails/?id=9"
  # A second between new issues.
  expect_eq "$(paste -sd ' ' "${WORK}/sleep-calls")" "1 1 1 1 1 1"

  # Without Steam, or with an item left out of its answer, it fails before touching any issue.
  rm -f "${WORK}/gh-calls"
  FAKE_STEAM_DOWN=1 bash "${repo}/ci/freshness.sh" > /dev/null && fail "the check passed without Steam"
  FAKE_STEAM_SKIP=4 bash "${repo}/ci/freshness.sh" > /dev/null && fail "the check passed with an item left out"
  expect_eq "$(calls)" ""
}


# Makes the folder of a Workshop item: $1 = folder. Mod Town (Build 42) has its cells, spawn points, zones and
# mod.info in 42/, its title only in common/'s translations and a zone loader that fails in common/; Old (Build 41
# layout) has a map without map.info and one with a building, and a zone loader that works; Empty has no mod files.
make_item() {
  local item="$1"
  mkdir -p "${item}/mods/Town/42/media/maps/Town" "${item}/mods/Town/common/media/maps/Town" "${item}/mods/Town/common/media/lua/shared/Translate/EN/Town" \
    "${item}/mods/Old/media/maps/Old Map" "${item}/mods/Old/media/maps/Bare" "${item}/mods/Empty/42"
  touch "${item}/mods/Town/42/media/maps/Town/"{12_5,10_6,x_1,1_2_3}.lotheader \
    "${item}/mods/Town/42/media/maps/Town/13_5.lotheader.bak" "${item}/mods/Old/mod.info" "${item}/mods/Old/media/maps/Old Map/"{0_0,-1_0}.lotheader
  printf 'title=Old\r\nlots=Muldraugh, KY\r  title=Town  \r\n\n description=Hidden\n' > "${item}/mods/Town/42/media/maps/Town/map.info"
  printf 'description=No title\n' > "${item}/mods/Old/media/maps/Old Map/map.info"
  printf '%s\n' 'function SpawnPoints()' 'return { unemployed = { { worldX = 10, worldY = 5, posX = 12, posY = 34, posZ = 1 },' \
    '  { posX = 2600, posY = 1290 }, -- { posX = 9, posY = 9 },' '  { posX = 7 }, { worldX = 1, posX = 5, posY = 5 } },' \
    'chef = { { posX = 2600, posY = 1290 }, { posX = 3100, posY = 1600 } } }' 'end' > "${item}/mods/Town/42/media/maps/Town/spawnpoints.lua"
  # 11_5 has a kitchen on level 1 holding a point; 10_5 has only the outside around another; 12_5 can't be read.
  lotheader "${item}/mods/Town/42/media/maps/Town/11_5.lotheader" 42 'room kitchen 1 2 190 250 10 10' 'building 0'
  lotheader "${item}/mods/Town/42/media/maps/Town/10_5.lotheader" 42 'room emptyoutside 0 0 30 0 20 20' 'building 0'
  printf 'name=Town\r\nid=Town\rdescription=A town\n\n  require=TilePack \nposter=poster.png' > "${item}/mods/Town/42/mod.info"
  printf '%s\n' 'objects = {' '  { name = "", type = "ParkingStall", x = 1, y = 2, z = 0, width = 3, height = 4 },' \
    '  { name = "", type = "Mannequin", geometry = "point", points = { 5, 6 } },' '}' > "${item}/mods/Town/42/media/maps/Town/objects.lua"
  printf 'regions = {}\n' > "${item}/mods/Town/42/media/maps/Town/regions.lua"
  mkdir -p "${item}/mods/Town/common/media/lua/server/metazones" "${item}/mods/Old/media/lua/server/metazones" "${item}/mods/Old/media/maps/Farm"
  printf '%s\n' "error('..v.x..','..v.y..','..v.z)" 'local right = v.x + v.width' > "${item}/mods/Town/common/media/lua/server/metazones/metazoneHandler.lua"
  printf -- '-- fixed\n' > "${item}/mods/Old/media/lua/server/metazones/metazoneHandler.lua"
  # Old's Farm (Build 41 cells of 300 squares) has a barn holding its point.
  lotheader "${item}/mods/Old/media/maps/Farm/0_0.lotheader" 41 'room barn 0 0 45 55 10 10' 'building 0'
  printf 'function SpawnPoints() return { unemployed = { { worldX = 0, worldY = 0, posX = 50, posY = 60 } } } end\n' \
    > "${item}/mods/Old/media/maps/Farm/spawnpoints.lua"
  printf 'function SpawnPoints() return {} end\n' > "${item}/mods/Old/media/maps/Bare/spawnpoints.lua"
  printf '\357\273\277  Town Proper \r\nsecond\r\n' > "${item}/mods/Town/common/media/lua/shared/Translate/EN/Town/title.txt"
  printf '{\n  "description": "A \\"title\\": inside",\n  "title" : "Town \\"J\\" \\u00e9"\n}\n' > "${item}/mods/Town/common/media/lua/shared/Translate/EN/Town.json"
  mkdir -p "${item}/mods/Old/media/lua/shared/Translate/EN"
  printf '{ "title": "" }\n' > "${item}/mods/Old/media/lua/shared/Translate/EN/Old Map.json"
  printf '{ "title": "Not a map" }\n' > "${item}/mods/Town/common/media/lua/shared/Translate/EN/Sandbox.json"
}
ITEM_JSON='{"format":2,"id":"123","title":"Town Pack","timeUpdated":200,"mods":[{"folder":"Old","roots":[{"path":"","modInfo":[],"zoneLoader":false,"maps":[{"name":"Bare","cells":[],"spawns":[],"rooms":[],"zones":{},"mapInfo":null,"title":null},{"name":"Farm","cells":[[0,0,0]],"spawns":[[50,60,0]],"rooms":[[50,60,0,45,55]],"zones":{},"mapInfo":null,"title":null},{"name":"Old Map","cells":[[0,-1,0]],"spawns":null,"rooms":[],"zones":{},"mapInfo":[],"title":null}],"translations":[]}]},{"folder":"Town","roots":[{"path":"42","modInfo":["name=Town","id=Town","  require=TilePack ","poster=poster.png"],"zoneLoader":null,"maps":[{"name":"Town","cells":[[5,10,12],[6,10,10]],"spawns":[[3012,1534,1],[2600,1290,0],[3100,1600,0]],"rooms":[[3012,1534,1,3006,1530],[3100,1600,0]],"zones":{"objects.lua":3,"regions.lua":null},"mapInfo":["title=Old","lots=Muldraugh, KY","  title=Town  "],"title":"Town"}],"translations":[]},{"path":"common","modInfo":null,"zoneLoader":true,"maps":[{"name":"Town","cells":[],"spawns":null,"rooms":[],"zones":{},"mapInfo":null,"title":null}],"translations":[{"name":"Town","json":"Town \"J\" é","txt":"Town Proper"}]}]}]}'

test_index_item() {
  TEST='index item'
  make_item "${WORK}/item"
  expect_eq "$(bash "${REPO}/worker/index_item.sh" "${WORK}/item" 123 "Town Pack" 200 2> "${WORK}/index-err")" "${ITEM_JSON}"
  grep -qxF "Warning: ${WORK}/item/mods/Town/42/media/maps/Town/12_5.lotheader could not be read (java.io.EOFException), so the buildings on its cell are unknown" \
    "${WORK}/index-err" || fail "no warning of the header that can't be read: $(cat "${WORK}/index-err")"
  mkdir -p "${WORK}/nothing"
  expect_eq "$(bash "${REPO}/worker/index_item.sh" "${WORK}/nothing" 9 "Nothing" 1)" '{"format":2,"id":"9","title":"Nothing","timeUpdated":1,"mods":[]}'
}

test_work() {
  TEST=work
  local dir="${WORK}/work"
  mkdir -p "${dir}/items" "${dir}/cache" "${dir}/library/content/108600" "${dir}/steamcmd" "${dir}/content"
  make_item "${dir}/content/123"
  make_item "${dir}/content/789"
  make_item "${dir}/content/654"
  make_item "${dir}/library/content/108600/456"
  make_item "${dir}/library/content/108600/789"
  make_item "${dir}/library/content/108600/654"
  printf '{"id": "999"}\n' > "${dir}/items/999.json"
  printf '%s\n' '"AppWorkshop"' '{' '	"WorkshopItemsInstalled"' '	{' '		"456"' '		{' '			"size"		"1"' '			"timeupdated"		"300"' '		}' \
    '		"789"' '		{' '			"timeupdated"		"100"' '		}' '	}' '	"WorkshopItemDetails"' '	{' '		"789"' '		{' '			"timeupdated"		"900"' '		}' '		"654"' '		{' '			"timeupdated"		"900"' '		}' '	}' '}' \
    > "${dir}/library/appworkshop_108600.acf"
  # SteamCMD downloads what FAKE_CONTENT has, except 321, and 322 only partly.
  cat > "${dir}/steamcmd/steamcmd.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${WORK}/steamcmd-calls"
id="${@: -2:1}"
echo "${id}:$(ls "$2/steamapps/workshop/content/108600" 2> /dev/null | paste -sd ,)" >> "${WORK}/steamcmd-found"
if [ "${id}" = 321 ]; then echo "ERROR! Timeout downloading item 321"; exit 0; fi
if [ "${id}" = 322 ]; then mkdir -p "$2/steamapps/workshop/content/108600/322/mods"; echo "ERROR! Download item 322 failed (Failure)."; exit 0; fi
mkdir -p "$2/steamapps/workshop/content/108600"
cp -r "${FAKE_CONTENT}/${id}" "$2/steamapps/workshop/content/108600/"
echo "Success. Downloaded item ${id} to \"$2/steamapps/workshop/content/108600/${id}\" (1 bytes)"
EOF
  chmod +x "${dir}/steamcmd/steamcmd.sh"
  export FAKE_ITEMS FAKE_ISSUES FAKE_CONTENT="${dir}/content"
  FAKE_ITEMS="$(jq -n -c --argjson town "$(details 123 "Town Pack" 200)" --argjson local "$(details 456 "Local Map" 300)" \
    --argjson stale "$(details 789 "Stale Map" 200)" --argjson back "$(details 555 "Back" 1)" --argjson broken "$(details 321 "Broken" 5)" \
    --argjson partial "$(details 322 "Partial" 5)" --argjson untagged "$(details 333 "Untagged" 5 108600 0 "Build 42")" --argjson details "$(details 654 "Details Only" 500)" \
    '{"123": $town, "456": $local, "789": $stale, "555": $back, "321": $broken, "322": $partial, "333": $untagged, "654": $details}')"
  FAKE_ISSUES='[
    {"number": 1, "title": "Add Town Pack (123)", "labels": [{"name": "add"}, {"name": "ready"}]},
    {"number": 2, "title": "Update Local Map (456)", "labels": [{"name": "update"}, {"name": "ready"}]},
    {"number": 3, "title": "Add Stale Map (789)", "labels": [{"name": "add"}, {"name": "ready"}]},
    {"number": 4, "title": "Gone Removed (999)", "labels": [{"name": "gone"}, {"name": "ready"}]},
    {"number": 5, "title": "Gone Back (555)", "labels": [{"name": "gone"}, {"name": "ready"}]},
    {"number": 6, "title": "Add a map", "labels": [{"name": "add"}, {"name": "ready"}]},
    {"number": 7, "title": "Add Broken (321)", "labels": [{"name": "add"}, {"name": "ready"}]},
    {"number": 9, "title": "Add Partial (322)", "labels": [{"name": "add"}, {"name": "ready"}]},
    {"number": 10, "title": "Update Untagged (333)", "labels": [{"name": "update"}, {"name": "ready"}]},
    {"number": 8, "title": "A fix (123)", "labels": [{"name": "ready"}], "pull_request": {}}]'
  # A full first page, so the worker asks for the second.
  FAKE_ISSUES="$(jq -c '. + [range(100 - length) | {number: (100 + .), title: "A fix (123)", labels: [{name: "ready"}], pull_request: {}}]' <<< "${FAKE_ISSUES}")"
  export FAKE_ISSUES_2='[{"number": 11, "title": "Add Details Only (654)", "labels": [{"name": "add"}, {"name": "ready"}]}]'
  rm -f "${WORK}/github-calls"
  local out worker="${REPO}/worker/work.sh"
  out="$(REPO=owner/index ITEMS_DIR="${dir}/items" CACHE_DIR="${dir}/cache" WORKSHOP_DIR="${dir}/library" STEAMCMDDIR="${dir}/steamcmd" \
    bash "${worker}" 2> "${WORK}/work-err")" || fail "the worker failed: $(cat "${WORK}/work-err")"
  expect_eq "${out}" "$(printf '%s\n' "1	add	123	Town Pack	done" "2	update	456	Local Map	done" "3	add	789	Stale Map	done" \
    "4	remove	999	Removed	done" "5	remove	555	Back	the Workshop has it again" "6	-	-	Add a map	its title has no Workshop ID or it has no add, update or gone label" \
    "7	add	321	Broken	SteamCMD could not download it" "9	add	322	Partial	SteamCMD could not download it" \
    "10	update	333	Untagged	the Workshop says: tag" "11	add	654	Details Only	done")"
  expect_eq "$(jq -c . "${dir}/items/123.json")" "${ITEM_JSON}"
  expect_eq "$(jq -c '[.id, .title, .timeUpdated]' "${dir}/items/456.json" "${dir}/items/789.json" | paste -sd ' ')" '["456","Local Map",300] ["789","Stale Map",200]'
  [ -e "${dir}/items/999.json" ] && fail "the gone item is still in the index"
  [ -e "${dir}/items/321.json" ] && fail "the item that failed to download is in the index"
  # 456 came from the library; 789's copy there is older than the Workshop's and 654 isn't installed in it, so they
  # were downloaded; 321 and 322 three times.
  expect_eq "$(sed -E 's/.* ([0-9]+) \+quit$/\1/' "${WORK}/steamcmd-calls" | paste -sd ' ')" "123 789 321 321 321 322 322 322 654"
  expect_eq "$(head -n 1 "${WORK}/steamcmd-calls")" "+force_install_dir ${dir}/cache +login anonymous +workshop_download_item 108600 123 +quit"
  grep -q '^Reading Local Map (456) from the Steam library$' "${WORK}/work-err" || fail "no word of the library copy: $(cat "${WORK}/work-err")"
  [ -d "${dir}/cache/steamapps/workshop/content/108600/123" ] || fail "the download isn't kept"
  # Dropping downloads: each is gone once read, failed ones too, and the items are indexed as before.
  rm -f "${WORK}/steamcmd-calls" "${WORK}/steamcmd-found" "${WORK}/github-calls" "${dir}/items/123.json"
  out="$(REPO=owner/index ITEMS_DIR="${dir}/items" CACHE_DIR="${dir}/cache" WORKSHOP_DIR="${dir}/library" STEAMCMDDIR="${dir}/steamcmd" \
    DROP_DOWNLOADS=1 bash "${worker}" 2> "${WORK}/work-err")" || fail "the worker failed dropping downloads: $(cat "${WORK}/work-err")"
  expect_eq "$(jq -c . "${dir}/items/123.json")" "${ITEM_JSON}"
  [ -e "${dir}/cache/steamapps/workshop" ] && fail "a download is left: $(find "${dir}/cache" -mindepth 3 -maxdepth 5)"
  # After the first, which finds what the run before kept, each download starts from nothing, after one that failed
  # too; the tries of one download keep what came before.
  expect_eq "$(paste -sd ' ' "${WORK}/steamcmd-found")" "123:123,322,654,789 789: 321: 321: 321: 322: 322:322 322:322 654:"
  expect_eq "$(sed -E 's/.*&page=//' "${WORK}/github-calls" | paste -sd ' ')" "1 2"
  expect_eq "$(head -n 1 "${WORK}/github-calls")" "https://api.github.com/repos/owner/index/issues?state=open&labels=ready&per_page=100&page=1"
}

test_worker_run() {
  TEST='worker run'
  local remote="${WORK}/remote.git" clone="${WORK}/clone"
  # Only this repository's settings.
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  git init --quiet --bare --initial-branch=main "${remote}"
  git clone --quiet "${remote}" "${clone}" 2> /dev/null
  mkdir -p "${clone}/worker" "${clone}/items"
  cp "${REPO}/worker/run.sh" "${clone}/worker/"
  printf '{"id": "999"}\n' > "${clone}/items/999.json"
  printf '{"id": "456"}\n' > "${clone}/items/456.json"
  git -C "${clone}" add --all
  git -C "${clone}" -c user.name=Test -c user.email=test@example.com commit --quiet -m start
  git -C "${clone}" push --quiet origin main
  git -C "${clone}" config user.name Test
  git -C "${clone}" config user.email test@example.com
  # The worker's run: 123 written, 999 removed, 456 as it was, 321 failed.
  cat > "${WORK}/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${WORK}/docker-calls"
[ "$1" = run ] && [ -z "${FAKE_NO_PLAN:-}" ] || exit 0
printf '{"id": "123"}\n' > "${FAKE_CLONE}/items/123.json"
rm -f "${FAKE_CLONE}/items/999.json"
printf '%s\n' "1	add	123	Town Pack	done" "4	remove	999	Removed	done" "2	update	456	Local Map	done" "7	add	321	Broken	SteamCMD could not download it"
EOF
  chmod +x "${WORK}/bin/docker"
  local out
  bash "${clone}/worker/run.sh" --keep 2> "${WORK}/run-err" && fail "run.sh took an unknown option"
  expect_eq "$(cat "${WORK}/run-err")" "usage: run.sh [--drop-downloads]"
  [ -e "${WORK}/docker-calls" ] && fail "run.sh ran docker with an unknown option"
  out="$(FAKE_CLONE="${clone}" WORKSHOP_DIR=/mnt/c/Steam/steamapps/workshop bash "${clone}/worker/run.sh")" || fail "run.sh failed"
  expect_eq "${out}" "$(printf '%s\n' "#1 Town Pack: add" "#4 Removed: remove" "#2 Local Map: unchanged" "#7 Broken: SteamCMD could not download it")"
  expect_eq "$(git -C "${remote}" log --format='%s|%b' main | grep -v '^$' | head -n 2 | paste -sd ' ')" "data: remove Removed (999)|Closes #4 data: add Town Pack (123)|Closes #1"
  expect_eq "$(git -C "${remote}" ls-tree --name-only main items/ | paste -sd ' ')" "items/123.json items/456.json"
  expect_eq "$(sed -n 2p "${WORK}/docker-calls")" "run --rm --volume zomboid-map-index-cache:/cache --volume ${clone}/items:/items --env REPO=${remote%.git} --env DROP_DOWNLOADS=0 --volume /mnt/c/Steam/steamapps/workshop:/workshop:ro zomboid-map-index-worker"
  rm -f "${WORK}/docker-calls"
  FAKE_NO_PLAN=1 bash "${clone}/worker/run.sh" --drop-downloads > /dev/null || fail "run.sh failed dropping downloads"
  expect_eq "$(sed -n 2p "${WORK}/docker-calls")" "run --rm --volume zomboid-map-index-cache:/cache --volume ${clone}/items:/items --env REPO=${remote%.git} --env DROP_DOWNLOADS=1 zomboid-map-index-worker"
}

test_library() {
  TEST=library
  local remote="${WORK}/library-remote.git" clone="${WORK}/library-clone" library="${WORK}/library" out
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  git init --quiet --bare --initial-branch=main "${remote}"
  git clone --quiet "${remote}" "${clone}" 2> /dev/null
  mkdir -p "${clone}/worker" "${clone}/items" "${library}"
  cp -r "${REPO}/ci" "${clone}/"
  cp "${REPO}/worker/library.sh" "${clone}/worker/"
  printf '{"id": "111"}\n' > "${clone}/items/111.json"
  git -C "${clone}" add --all
  git -C "${clone}" -c user.name=Test -c user.email=test@example.com commit --quiet -m start
  git -C "${clone}" push --quiet origin main
  # Installed: an indexed map, a queued one, an item not tagged Map, three maps to offer, a banned one and one the
  # Workshop doesn't have. 999 is only in the details, so it isn't installed.
  {
    printf '%s\n' '"AppWorkshop"' '{' '	"WorkshopItemsInstalled"' '	{'
    for id in 111 222 333 444 555 666 777 888; do
      printf '%s\n' "		\"${id}\"" '		{' '			"size"		"1"' '			"timeupdated"		"5"' '		}'
    done
    printf '%s\n' '	}' '	"WorkshopItemDetails"' '	{' '		"999"' '		{' '			"timeupdated"		"5"' '		}' '	}' '}'
  } > "${library}/appworkshop_108600.acf"
  export FAKE_ITEMS FAKE_OPEN='[{"number": 3, "title": "Add Queued Map (222)"}, {"number": 4, "title": "Add a map"}]'
  FAKE_ITEMS="$(jq -n -c --argjson indexed "$(details 111 "Indexed Map" 5)" --argjson queued "$(details 222 "Queued Map" 5)" \
    --argjson mod "$(details 333 "A Mod" 5 108600 0 "Build 42,Items")" --argjson beta "$(details 444 "Beta Map" 5)" \
    --argjson alpha "$(details 555 "alpha Map" 5)" --argjson banned "$(details 666 "Banned Map" 5 108600 1)" \
    --argjson gamma "$(details 777 "Gamma Map" 5)" --argjson details "$(details 999 "Details Only" 5)" \
    '{"111": $indexed, "222": $queued, "333": $mod, "444": $beta, "555": $alpha, "666": $banned, "777": $gamma, "999": $details}')"
  local list
  list="Maps in ${library} that the index doesn't have:
   1  alpha Map (555), 115 MB
   2  Beta Map (444), 115 MB
   3  Gamma Map (777), 115 MB"
  body() { printf 'issue | create | --title | Add a map | --label | add | --body | ### Workshop item\n\nhttps://steamcommunity.com/sharedfiles/filedetails/?id=%s\n' "$@"; }
  library() {
    rm -f "${WORK}/gh-calls" "${WORK}/sleep-calls"
    WORKSHOP_DIR="${library}" bash "${clone}/worker/library.sh" <<< "$1"
  }

  out="$(library '1 3')" || fail "the pick failed"
  expect_eq "${out}" "${list}
alpha Map: https://github.com/owner/index/issues/20
Gamma Map: https://github.com/owner/index/issues/21
Once the request check queues them, run: WORKSHOP_DIR=\"${library}\" ./worker/run.sh"
  expect_eq "$(calls)" "issue | list | --state | open | --limit | 1000 | --json | number,title
$(body 555 777)"
  expect_eq "$(cat "${WORK}/sleep-calls")" "1"
  # Every one, once, in the list's order.
  for answer in all '3,1-2 2' ' 03 01-02 '; do
    library "${answer}" > /dev/null || fail "the pick '${answer}' failed"
    expect_eq "$(calls | grep -v '^issue | list')" "$(body 555 444 777)"
  done
  # Nothing picked, or a pick that isn't in the list, opens nothing.
  out="$(library '')" || fail "picking nothing failed"
  expect_eq "${out}" "${list}"
  expect_eq "$(calls | grep -c '^issue | create')" 0
  for answer in 4 0 2-1 1-4 'x' '1 x' '1-' '*'; do
    library "${answer}" > /dev/null 2>&1 && fail "the pick '${answer}' passed"
    expect_eq "$(calls | grep -c '^issue | create')" 0
  done
  expect_eq "$(library 4 2>&1 > /dev/null)" "Not in the list: 4"
  expect_eq "$(library x 2>&1 > /dev/null)" "Not a number, a range or all: x"
  # Without Steam it stops before asking.
  FAKE_STEAM_DOWN=1 library 1 > /dev/null 2>&1 && fail "it passed without Steam"
  expect_eq "$(calls | grep -c '^issue | create')" 0
  # A map indexed since: the clone pulls it first.
  git clone --quiet "${remote}" "${WORK}/library-other" 2> /dev/null
  printf '{"id": "555"}\n' > "${WORK}/library-other/items/555.json"
  git -C "${WORK}/library-other" add --all
  git -C "${WORK}/library-other" -c user.name=Test -c user.email=test@example.com commit --quiet -m more
  git -C "${WORK}/library-other" push --quiet origin main
  expect_eq "$(library '' | sed -n 2p)" "   1  Beta Map (444), 115 MB"
  # Nothing left to offer, and a folder that isn't a library.
  FAKE_OPEN='[{"number": 3, "title": "Add Queued Map (222)"}, {"number": 5, "title": "Add Beta Map (444)"}, {"number": 6, "title": "Add Gamma Map (777)"}]' out="$(library 1)" || fail "nothing to offer failed"
  expect_eq "${out}" "The index has or queues every map in ${library}."
  expect_eq "$(WORKSHOP_DIR="${WORK}" bash "${clone}/worker/library.sh" < /dev/null 2>&1)" "${WORK} has no Project Zomboid items: ${WORK}/appworkshop_108600.acf is missing"
}

test_discover() {
  TEST=discover
  local repo="${WORK}/discover" out
  mkdir -p "${repo}/items"
  cp -r "${REPO}/ci" "${repo}/"
  printf '{"format": 2, "id": "1003", "title": "Third", "timeUpdated": 1}\n' > "${repo}/items/1003.json"
  # Ranked: 1001 to 1250. 1002 is banned, 1003 indexed, 1004 queued, 1007 not tagged Map; the Workshop doesn't
  # have those after 1007.
  export FAKE_RANKED FAKE_ITEMS STEAM_API_KEY=fake-key
  FAKE_RANKED="$(seq -s ' ' 1001 1250)"
  FAKE_ITEMS="$(jq -n -c --argjson first "$(details 1001 First 1789883053)" --argjson banned "$(details 1002 Banned 1 108600 1)" \
    --argjson third "$(details 1003 Third 1)" --argjson fourth "$(details 1004 Fourth 1)" \
    --argjson fifth "$(details 1005 Fifth 1789883053)" --argjson sixth "$(details 1006 Sixth 1)" \
    --argjson mod "$(details 1007 "A Mod" 1 108600 0 "Build 42,Items")" \
    '{"1001": $first, "1002": $banned, "1003": $third, "1004": $fourth, "1005": $fifth, "1006": $sixth, "1007": $mod}')"
  export FAKE_OPEN='[{"number": 4, "title": "Add Fourth (1004)", "labels": [{"name": "add"}, {"name": "ready"}]},
    {"number": 5, "title": "A question", "labels": []}]'
  discover() {
    rm -f "${WORK}/gh-calls" "${WORK}/sleep-calls" "${WORK}/query-calls"
    DISCOVER_TOP="$1" DISCOVER_QUEUE="$2" bash "${repo}/ci/discover.sh"
  }
  created() { calls | grep '^issue | create' | sed -E 's/^issue \| create \| --title \| ([^|]*) \|.*/\1/' | paste -sd ',' -; }

  # One queued, two more wanted: the two most subscribed it can take, of the 150 most subscribed.
  out="$(discover 150 3)" || fail "the check failed"
  expect_eq "${out}" "Queued 2 maps."
  expect_eq "$(calls | grep '^issue | create')" "issue | create | --title | Add First (1001) | --label | add,ready | --body | First is one of the 150 most subscribed maps on the Workshop, about 115 MB, updated on $(date -u -d @1789883053 +%Y-%m-%d). https://steamcommunity.com/sharedfiles/filedetails/?id=1001
issue | create | --title | Add Fifth (1005) | --label | add,ready | --body | Fifth is one of the 150 most subscribed maps on the Workshop, about 115 MB, updated on $(date -u -d @1789883053 +%Y-%m-%d). https://steamcommunity.com/sharedfiles/filedetails/?id=1005"
  expect_eq "$(head -n 1 "${WORK}/gh-calls")" "issue | list | --state | open | --limit | 1000 | --json | number,title,labels"
  expect_eq "$(cat "${WORK}/sleep-calls")" "1"
  expect_eq "$(cat "${WORK}/query-calls")" "key=fake-key query_type=9 appid=108600 requiredtags[0]=Map numperpage=100 page=1 ids_only=true
key=fake-key query_type=9 appid=108600 requiredtags[0]=Map numperpage=100 page=2 ids_only=true"
  # Only the most subscribed count, and not more than it wants.
  discover 5 10 > /dev/null || fail "the check failed with a short top"
  expect_eq "$(created)" "Add First (1001),Add Fifth (1005)"
  expect_eq "$(wc -l < "${WORK}/query-calls")" 1
  discover 500 2 > /dev/null || fail "the check failed with one wanted"
  expect_eq "$(created)" "Add First (1001)"
  # Fewer ranked than the top: no more pages.
  FAKE_RANKED="$(seq -s ' ' 1001 1050)" discover 500 10 > /dev/null || fail "the check failed with few ranked"
  expect_eq "$(wc -l < "${WORK}/query-calls")" 1
  expect_eq "$(created)" "Add First (1001),Add Fifth (1005),Add Sixth (1006)"
  # A full queue asks Steam nothing.
  out="$(discover 150 1)" || fail "the check failed with a full queue"
  expect_eq "${out}" "The queue is full: 1 issues are ready for the worker."
  [ -e "${WORK}/query-calls" ] && fail "it queried Steam with a full queue"
  # Without a key, or when Steam fails, it opens nothing.
  STEAM_API_KEY='' discover 150 3 > /dev/null && fail "it passed without a key"
  expect_eq "$(calls)" ""
  for down in FAKE_QUERY_DOWN FAKE_QUERY_BAD FAKE_STEAM_DOWN; do
    (export "${down}=1"; discover 150 3 > /dev/null) && fail "it passed with ${down}"
    expect_eq "$(created)" ""
  done
}

test_site() {
  TEST=site
  local repo="${WORK}/site-repo"
  mkdir -p "${repo}/items" "${repo}/site"
  cp -r "${REPO}/ci" "${repo}/"
  cp "${REPO}/site/grid.js" "${repo}/site/"
  export GAME_VERSIONS='41.78.16 42.21.0'
  # Without entries, an empty index.
  bash "${repo}/ci/site.sh" "${WORK}/site-empty" || fail "the build failed without entries"
  expect_eq "$(cat "${WORK}/site-empty/index.json")" '{"items":[]}'
  # The entries by Workshop ID as numbers; the licence and other files stay out.
  printf '{"id": "20", "title": "Twenty"}\n' > "${repo}/items/20.json"
  printf '{"id": "3", "title": "Three"}\n' > "${repo}/items/3.json"
  cp "${REPO}/items/LICENSE" "${repo}/items/"
  bash "${repo}/ci/site.sh" "${WORK}/site" || fail "the build failed"
  expect_eq "$(cat "${WORK}/site/index.json")" '{"items":[{"id":"3","title":"Three"},{"id":"20","title":"Twenty"}]}'
  expect_eq "$(ls "${WORK}/site" | paste -sd ' ')" "build-41.json build-42.json grid-1.js index.json"
  cmp -s "${WORK}/site/grid-1.js" "${REPO}/site/grid.js" || fail "grid-1.js isn't site/grid.js"
  # The major version names the script.
  sed -i "s/^export const VERSION = '1\.0\.0';$/export const VERSION = '12.3.4';/" "${repo}/site/grid.js"
  bash "${repo}/ci/site.sh" "${WORK}/site-12" || fail "the build failed for version 12"
  expect_eq "$(ls "${WORK}/site-12" | paste -sd ' ')" "build-41.json build-42.json grid-12.js index.json"
  sed -i "s/^export const VERSION = .*/export const VERSION = '2';/" "${repo}/site/grid.js"
  bash "${repo}/ci/site.sh" "${WORK}/site-bad" 2> /dev/null && fail "the build passed without a full version"
}

# Item 7 has Town, read from 42/ (42.22 is newer than the game) and common/ on Build 42 and from the mod folder itself on
# Build 41, and Old, which versionMax keeps from Build 41. Next (20) and Fork (100, another TownMod) share cells with
# Town. Item 3 is of the first format, the folder names of 5, 6 and 8 would leave the mods folder, and 9 has a tab in
# one.
test_builds() {
  TEST=builds
  local repo="${WORK}/builds-repo" out="${WORK}/builds"
  mkdir -p "${repo}/items" "${repo}/site"
  cp -r "${REPO}/ci" "${repo}/"
  cp "${REPO}/site/grid.js" "${repo}/site/"
  export GAME_VERSIONS='41.78.16 42.21.0'
  bash "${repo}/ci/site.sh" "${WORK}/builds-empty" || fail "the build failed without entries"
  expect_eq "$(cat "${WORK}/builds-empty/build-42.json")" '{"gameVersion":"42.21.0","items":[],"maps":[],"conflicts":[],"providers":{}}'
  cat > "${repo}/items/7.json" <<'JSON'
{"format": 2, "id": "7", "title": "Town Pack", "timeUpdated": 1690000000, "mods": [
  {"folder": "Town", "roots": [
    {"path": "", "modInfo": ["name=Town 41", "id=TownMod", "require=TilePack"], "zoneLoader": null,
     "maps": [{"name": "Town", "cells": [[1, 1, 2]], "spawns": [[1, 1, 0]], "rooms": [], "zones": {}, "mapInfo": ["title=Town 41"], "title": "Town 41"}],
     "translations": [{"name": "Town", "json": "Town JSON 41", "txt": "Town TXT"}]},
    {"path": "42", "modInfo": ["name=Town", "id=TownMod", "require=\\TilePack, \\Other", "incompatible=Rival"], "zoneLoader": false,
     "maps": [{"name": "Town", "cells": [[5, 10, 11]], "spawns": null, "rooms": [], "zones": {"objects.lua": 4}, "mapInfo": null, "title": null}],
     "translations": [{"name": "Town", "json": null, "txt": "Town 42 TXT"}]},
    {"path": "42.22", "modInfo": ["name=Too new", "id=TownMod"], "zoneLoader": null,
     "maps": [{"name": "Town", "cells": [[0, 0, 0]], "spawns": [], "rooms": [], "zones": {}, "mapInfo": ["title=Too new"], "title": "Too new"}],
     "translations": []},
    {"path": "common", "modInfo": null, "zoneLoader": true,
     "maps": [{"name": "Town", "cells": [[9, 9, 9]], "spawns": [[1, 1, 0], [2, 2, 0]], "rooms": [], "zones": {"objects.lua": null, "regions.lua": 7},
               "mapInfo": ["title=Common Town"], "title": "Common Town"},
              {"name": "Extra", "cells": [[20, 1, 1]], "spawns": null, "rooms": [], "zones": {}, "mapInfo": null, "title": null}],
     "translations": [{"name": "Town", "json": "Town JSON", "txt": null}, {"name": "Extra", "json": "Extra JSON", "txt": null}]}]},
  {"folder": "Old", "roots": [{"path": "", "modInfo": ["name=Old", "id=OldMod", "versionMax=41.50"], "zoneLoader": null,
    "maps": [{"name": "Old", "cells": [[1, 1, 1]], "spawns": null, "rooms": [], "zones": {}, "mapInfo": null, "title": null}], "translations": []}]}]}
JSON
  cat > "${repo}/items/20.json" <<'JSON'
{"format": 2, "id": "20", "title": "Next Door", "timeUpdated": 5, "mods": [{"folder": "Next", "roots": [
  {"path": "", "modInfo": ["id=NextMod"], "zoneLoader": null,
   "maps": [{"name": "Next", "cells": [[1, 2, 3]], "spawns": null, "rooms": [], "zones": {}, "mapInfo": ["title=Next 41"], "title": "Next 41"}],
   "translations": [{"name": "Next", "json": "Next JSON", "txt": null}]},
  {"path": "42", "modInfo": ["id=NextMod"], "zoneLoader": null,
   "maps": [{"name": "Next", "cells": [[5, 10, 12], [6, 1, 1]], "spawns": [], "rooms": [], "zones": {}, "mapInfo": ["title=Next"], "title": "Next"}],
   "translations": [{"name": "Next", "json": null, "txt": "Next TXT"}]}]}]}
JSON
  cat > "${repo}/items/100.json" <<'JSON'
{"format": 2, "id": "100", "title": "Fork", "timeUpdated": 6, "mods": [{"folder": "Fork", "roots": [
  {"path": "42", "modInfo": ["name=Fork", "id=TownMod"], "zoneLoader": null,
   "maps": [{"name": "Fork", "cells": [[5, 11, 11]], "spawns": null, "rooms": [], "zones": {}, "mapInfo": null, "title": null}], "translations": []},
  {"path": "common", "modInfo": null, "zoneLoader": true, "maps": [], "translations": []}]}]}
JSON
  printf '{"format": 1, "id": "3", "title": "Older", "timeUpdated": 5, "mods": []}\n' > "${repo}/items/3.json"
  printf '{"format": 2, "id": "5", "title": "Up", "timeUpdated": 5, "mods": [{"folder": "..", "roots": [{"path": "", "modInfo": ["id=Up"]}]}]}\n' \
    > "${repo}/items/5.json"
  printf '{"format": 2, "id": "6", "title": "Down", "timeUpdated": 5, "mods": [{"folder": "Down", "roots": [{"path": "42/x", "modInfo": ["id=Down"]}]}]}\n' \
    > "${repo}/items/6.json"
  printf '{"format": 2, "id": "8", "title": "Here", "timeUpdated": 5, "mods": [{"folder": "Here", "roots": [{"path": ".", "modInfo": ["id=Here"]}]}]}\n' \
    > "${repo}/items/8.json"
  printf '{"format": 2, "id": "9", "title": "Tab", "timeUpdated": 5, "mods": [{"folder": "A\\tB", "roots": [{"path": "", "modInfo": ["id=Tab"]}]}]}\n' \
    > "${repo}/items/9.json"
  bash "${repo}/ci/site.sh" "${out}" 2> "${WORK}/builds-err" || fail "the build failed: $(cat "${WORK}/builds-err")"
  expect_eq "$(cat "${WORK}/builds-err")" "$(printf '%s\n' \
    'Warning: item 5 has a folder name no folder can have, so the builds leave it out' \
    'Warning: item 6 has a folder name no folder can have, so the builds leave it out' \
    'Warning: item 8 has a folder name no folder can have, so the builds leave it out' \
    'Warning: item 9 has a folder name no folder can have, so the builds leave it out')"
  expect_eq "$(jq -c '[.gameVersion, [.items[].id]]' "${out}/build-41.json" "${out}/build-42.json")" \
    "$(printf '%s\n' '["41.78.16",["7","20","100"]]' '["42.21.0",["7","20","100"]]')"
  expect_eq "$(jq -c '.items[0]' "${out}/build-42.json")" \
    '{"id":"7","title":"Town Pack","timeUpdated":1690000000,"mods":[{"folder":"Old","id":"OldMod","name":"Old","versionFolder":null,"loads":false,"error":"no mod.info for this game version","require":[],"incompatible":[],"zoneLoader":null,"maps":[]},{"folder":"Town","id":"TownMod","name":"Town","versionFolder":"42","loads":true,"error":"its require= has spaces around Other","require":["TilePack","Other"],"incompatible":["Rival"],"zoneLoader":false,"maps":[0,1]}]}'
  expect_eq "$(jq -c '[.items[1:][].mods[] | [.folder, .name, .versionFolder, .loads, .zoneLoader, .maps]]' "${out}/build-42.json")" \
    '[["Next",null,"42",true,null,[2]],["Fork","Fork","42",true,true,[3]]]'
  expect_eq "$(jq -c '.maps[]' "${out}/build-42.json")" "$(printf '%s\n' \
    '{"item":"7","folder":"Town","name":"Extra","title":null,"cells":[[20,1,1]],"spawns":null,"zones":{}}' \
    '{"item":"7","folder":"Town","name":"Town","title":"Town JSON","cells":[[5,10,11]],"spawns":2,"zones":{"objects.lua":4,"regions.lua":7}}' \
    '{"item":"20","folder":"Next","name":"Next","title":"Next","cells":[[5,10,12],[6,1,1]],"spawns":0,"zones":{}}' \
    '{"item":"100","folder":"Fork","name":"Fork","title":null,"cells":[[5,11,11]],"spawns":null,"zones":{}}')"
  expect_eq "$(jq -c '[.conflicts, .providers]' "${out}/build-42.json")" '[[[1,2,2],[1,3,1],[2,3,1]],{"NextMod":["20"],"TownMod":["7","100"]}]'
  # Build 41 reads the mod folders themselves.
  expect_eq "$(jq -c '.items[0].mods' "${out}/build-41.json")" \
    '[{"folder":"Old","id":"OldMod","name":"Old","versionFolder":"","loads":false,"error":null,"require":[],"incompatible":[],"zoneLoader":null,"maps":[]},{"folder":"Town","id":"TownMod","name":"Town 41","versionFolder":"","loads":true,"error":null,"require":["TilePack"],"incompatible":[],"zoneLoader":null,"maps":[0]}]'
  expect_eq "$(jq -c '[.items[1:][].mods[] | [.folder, .versionFolder, .loads, .error, .maps]]' "${out}/build-41.json")" \
    '[["Next","",true,null,[1]],["Fork",null,false,"no mod.info for this game version",[]]]'
  expect_eq "$(jq -c '.maps[]' "${out}/build-41.json")" "$(printf '%s\n' \
    '{"item":"7","folder":"Town","name":"Town","title":"Town TXT","cells":[[1,1,2]],"spawns":1,"zones":{}}' \
    '{"item":"20","folder":"Next","name":"Next","title":"Next 41","cells":[[1,2,3]],"spawns":null,"zones":{}}')"
  expect_eq "$(jq -c '[.conflicts, .providers]' "${out}/build-41.json")" '[[[0,1,1]],{"NextMod":["20"],"TownMod":["7"]}]'
  # Titles come from Translate/EN/<map>.json from 42.20 on.
  GAME_VERSIONS=42.19.5 bash "${repo}/ci/site.sh" "${WORK}/builds-4219" 2> /dev/null || fail "the build failed for 42.19"
  expect_eq "$(ls "${WORK}/builds-4219" | paste -sd ' ')" "build-42.json grid-1.js index.json"
  expect_eq "$(jq -c '[.maps[].title]' "${WORK}/builds-4219/build-42.json")" '[null,"Town 42 TXT","Next TXT",null]'
  GAME_VERSIONS=42.20 bash "${repo}/ci/site.sh" "${WORK}/builds-4220" 2> /dev/null || fail "the build failed for 42.20"
  expect_eq "$(jq -c '[.maps[].title]' "${WORK}/builds-4220/build-42.json")" '[null,"Town JSON","Next",null]'
  for versions in '' 42 '42.13.0 42.21.0'; do
    GAME_VERSIONS="${versions}" bash "${repo}/ci/site.sh" "${WORK}/builds-bad" 2> "${WORK}/builds-err" \
      && fail "the build passed with GAME_VERSIONS '${versions}'"
  done
  expect_eq "$(cat "${WORK}/builds-err")" 'GAME_VERSIONS has more than one version of Build 42'
  GAME_VERSIONS=42 bash "${repo}/ci/site.sh" "${WORK}/builds-bad" 2> "${WORK}/builds-err"
  expect_eq "$(cat "${WORK}/builds-err")" 'GAME_VERSIONS has 42, which is not a game version like 42.21.0'
}

test_grid() {
  TEST=grid
  node "${REPO}/test/grid.mjs" || fail "the grid tests failed"
}

for t in test_request test_freshness test_index_item test_work test_worker_run test_library test_discover test_site test_builds test_grid; do
  ("${t}"; exit "${FAILED}") || FAILED=1
done
if [ "${FAILED}" = 0 ]; then echo "Tests passed"; else echo "Tests failed"; exit 1; fi
