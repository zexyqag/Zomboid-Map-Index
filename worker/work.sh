#!/bin/bash
# Works through the open issues of the repository REPO (owner/name) that the checks labelled ready. An item to add
# or update is read from WORKSHOP_DIR (a Steam library's steamapps/workshop folder) when its copy there is as new as
# the Workshop's, or else downloaded into CACHE_DIR with DepotDownloader (DEPOTDOWNLOADER), or with SteamCMD when
# DepotDownloader can't, and its index entry written to ITEMS_DIR/<id>.json; the entry of an item that is gone, or that the
# Workshop doesn't tag Map and that has no map, is removed. With DROP_DOWNLOADS=1 the downloads are deleted once
# read. Prints per issue "<number>\t<add|update|remove>\t<id>\t<result>\t<title>", "-" for what it doesn't know, the
# result being "done" or why not, the title last as it can be empty, and what it does on stderr.
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
  updated="$(installed_items "${acf}" | awk -F '\t' -v id="$1" '$1 == id { print $2 }')"
  if [[ "${updated}" =~ ^[0-9]+$ ]] && [ "${updated}" -ge "$2" ]; then
    printf '%s\n' "${workshop}/content/${WORKSHOP_APP}/$1"
  fi
}

drop_downloads() {
  # All of SteamCMD's workshop folder goes, its record of the items it has with it, so it downloads them anew, and
  # all DepotDownloader has.
  [ "${DROP_DOWNLOADS:-0}" != 1 ] || rm -rf "${cache:?}/steamapps/workshop" "${cache:?}/depotdownloader"
}

log_lines() {
  # $1 = a downloader's log. Prints its lines without colours, tabs or blank lines: SteamCMD redraws its progress
  # with carriage returns, and starts some lines with a colour on the same line.
  tr '\r\t' '\n ' < "$1" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]/\n/g' | sed -E 's/^ +| +$//g; /^$/d'
}

downloaded() {
  # $1 = workshop ID. Prints the KiB SteamCMD has on disk while it downloads the item: all it keeps besides the items
  # it has, and what it has of this one.
  local workshop="${cache}/steamapps/workshop"
  { find "${workshop}" -mindepth 1 -maxdepth 1 ! -name content -print0 2> /dev/null || true
    printf '%s\0' "${workshop}/content/${WORKSHOP_APP}/$1"; } | du -sk -c --files0-from=- 2> /dev/null | tail -n 1 | cut -f 1 || true
}

steamcmd_download() {
  # $1 = workshop ID, $2 = its size in MiB. Downloads the item with SteamCMD and prints its folder, or what SteamCMD
  # said last when it fails: its last error, or else its last line, on one line without colours or tabs. SteamCMD
  # gives up on a big item after a while but keeps what it got, so it is tried again for as long as a try gets more
  # of it, until three tries in a row get nothing. Each failed try says how much SteamCMD has on disk and how much
  # room is left.
  local attempt=0 fruitless=0 most size free log lines said
  most="$(downloaded "$1")"
  log="$(mktemp)"
  while [ "${fruitless}" -lt 3 ]; do
    attempt=$((attempt + 1))
    "${STEAMCMDDIR:?}/steamcmd.sh" +force_install_dir "${cache}" +login anonymous +workshop_download_item "${WORKSHOP_APP}" "$1" +quit \
      > "${log}" 2>&1 || true
    if grep -q "Success. Downloaded item $1" "${log}" && [ -d "${cache}/steamapps/workshop/content/${WORKSHOP_APP}/$1" ]; then
      rm -f "${log}"
      printf '%s\n' "${cache}/steamapps/workshop/content/${WORKSHOP_APP}/$1"
      return 0
    fi
    lines="$(log_lines "${log}")"
    said="$(grep -E 'ERROR|Error|Timeout' <<< "${lines}" | tail -n 1 || true)"
    [ -n "${said}" ] || said="$(tail -n 1 <<< "${lines}")"
    size="$(downloaded "$1")"
    free="$(df -Pm "${cache}" | awk 'NR == 2 { print $4 }')"
    echo "SteamCMD could not download item $1 (attempt ${attempt}, $((size / 1024)) of $2 MiB, ${free} MiB free): ${said}" >&2
    if [ "${size}" -gt "${most}" ]; then
      most="${size}"
      fruitless=0
    else
      fruitless=$((fruitless + 1))
    fi
  done
  rm -f "${log}"
  printf '%s\n' "${said}"
  return 1
}

