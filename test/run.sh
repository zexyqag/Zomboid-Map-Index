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
# FAKE_STEAM_SKIP.
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/curl" <<'EOF'
#!/bin/bash
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

# Runs the request check on an issue: $1 = body, $2 = number, $3 = state, $4 = title, $5 = labels (comma separated).
request() {
  jq -n --arg body "$1" --argjson number "${2:-9}" --arg state "${3:-open}" --arg title "${4:-Add a map}" --arg labels "${5-add}" \
    '{issue: {number: $number, state: $state, title: $title, body: $body, labels: ($labels | split(",") | map(select(length > 0) | {name: .}))}}' \
    > "${WORK}/event.json"
  rm -f "${WORK}/gh-calls"
  GITHUB_EVENT_PATH="${WORK}/event.json" bash "${REPO}/ci/request.sh"
}
calls() { cat "${WORK}/gh-calls" 2> /dev/null; }
form() { printf '### Workshop item\n\n%s\n' "$1"; }

test_request() {
  TEST=request
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
  mkdir -p "${WORK}/repo"
  cp -r "${REPO}/ci" "${WORK}/repo/"
  mkdir -p "${WORK}/repo/items"
  printf '{"id": "3484263516", "title": "Raven Creek B42", "timeUpdated": 1789883053}\n' > "${WORK}/repo/items/3484263516.json"
  jq -n --arg body "$(form 3484263516)" '{issue: {number: 9, state: "open", title: "Add a map", body: $body, labels: [{name: "add"}]}}' > "${WORK}/event.json"
  rm -f "${WORK}/gh-calls"
  GITHUB_EVENT_PATH="${WORK}/event.json" bash "${WORK}/repo/ci/request.sh"
  expect_eq "$(calls | tail -n 2)" "issue | comment | 9 | --body | Raven Creek B42 is in the index already, from its update of $(date -u -d @1789883053 +%Y-%m-%d).
issue | close | 9 | --reason | completed"
  printf '{"id": "3484263516", "title": "Raven Creek B42", "timeUpdated": 1700000000}\n' > "${WORK}/repo/items/3484263516.json"
  rm -f "${WORK}/gh-calls"
  GITHUB_EVENT_PATH="${WORK}/event.json" bash "${WORK}/repo/ci/request.sh"
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

for t in test_request test_freshness; do
  ("${t}"; exit "${FAILED}") || FAILED=1
done
if [ "${FAILED}" = 0 ]; then echo "Tests passed"; else echo "Tests failed"; exit 1; fi
