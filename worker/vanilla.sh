#!/bin/bash
# Reads the game's own maps on the Steam branches given: installs Project Zomboid's dedicated server from each with
# SteamCMD into a folder in CACHE_DIR, deleted once read, and prints {"<major version>": {gameVersion, branch, maps}},
# with the version as the server logs it, read from the game's files with the jar VERSION_READER, and maps holding the
# name and cells, as runs [y, first x, last x], of each folder in media/maps. Fails on two branches of one build.
# Usage: vanilla.sh <branch>...
set -euo pipefail
here="$(dirname "$0")"
# shellcheck source=ci/lib.sh
. "${here}/../ci/lib.sh"

if [ "$#" = 0 ]; then
  echo "usage: vanilla.sh <branch>..." >&2
  exit 2
fi
# Project Zomboid's dedicated server on Steam.
SERVER_APP=380870
cache="${CACHE_DIR:-/cache}"

install() {
  # $1 = branch, $2 = folder. Installs the server there, trying three times.
  local log attempt
  local -a beta=()
  # "-beta public" is no beta SteamCMD takes.
  [ "$1" = public ] || beta=(-beta "$1")
  log="$(mktemp)"
  for attempt in 1 2 3; do
    "${STEAMCMDDIR:?}/steamcmd.sh" +force_install_dir "$2" +login anonymous +app_update "${SERVER_APP}" "${beta[@]}" validate +quit \
      > "${log}" 2>&1 || true
    if grep -q "Success! App '${SERVER_APP}'" "${log}"; then
      rm -f "${log}"
      return 0
    fi
    echo "SteamCMD could not install the $1 branch (attempt ${attempt}): $(grep -E 'ERROR|Error|Timeout' "${log}" | tail -n 1)" >&2
  done
  rm -f "${log}"
  return 1
}

read_game() {
  # $1 = branch, $2 = game folder. Prints {gameVersion, branch, maps}.
  local version
  local -a classpath=()
  mapfile -t classpath < <(jq -r '.classpath[]' "$2/ProjectZomboid64.json")
  version="$(cd "$2" && java -jar "${VERSION_READER:?}" "${classpath[@]}")" || return 1
  find "$2/media/maps" -mindepth 1 -maxdepth 1 -type d | cell_runs > "${tmp}/cells" || return 1
  find "$2/media/maps" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort \
    | jq -R . | jq -s -c --arg version "${version}" --arg branch "$1" --arg maps "$2/media/maps/" --rawfile cells "${tmp}/cells" '
      ($cells | split("\n") | map(select(length > 0) | split("\t") | {key: (.[0] | ltrimstr($maps)), value: (.[1] | fromjson)}) | from_entries)
        as $cells
      | {gameVersion: $version, branch: $branch, maps: map({name: ., cells: ($cells[.] // [])})}'
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
declare -A builds=()
games=()
for branch; do
  game="$(mktemp -d "${cache}/game.XXXXXX")"
  if ! install "${branch}" "${game}" || ! read_game "${branch}" "${game}" > "${tmp}/${branch}.json"; then
    rm -rf "${game}"
    echo "The ${branch} branch could not be read" >&2
    exit 1
  fi
  rm -rf "${game}"
  major="$(jq -r '.gameVersion | split(".")[0]' "${tmp}/${branch}.json")"
  if [ -n "${builds[${major}]:-}" ]; then
    echo "The ${builds[${major}]} and ${branch} branches are both Build ${major}" >&2
    exit 1
  fi
  builds[${major}]="${branch}"
  games+=("${tmp}/${branch}.json")
done
jq -s -c 'map({key: (.gameVersion | split(".")[0]), value: .}) | from_entries' "${games[@]}"
