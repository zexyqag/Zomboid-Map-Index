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
# FAKE_STEAM_SKIP. GitHub lists FAKE_ISSUES.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/curl" <<'EOF'
#!/bin/bash
if [[ "${*: -1}" == https://api.github.com/* ]]; then
  printf '%s\n' "${FAKE_ISSUES:-[]}"
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
# gh logs each call on a line, its arguments joined by " | ", and lists FAKE_OPEN as the open issues.
cat > "${WORK}/bin/gh" <<'EOF'
#!/bin/bash
(IFS='|'; printf '%s\n' "$*" | sed 's/|/ | /g') >> "${WORK}/gh-calls"
[ "$1 $2" = "issue list" ] && printf '%s\n' "${FAKE_OPEN:-[]}"
exit 0
EOF
chmod +x "${WORK}/bin/curl" "${WORK}/bin/gh"
export WORK PATH="${WORK}/bin:${PATH}"

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
  printf '{"id": "3484263516", "title": "Raven Creek B42", "timeUpdated": 1789883053}\n' > "${WORK}/request/items/3484263516.json"
  request "$(form 3484263516)"
  expect_eq "$(calls | tail -n 2)" "issue | comment | 9 | --body | Raven Creek B42 is in the index already, from its update of $(date -u -d @1789883053 +%Y-%m-%d).
issue | close | 9 | --reason | completed"
  printf '{"id": "3484263516", "title": "Raven Creek B42", "timeUpdated": 1700000000}\n' > "${WORK}/request/items/3484263516.json"
  request "$(form 3484263516)"
  expect_eq "$(calls | tail -n 2)" "issue | edit | 9 | --title | Update Raven Creek B42 (3484263516) | --add-label | update,ready | --remove-label | add
issue | comment | 9 | --body | Queued: the index has Raven Creek B42 from its update of $(date -u -d @1700000000 +%Y-%m-%d); it changed on $(date -u -d @1789883053 +%Y-%m-%d). This issue closes when the index has it."

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

  for item in '1 Current 100' '2 Changed 100' '3 Removed 100' '4 Banned 100' '5 Queued 100' '6 Elsewhere 100'; do
    read -r id title updated <<< "${item}"
    printf '{"id": "%s", "title": "%s", "timeUpdated": %s, "mods": []}\n' "${id}" "${title}" "${updated}" > "${repo}/items/${id}.json"
  done
  export FAKE_ITEMS
  FAKE_ITEMS="$(jq -n -c --argjson current "$(details 1 Current 100)" --argjson changed "$(details 2 "Changed Again" 200)" \
    --argjson banned "$(details 4 Banned 100 108600 1)" --argjson queued "$(details 5 Queued 300)" --argjson elsewhere "$(details 6 Elsewhere 100 999)" \
    '{"1": $current, "2": $changed, "4": $banned, "5": $queued, "6": $elsewhere}')"
  rm -f "${WORK}/gh-calls"
  FAKE_OPEN='[{"number": 3, "title": "Update Queued (5)"}]' bash "${repo}/ci/freshness.sh" || fail "the check failed"
  expect_eq "$(calls)" "${LABELS}
issue | list | --state | open | --limit | 1000 | --json | number,title
issue | create | --title | Update Changed Again (2) | --label | update,ready | --body | Changed Again changed on the Workshop on $(date -u -d @200 +%Y-%m-%d); the index has it from $(date -u -d @100 +%Y-%m-%d). https://steamcommunity.com/sharedfiles/filedetails/?id=2
issue | create | --title | Gone Removed (3) | --label | gone,ready | --body | The Workshop no longer has Removed as a Project Zomboid item (removed). https://steamcommunity.com/sharedfiles/filedetails/?id=3
issue | create | --title | Gone Banned (4) | --label | gone,ready | --body | The Workshop no longer has Banned as a Project Zomboid item (banned). https://steamcommunity.com/sharedfiles/filedetails/?id=4
issue | create | --title | Gone Elsewhere (6) | --label | gone,ready | --body | The Workshop no longer has Elsewhere as a Project Zomboid item (not for Project Zomboid). https://steamcommunity.com/sharedfiles/filedetails/?id=6"

  # Without Steam, or with an item left out of its answer, it fails before touching any issue.
  rm -f "${WORK}/gh-calls"
  FAKE_STEAM_DOWN=1 bash "${repo}/ci/freshness.sh" > /dev/null && fail "the check passed without Steam"
  FAKE_STEAM_SKIP=4 bash "${repo}/ci/freshness.sh" > /dev/null && fail "the check passed with an item left out"
  expect_eq "$(calls)" ""
}


# Makes the folder of a Workshop item: $1 = folder. Mod Town (Build 42) has its cells in 42/ and its title only in
# common/'s translations; Old (Build 41 layout) has a map without map.info; Empty has no mod files.
make_item() {
  local item="$1"
  mkdir -p "${item}/mods/Town/42/media/maps/Town" "${item}/mods/Town/common/media/maps/Town" "${item}/mods/Town/common/media/lua/shared/Translate/EN/Town" \
    "${item}/mods/Old/media/maps/Old Map" "${item}/mods/Old/media/maps/Bare" "${item}/mods/Empty/42"
  touch "${item}/mods/Town/42/mod.info" "${item}/mods/Town/42/media/maps/Town/"{10_5,11_5,12_5,10_6,x_1,1_2_3}.lotheader \
    "${item}/mods/Town/42/media/maps/Town/13_5.lotheader.bak" "${item}/mods/Old/mod.info" "${item}/mods/Old/media/maps/Old Map/"{0_0,-1_0}.lotheader
  printf 'title=Old\r\n  title=Town  \r\n' > "${item}/mods/Town/42/media/maps/Town/map.info"
  printf 'description=No title\n' > "${item}/mods/Old/media/maps/Old Map/map.info"
  printf '%s\n' 'function SpawnPoints()' 'return { unemployed = { { worldX = 10, worldY = 5, posX = 12, posY = 34, posZ = 1 },' \
    '  { posX = 2600, posY = 1290 }, -- { posX = 9, posY = 9 },' '  { posX = 7 }, { worldX = 1, posX = 5, posY = 5 } },' \
    'chef = { { posX = 2600, posY = 1290 } } }' 'end' > "${item}/mods/Town/42/media/maps/Town/spawnpoints.lua"
  printf 'function SpawnPoints() return {} end\n' > "${item}/mods/Old/media/maps/Bare/spawnpoints.lua"
  printf '\357\273\277  Town Proper \r\nsecond\r\n' > "${item}/mods/Town/common/media/lua/shared/Translate/EN/Town/title.txt"
  printf '{\n  "description": "A \\"title\\": inside",\n  "title" : "Town \\"J\\" \\u00e9"\n}\n' > "${item}/mods/Town/common/media/lua/shared/Translate/EN/Town.json"
  mkdir -p "${item}/mods/Old/media/lua/shared/Translate/EN"
  printf '{ "title": "" }\n' > "${item}/mods/Old/media/lua/shared/Translate/EN/Old Map.json"
  printf '{ "title": "Not a map" }\n' > "${item}/mods/Town/common/media/lua/shared/Translate/EN/Sandbox.json"
}
ITEM_JSON='{"id":"123","title":"Town Pack","timeUpdated":200,"mods":[{"folder":"Old","roots":[{"path":"","maps":[{"name":"Bare","cells":[],"spawns":[],"mapInfo":false,"title":null},{"name":"Old Map","cells":[[0,-1,0]],"spawns":null,"mapInfo":true,"title":null}],"translations":[]}]},{"folder":"Town","roots":[{"path":"42","maps":[{"name":"Town","cells":[[5,10,12],[6,10,10]],"spawns":[[3012,1534,1],[2600,1290,0]],"mapInfo":true,"title":"Town"}],"translations":[]},{"path":"common","maps":[{"name":"Town","cells":[],"spawns":null,"mapInfo":false,"title":null}],"translations":[{"name":"Town","json":"Town \"J\" é","txt":"Town Proper"}]}]}]}'

test_index_item() {
  TEST='index item'
  make_item "${WORK}/item"
  expect_eq "$(bash "${REPO}/worker/index_item.sh" "${WORK}/item" 123 "Town Pack" 200)" "${ITEM_JSON}"
  mkdir -p "${WORK}/nothing"
  expect_eq "$(bash "${REPO}/worker/index_item.sh" "${WORK}/nothing" 9 "Nothing" 1)" '{"id":"9","title":"Nothing","timeUpdated":1,"mods":[]}'
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
    {"number": 11, "title": "Add Details Only (654)", "labels": [{"name": "add"}, {"name": "ready"}]},
    {"number": 8, "title": "A fix (123)", "labels": [{"name": "ready"}], "pull_request": {}}]'
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
[ "$1" = run ] || exit 0
printf '{"id": "123"}\n' > "${FAKE_CLONE}/items/123.json"
rm -f "${FAKE_CLONE}/items/999.json"
printf '%s\n' "1	add	123	Town Pack	done" "4	remove	999	Removed	done" "2	update	456	Local Map	done" "7	add	321	Broken	SteamCMD could not download it"
EOF
  chmod +x "${WORK}/bin/docker"
  local out
  out="$(FAKE_CLONE="${clone}" WORKSHOP_DIR=/mnt/c/Steam/steamapps/workshop bash "${clone}/worker/run.sh")" || fail "run.sh failed"
  expect_eq "${out}" "$(printf '%s\n' "#1 Town Pack: add" "#4 Removed: remove" "#2 Local Map: unchanged" "#7 Broken: SteamCMD could not download it")"
  expect_eq "$(git -C "${remote}" log --format='%s|%b' main | grep -v '^$' | head -n 2 | paste -sd ' ')" "data: remove Removed (999)|Closes #4 data: add Town Pack (123)|Closes #1"
  expect_eq "$(git -C "${remote}" ls-tree --name-only main items/ | paste -sd ' ')" "items/123.json items/456.json"
  expect_eq "$(sed -n 2p "${WORK}/docker-calls")" "run --rm --volume zomboid-map-index-cache:/cache --volume ${clone}/items:/items --env REPO=${remote%.git} --volume /mnt/c/Steam/steamapps/workshop:/workshop:ro zomboid-map-index-worker"
}

for t in test_request test_freshness test_index_item test_work test_worker_run; do
  ("${t}"; exit "${FAILED}") || FAILED=1
done
if [ "${FAILED}" = 0 ]; then echo "Tests passed"; else echo "Tests failed"; exit 1; fi
