#!/bin/bash
# Works through the open issues of the repository REPO (owner/name) that the checks labelled ready. An item to add
# or update is read from WORKSHOP_DIR (a Steam library's steamapps/workshop folder) when its copy there is as new as
# the Workshop's, or else downloaded with SteamCMD into CACHE_DIR, and its index entry written to ITEMS_DIR/<id>.json;
# the entry of an item that is gone is removed. Prints per issue "<number>\t<add|update|remove>\t<id>\t<title>\t<result>",
# "-" for what it doesn't know, the result being "done" or why not, and what it does on stderr.
set -euo pipefail
here="$(dirname "$0")"
# shellcheck source=ci/lib.sh
. "${here}/../ci/lib.sh"

items="${ITEMS_DIR:-/items}"
cache="${CACHE_DIR:-/cache}"
workshop="${WORKSHOP_DIR:-/workshop}"

local_copy() {
  # $1 = workshop ID, $2 = its Workshop update time. Prints the folder of the copy in WORKSHOP_DIR when Steam's
  # appworkshop_<app>.acf there says it is as new.
  local acf="${workshop}/appworkshop_${WORKSHOP_APP}.acf" updated
  [ -f "${acf}" ] && [ -d "${workshop}/content/${WORKSHOP_APP}/$1" ] || return 0
  updated="$(LC_ALL=C awk -v id="$1" '
    { sub(/\r$/, ""); line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
    line == "{" { path[++depth] = key; next }
    line == "}" { depth--; next }
    match(line, /^"[^"]*"[ \t]+"[^"]*"$/) {
      split(line, part, "\"")
      if (depth == 3 && path[2] == "WorkshopItemsInstalled" && path[3] == id && part[2] == "timeupdated") print part[4]
      next
    }
    match(line, /^"[^"]*"$/) { key = substr(line, 2, length(line) - 2) }
  ' "${acf}")"
  if [[ "${updated}" =~ ^[0-9]+$ ]] && [ "${updated}" -ge "$2" ]; then
    printf '%s\n' "${workshop}/content/${WORKSHOP_APP}/$1"
  fi
}

download() {
  # $1 = workshop ID. Downloads the item with SteamCMD, trying three times, and prints its folder.
  local attempt log
  log="$(mktemp)"
  for attempt in 1 2 3; do
    "${STEAMCMDDIR:?}/steamcmd.sh" +force_install_dir "${cache}" +login anonymous +workshop_download_item "${WORKSHOP_APP}" "$1" +quit \
      > "${log}" 2>&1 || true
    if grep -q "Success. Downloaded item $1" "${log}" && [ -d "${cache}/steamapps/workshop/content/${WORKSHOP_APP}/$1" ]; then
      rm -f "${log}"
      printf '%s\n' "${cache}/steamapps/workshop/content/${WORKSHOP_APP}/$1"
      return 0
    fi
    echo "SteamCMD could not download item $1 (attempt ${attempt}): $(grep -E 'ERROR|Error|Timeout' "${log}" | tail -n 1)" >&2
  done
  rm -f "${log}"
  return 1
}

issues="$(curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/${REPO:?}/issues?state=open&labels=ready&per_page=100")"
while IFS=$'\t' read -r number id kind title; do
  if [ "${id}" = - ] || [ "${kind}" = - ]; then
    printf '%s\t-\t-\t%s\tits title has no Workshop ID or it has no add, update or gone label\n' "${number}" "${title}"
    continue
  fi
  if ! details="$(steam_details <<< "${id}")"; then
    printf '%s\t%s\t%s\t%s\tSteam'"'"'s Workshop details could not be read\n' "${number}" "${kind}" "${id}" "${title}"
    continue
  fi
  problem="$(item_problem <<< "${details}")"
  if [ "${kind}" = gone ]; then
    title="${title#Gone }"
    title="${title% "(${id})"}"
    case "${problem}" in
      missing | app | banned)
        rm -f "${items}/${id}.json"
        printf '%s\tremove\t%s\t%s\tdone\n' "${number}" "${id}" "${title}" ;;
      *) printf '%s\tremove\t%s\t%s\tthe Workshop has it again\n' "${number}" "${id}" "${title}" ;;
    esac
    continue
  fi
  name="$(jq -r '.title' <<< "${details}")"
  if [ -n "${problem}" ]; then
    printf '%s\t%s\t%s\t%s\tthe Workshop says: %s\n' "${number}" "${kind}" "${id}" "${name}" "${problem}"
    continue
  fi
  updated="$(jq -r '.time_updated' <<< "${details}")"
  folder="$(local_copy "${id}" "${updated}")"
  if [ -n "${folder}" ]; then
    echo "Reading ${name} (${id}) from the Steam library" >&2
  else
    echo "Downloading ${name} (${id})" >&2
    if ! folder="$(download "${id}")"; then
      printf '%s\t%s\t%s\t%s\tSteamCMD could not download it\n' "${number}" "${kind}" "${id}" "${name}"
      continue
    fi
  fi
  if bash "${here}/index_item.sh" "${folder}" "${id}" "${name}" "${updated}" > "${items}/${id}.json.new"; then
    mv "${items}/${id}.json.new" "${items}/${id}.json"
    printf '%s\t%s\t%s\t%s\tdone\n' "${number}" "${kind}" "${id}" "${name}"
  else
    rm -f "${items}/${id}.json.new"
    printf '%s\t%s\t%s\t%s\tits files could not be read\n' "${number}" "${kind}" "${id}" "${name}"
  fi
done < <(jq -r '.[] | select(.pull_request | not) | [.number, ((.title | capture("\\((?<id>[0-9]+)\\)$").id) // "-"),
  ([.labels[].name] | if index("gone") then "gone" elif index("update") then "update" elif index("add") then "add" else "-" end), .title] | @tsv' \
  <<< "${issues}")
