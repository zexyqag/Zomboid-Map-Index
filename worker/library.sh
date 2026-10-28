#!/bin/bash
# Lists the maps installed in the Steam library WORKSHOP_DIR (its steamapps/workshop folder) that the index doesn't
# have and no open issue queues, and opens an "Add a map" issue with gh for each one picked. Run it in a clone of this
# repository; once the request check queues the issues, run.sh with the same WORKSHOP_DIR reads the maps from the
# library.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ci/lib.sh

acf="${WORKSHOP_DIR:?needs the steamapps/workshop folder of a Steam library}/appworkshop_${WORKSHOP_APP}.acf"
if [ ! -f "${acf}" ]; then
  echo "${WORKSHOP_DIR} has no Project Zomboid items: ${acf} is missing" >&2
  exit 1
fi

git pull --ff-only --quiet
queued="$(open_issues)"
if ! details="$(installed_items "${acf}" | cut -f 1 | steam_details)"; then
  echo "Steam's Workshop details could not be read" >&2
  exit 1
fi
mapfile -t candidates < <(
  while IFS= read -r item; do
    [ -n "${item}" ] && [ -z "$(item_problem <<< "${item}")" ] && is_map <<< "${item}" || continue
    id="$(jq -r '.publishedfileid' <<< "${item}")"
    [ ! -f "items/${id}.json" ] && [ -z "$(queued_in "${id}" <<< "${queued}")" ] || continue
    jq -r '[.publishedfileid, ((.file_size | tonumber) / 1048576 | ceil), .title] | @tsv' <<< "${item}"
  done <<< "${details}" | sort -t $'\t' -k 3 -f
)
if [ "${#candidates[@]}" = 0 ]; then
  echo "The index has or queues every map in ${WORKSHOP_DIR}."
  exit 0
fi

echo "Maps in ${WORKSHOP_DIR} that the index doesn't have:"
for n in "${!candidates[@]}"; do
  IFS=$'\t' read -r id size title <<< "${candidates[n]}"
  printf '%4d  %s (%s), %s MB\n' "$((n + 1))" "${title}" "${id}" "${size}"
done
read -r -p "Open an issue for which? Numbers or ranges (1 3 5-7), all, or nothing to stop: " answer || true
read -r -a words <<< "${answer//,/ }"
picks=()
for word in "${words[@]}"; do
  if [ "${word}" = all ]; then
    first=1 last="${#candidates[@]}"
  elif [[ "${word}" =~ ^([0-9]+)(-([0-9]+))?$ ]]; then
    first=$((10#${BASH_REMATCH[1]})) last=$((10#${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}))
  else
    echo "Not a number, a range or all: ${word}" >&2
    exit 1
  fi
  if [ "${first}" -lt 1 ] || [ "${first}" -gt "${last}" ] || [ "${last}" -gt "${#candidates[@]}" ]; then
    echo "Not in the list: ${word}" >&2
    exit 1
  fi
  for ((n = first; n <= last; n++)); do
    picks+=("${n}")
  done
done
[ "${#picks[@]}" -gt 0 ] || exit 0

opened=0
while read -r n; do
  IFS=$'\t' read -r id size title <<< "${candidates[n - 1]}"
  # GitHub stops accounts that open issues much faster than one a second.
  [ "${opened}" = 0 ] || sleep 1
  url="$(gh issue create --title "Add a map" --label add --body "$(printf '### Workshop item\n\n%s' "$(workshop_link "${id}")")")"
  echo "${title}: ${url}"
  opened=$((opened + 1))
done < <(printf '%s\n' "${picks[@]}" | sort -nu)
echo "Once the request check queues them, run: WORKSHOP_DIR=\"${WORKSHOP_DIR}\" ./worker/run.sh"
