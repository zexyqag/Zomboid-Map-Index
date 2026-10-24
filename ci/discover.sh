#!/bin/bash
# Queues the most subscribed maps of the Workshop that the index doesn't have and no open issue queues, most
# subscribed first, until DISCOVER_QUEUE issues labelled ready are open. Only the DISCOVER_TOP most subscribed
# items tagged Map count. Steam ranks them for a Web API key in STEAM_API_KEY.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ci/lib.sh

STEAM_QUERY=https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/
# Steam's EPublishedFileQueryType for items ranked by their total unique subscriptions.
BY_SUBSCRIPTIONS=9

if [ -z "${STEAM_API_KEY:-}" ]; then
  echo "::error::STEAM_API_KEY is empty: add a Steam Web API key as the repository secret STEAM_API_KEY"
  exit 1
fi
top="${DISCOVER_TOP:?}"
queue="${DISCOVER_QUEUE:?}"

issues="$(gh issue list --state open --limit 1000 --json number,title,labels)"
wanted=$((queue - $(jq '[.[] | select(any(.labels[]; .name == "ready"))] | length' <<< "${issues}")))
if [ "${wanted}" -le 0 ]; then
  echo "The queue is full: $((queue - wanted)) issues are ready for the worker."
  exit 0
fi
open="$(jq -r '.[] | "\(.number)\t\(.title)"' <<< "${issues}")"

ranked=()
for ((page = 1; (page - 1) * 100 < top; page++)); do
  if ! response="$(curl -fsS --max-time 30 -G --data-urlencode "key=${STEAM_API_KEY}" \
    --data-urlencode "query_type=${BY_SUBSCRIPTIONS}" --data-urlencode "appid=${WORKSHOP_APP}" \
    --data-urlencode "requiredtags[0]=Map" --data-urlencode "numperpage=100" --data-urlencode "page=${page}" \
    --data-urlencode "ids_only=true" "${STEAM_QUERY}")" \
    || ! jq -e '.response | has("publishedfiledetails") or .total == 0' <<< "${response}" > /dev/null 2>&1; then
    echo "::error::Steam's Workshop query failed on page ${page}"
    exit 1
  fi
  mapfile -t -O "${#ranked[@]}" ranked < <(jq -r '.response.publishedfiledetails[]?.publishedfileid' <<< "${response}")
  [ "$(jq '.response.publishedfiledetails // [] | length' <<< "${response}")" -eq 100 ] || break
done

candidates=()
for id in "${ranked[@]:0:top}"; do
  if [ ! -f "items/${id}.json" ] && [ -z "$(queued_in "${id}" <<< "${open}")" ]; then
    candidates+=("${id}")
  fi
done
[ "${#candidates[@]}" -gt 0 ] || exit 0
if ! details="$(printf '%s\n' "${candidates[@]}" | steam_details)"; then
  echo "::error::Steam's Workshop details could not be read"
  exit 1
fi

ensure_labels
opened=0
for id in "${candidates[@]}"; do
  [ "${opened}" -lt "${wanted}" ] || break
  item="$(jq -c --arg id "${id}" 'select(.publishedfileid == $id)' <<< "${details}")"
  [ -z "$(item_problem <<< "${item}")" ] || continue
  title="$(jq -r '.title' <<< "${item}")"
  size="$(jq -r '(.file_size | tonumber) / 1048576 | ceil' <<< "${item}")"
  updated="$(jq -r '.time_updated' <<< "${item}")"
  # GitHub stops accounts that open issues much faster than one a second.
  [ "${opened}" = 0 ] || sleep 1
  gh issue create --title "Add ${title} (${id})" --label add,ready \
    --body "${title} is one of the ${top} most subscribed maps on the Workshop, about ${size} MB, updated on $(utc_date "${updated}"). $(workshop_link "${id}")" \
    > /dev/null
  opened=$((opened + 1))
done
echo "Queued ${opened} maps."
