#!/bin/bash
# Queues the items of the index that changed on the Workshop since they were indexed ("Update") or that it no
# longer has ("Gone"), each in an issue of its own unless one is open for it already.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ci/lib.sh

shopt -s nullglob
files=(items/*.json)
[ "${#files[@]}" -gt 0 ] || exit 0
if ! details="$(jq -r '.id' "${files[@]}" | steam_details)"; then
  echo "::error::Steam's Workshop details could not be read"
  exit 1
fi
ensure_labels
open="$(open_issues)"
while IFS=$'\t' read -r id kind title indexed detail; do
  [ -z "$(queued_in "${id}" <<< "${open}")" ] || continue
  link="$(workshop_link "${id}")"
  if [ "${kind}" = update ]; then
    gh issue create --title "Update ${title} (${id})" --label update,ready \
      --body "${title} changed on the Workshop on $(utc_date "${detail}"); the index has it from $(utc_date "${indexed}"). ${link}" > /dev/null
  else
    gh issue create --title "Gone ${title} (${id})" --label gone,ready \
      --body "The Workshop no longer has ${title} as a Project Zomboid item (${detail}). ${link}" > /dev/null
  fi
done < <(jq -r -n --argjson app "${WORKSHOP_APP}" --slurpfile items <(jq -c '{id, title, timeUpdated}' "${files[@]}") \
  --slurpfile steam <(printf '%s\n' "${details}") '
  ($steam | map({key: .publishedfileid, value: .}) | from_entries) as $by_id
  | $items[] | . as $item | $by_id[$item.id] as $s
  | if $s.result != 1 then [$item.id, "gone", $item.title, $item.timeUpdated, "removed"]
    elif $s.consumer_app_id != $app then [$item.id, "gone", $item.title, $item.timeUpdated, "not for Project Zomboid"]
    elif ($s.banned // 0) != 0 then [$item.id, "gone", $item.title, $item.timeUpdated, "banned"]
    elif $s.time_updated > $item.timeUpdated then [$item.id, "update", $s.title, $item.timeUpdated, $s.time_updated]
    else empty end
  | map(tostring) | join("\t")')
