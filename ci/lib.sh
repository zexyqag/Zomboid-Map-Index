#!/bin/bash
# Shared by the request and freshness checks: Steam's public details of Workshop items, the items of the
# index and the issues that queue work for the worker.

STEAM_DETAILS=https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/
# Project Zomboid's app on the Workshop.
WORKSHOP_APP=108600

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
  # stdin = Steam's details of one item. Prints why the index can't have it: "missing", "app", "banned" or
  # "tag", or nothing.
  jq -r --argjson app "${WORKSHOP_APP}" '
    if .result != 1 then "missing"
    elif .consumer_app_id != $app then "app"
    elif (.banned // 0) != 0 then "banned"
    elif any(.tags[]?; .tag == "Map") | not then "tag"
    else empty end'
}

indexed_time() {
  # $1 = workshop ID. Prints the Workshop update time the index has the item from, if it has it.
  [ ! -f "items/$1.json" ] || jq -r '.timeUpdated' "items/$1.json"
}

open_issues() {
  # Prints "<number>\t<title>" of each open issue.
  gh issue list --state open --limit 1000 --json number,title | jq -r '.[] | "\(.number)\t\(.title)"'
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
