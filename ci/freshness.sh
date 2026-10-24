#!/bin/bash
# Queues the items of the index that changed on the Workshop since they were indexed or whose entries have an
# older format ("Update"), or that the Workshop no longer has ("Gone"), each in an issue of its own unless one is
# open for it already. An item without map folders (tile packs, map tools) is read again only once the version the
# index has is QUIET_DAYS old, so one that changes often isn't downloaded each time, and one that gains maps later
# is still read again.
set -euo pipefail
cd "$(dirname "$0")/.."
QUIET_DAYS=90
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
opened=0
while IFS=$'\t' read -r id kind title indexed detail; do
  [ -z "$(queued_in "${id}" <<< "${open}")" ] || continue
  link="$(workshop_link "${id}")"
  # GitHub stops accounts that open issues much faster than one a second.
  [ "${opened}" = 0 ] || sleep 1
  case "${kind}" in
    update)
      gh issue create --title "Update ${title} (${id})" --label update,ready \
        --body "${title} changed on the Workshop on $(utc_date "${detail}"); the index has it from $(utc_date "${indexed}"). ${link}" > /dev/null ;;
    format)
      gh issue create --title "Update ${title} (${id})" --label update,ready \
        --body "The index has ${title} in an older format, so the worker reads it again. ${link}" > /dev/null ;;
    gone)
      gh issue create --title "Gone ${title} (${id})" --label gone,ready \
        --body "The Workshop no longer has ${title} as a Project Zomboid item (${detail}). ${link}" > /dev/null ;;
  esac
  opened=$((opened + 1))
done < <(jq -r -n --argjson app "${WORKSHOP_APP}" --argjson format "${INDEX_FORMAT}" --argjson quiet "$((QUIET_DAYS * 86400))" \
  --slurpfile items <(jq -c '{id, title, timeUpdated, format, maps: ([.mods[]?.roots[]?.maps[]?] | length)}' "${files[@]}") \
  --slurpfile steam <(printf '%s\n' "${details}") '
  ($steam | map({key: .publishedfileid, value: .}) | from_entries) as $by_id
  | $items[] | . as $item | $by_id[$item.id] as $s
  | if $s.result != 1 then [$item.id, "gone", $item.title, $item.timeUpdated, "removed"]
    elif $s.consumer_app_id != $app then [$item.id, "gone", $item.title, $item.timeUpdated, "not for Project Zomboid"]
    elif ($s.banned // 0) != 0 then [$item.id, "gone", $item.title, $item.timeUpdated, "banned"]
    elif $s.time_updated > $item.timeUpdated and ($item.maps > 0 or now - $item.timeUpdated >= $quiet) then
      [$item.id, "update", $s.title, $item.timeUpdated, $s.time_updated]
    elif $item.format != $format then [$item.id, "format", $s.title, $item.timeUpdated, "-"]
    else empty end
  | map(tostring) | join("\t")')
