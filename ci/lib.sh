#!/bin/bash
# Shared by the checks and the worker: Steam's public details of Workshop items, the cells of map folders, the items
# of the index and of a Steam library, and the issues that queue work for the worker.

STEAM_DETAILS=https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/
# The same with a Web API key, and with the items each requires and its votes.
STEAM_FULL_DETAILS=https://api.steampowered.com/IPublishedFileService/GetDetails/v1/
# Project Zomboid's app on the Workshop.
WORKSHOP_APP=108600
# The version of the index entries' format; entries of an older one are read again.
INDEX_FORMAT=2

steam_details() {
  # stdin = workshop IDs, one per line. Prints Steam's details of each as one JSON line; fails when Steam
  # can't be reached or leaves an item out.
  local i response
  local -a batch=() args=()
  while mapfile -t -n 100 batch && [ "${#batch[@]}" -gt 0 ]; do
    args=()
    for i in "${!batch[@]}"; do
      args+=(--data-urlencode "publishedfileids[$i]=${batch[$i]}")
    done
    response="$(curl -fsS --max-time 30 -X POST --data-urlencode "itemcount=${#batch[@]}" "${args[@]}" "${STEAM_DETAILS}")" || return 1
    jq -ce --argjson count "${#batch[@]}" '.response.publishedfiledetails | select(length == $count) | .[]' <<< "${response}" \
      2> /dev/null || return 1
  done
}

item_problem() {
  # stdin = Steam's details of one item. Prints why the index can't have it: "missing", "app" or "banned", or
  # nothing.
  jq -r --argjson app "${WORKSHOP_APP}" '
    if .result != 1 then "missing"
    elif .consumer_app_id != $app then "app"
    elif (.banned // 0) != 0 then "banned"
    else empty end'
}

is_map() {
  # stdin = Steam's details of one item. True when the Workshop has it tagged Map.
  jq -e 'any(.tags[]?; .tag == "Map")' > /dev/null
}

full_details() {
  # stdin = workshop IDs, one per line. Prints Steam's details of each with the items it requires (children) and its
  # votes, read with the Web API key in STEAM_API_KEY, as one JSON line; fails without a key, when Steam can't be
  # reached or when it leaves an item out.
  local i response
  local -a batch=() args=()
  if [ -z "${STEAM_API_KEY:-}" ]; then
    echo "STEAM_API_KEY is empty: add a Steam Web API key as the repository secret STEAM_API_KEY" >&2
    return 1
  fi
  while mapfile -t -n 100 batch && [ "${#batch[@]}" -gt 0 ]; do
    args=()
    for i in "${!batch[@]}"; do
      args+=(--data-urlencode "publishedfileids[$i]=${batch[$i]}")
    done
    response="$(curl -fsS --max-time 30 -G --data-urlencode "key=${STEAM_API_KEY}" --data-urlencode includechildren=true \
      --data-urlencode includevotes=true "${args[@]}" "${STEAM_FULL_DETAILS}")" || return 1
    jq -ce --argjson count "${#batch[@]}" '.response.publishedfiledetails | select(length == $count) | .[]' <<< "${response}" \
      2> /dev/null || return 1
  done
}

required_items() {
  # stdin = full_details lines. Prints "<item>\t<item it requires>" for each item that the Workshop says each requires.
  jq -r '.publishedfileid as $id | .children[]? | [$id, .publishedfileid] | @tsv'
}

indexed_ids() {
  # Prints the Workshop IDs of the items in the index.
  local file
  for file in items/*.json; do
    [ ! -f "${file}" ] || jq -r '.id' "${file}"
  done
}

cell_runs() {
  # stdin = map folders, one per line. Prints "<folder>\t<cells>" for each with cell headers (<x>_<y>.lotheader), the
  # cells as JSON runs [y, first x, last x], by y and x.
  while IFS= read -r map; do
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
    '
}

installed_items() {
  # $1 = a Steam library's appworkshop_<app>.acf. Prints "<id>\t<update time>" of each item installed in it.
  LC_ALL=C awk '
    { sub(/\r$/, ""); line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
    line == "{" { path[++depth] = key; next }
    line == "}" { depth--; next }
    match(line, /^"[^"]*"[ \t]+"[^"]*"$/) {
      split(line, part, "\"")
      if (depth == 3 && path[2] == "WorkshopItemsInstalled" && part[2] == "timeupdated") print path[3] "\t" part[4]
      next
    }
    match(line, /^"[^"]*"$/) { key = substr(line, 2, length(line) - 2) }
  ' "$1"
}

indexed_time() {
  # $1 = workshop ID. Prints the Workshop update time the index has the item from, if it has it.
  [ ! -f "items/$1.json" ] || jq -r '.timeUpdated' "items/$1.json"
}

indexed_current() {
  # $1 = workshop ID of an item in the index. True when its entry has the format the worker writes.
  jq -e --argjson format "${INDEX_FORMAT}" '.format == $format' "items/$1.json" > /dev/null
}

open_issues() {
  # Prints "<number>\t<title>\t<labels, joined by commas>" of every open issue.
  gh api --paginate 'repos/{owner}/{repo}/issues?state=open&per_page=100' \
    --jq '.[] | select(has("pull_request") | not) | "\(.number)\t\(.title)\t\([.labels[]?.name] | join(","))"'
}

queued_in() {
  # $1 = workshop ID, stdin = what open_issues printed. Prints the numbers of the issues that queue the item,
  # whose titles end with "(<id>)".
  awk -F '\t' -v end="($1)" 'substr($2, length($2) - length(end) + 1) == end { print $1 }'
}

ensure_labels() {
  gh label create add --color 1d76db --description "A map to add to the index" --force > /dev/null
  gh label create update --color fbca04 --description "A map that changed since it was indexed" --force > /dev/null
  gh label create gone --color b60205 --description "A map the Workshop no longer has" --force > /dev/null
  gh label create ready --color 0e8a16 --description "Checked, waiting for the worker" --force > /dev/null
}

workshop_link() {
  printf 'https://steamcommunity.com/sharedfiles/filedetails/?id=%s' "$1"
}

utc_date() {
  date -u -d "@$1" +%Y-%m-%d
}