depot_download() {
  # $1 = workshop ID. Downloads the item with DepotDownloader into CACHE_DIR/depotdownloader/<id>, which goes on from
  # what an earlier run left there, and prints its folder, or what DepotDownloader said last when it fails.
  local folder="${cache}/depotdownloader/$1" log
  log="$(mktemp)"
  if "${DEPOTDOWNLOADER:?}" -app "${WORKSHOP_APP}" -pubfile "$1" -dir "${folder}" > "${log}" 2>&1 \
    && grep -q '^Total downloaded:' "${log}"; then
    rm -f "${log}"
    printf '%s\n' "${folder}"
    return 0
  fi
  log_lines "${log}" | grep -vx 'Disconnected from Steam' | tail -n 1 || true
  rm -f "${log}"
  return 1
}

issues="$(mktemp)"
trap 'rm -f "${issues}"' EXIT
for ((page = 1; ; page++)); do
  page_issues="$(curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPO:?}/issues?state=open&labels=ready&per_page=100&page=${page}")"
  printf '%s\n' "${page_issues}" >> "${issues}"
  [ "$(jq 'length' <<< "${page_issues}")" -eq 100 ] || break
done
while IFS=$'\t' read -r number id kind title; do
  if [ "${id}" = - ] || [ "${kind}" = - ]; then
    printf '%s\t-\t-\tits title has no Workshop ID or it has no add, update or gone label\t%s\n' "${number}" "${title}"
    continue
  fi
  if ! details="$(steam_details <<< "${id}")"; then
    printf '%s\t%s\t%s\tSteam'"'"'s Workshop details could not be read\t%s\n' "${number}" "${kind}" "${id}" "${title}"
    continue
  fi
  problem="$(item_problem <<< "${details}")"
  if [ "${kind}" = gone ]; then
    title="${title#Gone }"
    title="${title% "(${id})"}"
    if [ -n "${problem}" ] || { ! is_map <<< "${details}" && ! has_map "${items}/${id}.json"; }; then
      rm -f "${items}/${id}.json"
      printf '%s\tremove\t%s\tdone\t%s\n' "${number}" "${id}" "${title}"
    else
      printf '%s\tremove\t%s\tthe Workshop has it again\t%s\n' "${number}" "${id}" "${title}"
    fi
    continue
  fi
  name="$(jq -r '.title' <<< "${details}")"
  if [ -n "${problem}" ]; then
    printf '%s\t%s\t%s\tthe Workshop says: %s\t%s\n' "${number}" "${kind}" "${id}" "${problem}" "${name}"
    continue
  fi
  updated="$(jq -r '.time_updated' <<< "${details}")"
  folder="$(local_copy "${id}" "${updated}")"
  downloaded=false
  if [ -n "${folder}" ]; then
    echo "Reading ${name} (${id}) from the Steam library" >&2
  else
    echo "Downloading ${name} (${id})" >&2
    downloaded=true
    if ! folder="$(depot_download "${id}")"; then
      drop_downloads
      depot_said="${folder}"
      echo "Downloading ${name} (${id}) with SteamCMD, as DepotDownloader could not: ${depot_said}" >&2
      if ! folder="$(steamcmd_download "${id}" "$(jq -r '(.file_size | tonumber) / 1048576 | ceil' <<< "${details}")")"; then
        drop_downloads
        printf '%s\t%s\t%s\tDepotDownloader could not download it (%s), nor SteamCMD (%s)\t%s\n' \
          "${number}" "${kind}" "${id}" "${depot_said}" "${folder}" "${name}"
        continue
      fi
    fi
  fi
  if bash "${here}/index_item.sh" "${folder}" "${id}" "${name}" "${updated}" > "${items}/${id}.json.new"; then
    mv "${items}/${id}.json.new" "${items}/${id}.json"
    printf '%s\t%s\t%s\tdone\t%s\n' "${number}" "${kind}" "${id}" "${name}"
  else
    rm -f "${items}/${id}.json.new"
    printf '%s\t%s\t%s\tits files could not be read\t%s\n' "${number}" "${kind}" "${id}" "${name}"
  fi
  [ "${downloaded}" = false ] || drop_downloads
done < <(jq -r -s 'add | .[] | select(.pull_request | not) | [.number, ((.title | capture("\\((?<id>[0-9]+)\\)$").id) // "-"),
  ([.labels[].name] | if index("gone") then "gone" elif index("update") then "update" elif index("add") then "add" else "-" end), .title] | @tsv' \
  "${issues}")
