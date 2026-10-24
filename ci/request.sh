#!/bin/bash
# Checks an issue made with the "Add a map" form (the event in GITHUB_EVENT_PATH): queues the item for the
# worker (labels add or update, and ready), or closes the issue with the reason. Other issues are left alone. The index
# takes items tagged Map, and items that a map in it requires on the Workshop, such as tile packs; which those are,
# Steam says for the Web API key in STEAM_API_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ci/lib.sh

event="${GITHUB_EVENT_PATH:?}"
number="$(jq -r '.issue.number' "${event}")"
[ "$(jq -r '.issue.state' "${event}")" = open ] || exit 0
body="$(jq -r '.issue.body // ""' "${event}" | tr -d '\r')"
grep -qx '### Workshop item' <<< "${body}" || exit 0
field="$(awk '/^### Workshop item$/ { found = 1; next } found && /^### / { exit } found && NF { print; exit }' <<< "${body}")"

reject() {
  gh issue comment "${number}" --body "$1" > /dev/null
  gh issue close "${number}" --reason "not planned" > /dev/null
}

ensure_labels
if [[ "${field}" =~ [?\&]id=([0-9]{1,20})([^0-9]|$) ]] || [[ "${field}" =~ ^[[:space:]]*([0-9]{1,20})[[:space:]]*$ ]]; then
  id="${BASH_REMATCH[1]}"
else
  reject "This needs a Workshop link (https://steamcommunity.com/sharedfiles/filedetails/?id=...) or the item's ID. Edit it in and reopen the issue."
  exit 0
fi
if ! details="$(steam_details <<< "${id}")"; then
  echo "::error::Steam's Workshop details could not be read for item ${id}"
  exit 1
fi
case "$(item_problem <<< "${details}")" in
  missing) reject "Steam has no public Workshop item with the ID ${id}."; exit 0 ;;
  app) reject "Workshop item ${id} isn't for Project Zomboid."; exit 0 ;;
  banned) reject "Steam has banned Workshop item ${id}."; exit 0 ;;
esac
title="$(jq -r '.title' <<< "${details}")"
if ! is_map <<< "${details}"; then
  if ! required="$(indexed_ids | full_details | required_items)"; then
    echo "::error::Steam's Workshop details of the index's items could not be read"
    exit 1
  fi
  if ! awk -F '\t' -v id="${id}" '$2 == id { found = 1 } END { exit !found }' <<< "${required}"; then
    reject "Workshop item ${id} isn't tagged Map on the Workshop and no item in the index requires it, so the index doesn't take it."
    exit 0
  fi
fi
updated="$(jq -r '.time_updated' <<< "${details}")"
indexed="$(indexed_time "${id}")"
if [ -n "${indexed}" ] && [ "${indexed}" -ge "${updated}" ] && indexed_current "${id}"; then
  gh issue comment "${number}" --body "${title} is in the index already, from its update of $(utc_date "${indexed}")." > /dev/null
  gh issue close "${number}" --reason completed > /dev/null
  exit 0
fi
other="$(open_issues | queued_in "${id}" | grep -vx "${number}" | head -n 1 || true)"
if [ -n "${other}" ]; then
  reject "${title} is queued in #${other} already."
  exit 0
fi

kind="$([ -n "${indexed}" ] && echo update || echo add)"
heading="$([ "${kind}" = add ] && echo Add || echo Update) ${title} (${id})"
# An edit that changes nothing keeps the issue as it is.
if [ "$(jq -r '.issue.title' "${event}")" = "${heading}" ] && jq -e 'any(.issue.labels[]; .name == "ready")' "${event}" > /dev/null; then
  exit 0
fi
args=(--title "${heading}" --add-label "${kind},ready")
if [ "${kind}" = update ] && jq -e 'any(.issue.labels[]; .name == "add")' "${event}" > /dev/null; then
  args+=(--remove-label add)
fi
gh issue edit "${number}" "${args[@]}" > /dev/null
size="$(jq -r '(.file_size | tonumber) / 1048576 | ceil' <<< "${details}")"
if [ "${kind}" = add ]; then
  message="Queued: ${title}, about ${size} MB, updated on the Workshop on $(utc_date "${updated}")."
elif [ "${indexed}" -lt "${updated}" ]; then
  message="Queued: the index has ${title} from its update of $(utc_date "${indexed}"); it changed on $(utc_date "${updated}")."
else
  message="Queued: the index has ${title} in an older format, so it is read again."
fi
gh issue comment "${number}" --body "${message} This issue closes when the index has it." > /dev/null
