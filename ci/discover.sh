#!/bin/bash
# Queues what the index doesn't have and no open issue queues: first the items that the items in the index require on
# the Workshop, such as tile packs, then the Workshop's items tagged Map and each tag in DISCOVER_TAGS (comma-separated,
# such as Build 42), most subscribed first. It opens DISCOVER_COUNT issues, or without it as many as it takes for
# DISCOVER_QUEUE issues labelled ready to be open. Steam tells both for a Web API key in STEAM_API_KEY.
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
for setting in DISCOVER_QUEUE DISCOVER_COUNT; do
  if [ -n "${!setting:-}" ] && ! [[ "${!setting}" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::${setting} is '${!setting}', not a whole number above 0"
    exit 1
  fi
done
queue="${DISCOVER_QUEUE:?}"
tags=(Map)
IFS=, read -r -a more_tags <<< "${DISCOVER_TAGS:-}"
tagged=""
for tag in "${more_tags[@]}"; do
  tag="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<< "${tag}")"
  [ -n "${tag}" ] || continue
  tags+=("${tag}")
  tagged="${tagged:+${tagged} and }${tag}"
done
tagged="${tagged:+ tagged ${tagged}}"
tag_args=()
for i in "${!tags[@]}"; do
  tag_args+=(--data-urlencode "requiredtags[${i}]=${tags[${i}]}")
done

open="$(open_issues)"
if [ -n "${DISCOVER_COUNT:-}" ]; then
  wanted="${DISCOVER_COUNT}"
else
  ready="$(cut -f 3 <<< "${open}" | grep -c -E '(^|,)ready(,|$)' || true)"
  wanted=$((queue - ready))
  if [ "${wanted}" -le 0 ]; then
    echo "The queue is full: ${ready} issues are ready for the worker."
    exit 0
  fi
fi

# What the index's items require on the Workshop, as "<item>\t<required item>", and per required item the titles of
# those that require it.
if ! required="$(indexed_ids | full_details | required_items)"; then
  echo "::error::Steam's Workshop details of the index's items could not be read"
  exit 1
fi
declare -A required_by=()
while IFS=$'\t' read -r item needed; do
  [ -n "${item}" ] || continue
  title="$(jq -r '.title' "items/${item}.json")"
  required_by[${needed}]="${required_by[${needed}]:+${required_by[${needed}]}, }${title}"
done <<< "${required}"

declare -A seen=() rank=()
opened=0
offer() {
  # Arguments: workshop IDs. Opens an issue for each that the index doesn't have, no open issue queues, no earlier
  # call offered and the index can have, until it has opened what it wants.
  local id item title size updated why details
  local -a fresh=()
  for id; do
    [ -z "${seen[${id}]:-}" ] || continue
    seen[${id}]=1
    [ -f "items/${id}.json" ] || [ -n "$(queued_in "${id}" <<< "${open}")" ] || fresh+=("${id}")
  done
  [ "${#fresh[@]}" -gt 0 ] || return 0
  if ! details="$(printf '%s\n' "${fresh[@]}" | steam_details)"; then
    echo "::error::Steam's Workshop details could not be read"
    exit 1
  fi
  for id in "${fresh[@]}"; do
    [ "${opened}" -lt "${wanted}" ] || return 0
    item="$(jq -c --arg id "${id}" 'select(.publishedfileid == $id)' <<< "${details}")"
    [ -z "$(item_problem <<< "${item}")" ] || continue
    title="$(jq -r '.title' <<< "${item}")"
    size="$(jq -r '(.file_size | tonumber) / 1048576 | ceil' <<< "${item}")"
    updated="$(jq -r '.time_updated' <<< "${item}")"
    # GitHub stops accounts that open more than about 500 issues an hour.
    [ "${opened}" = 0 ] || sleep 8
    if [ -n "${required_by[${id}]:-}" ]; then
      why="${title} is required on the Workshop by ${required_by[${id}]}"
    else
      why="${title} is number ${rank[${id}]} of the most subscribed maps${tagged} on the Workshop"
    fi
    gh issue create --title "Add ${title} (${id})" --label add,ready \
      --body "${why}, about ${size} MB, updated on $(utc_date "${updated}"). $(workshop_link "${id}")" > /dev/null
    opened=$((opened + 1))
  done
}

ensure_labels
mapfile -t needed < <(cut -f 2 <<< "${required}" | grep .)
offer "${needed[@]}"

# The ranking a page of 100 at a time, as far as it takes: Steam's cursor reaches deeper than its page numbers.
ranked=0
cursor='*'
while [ "${opened}" -lt "${wanted}" ]; do
  if ! response="$(curl -fsS --max-time 30 -G --data-urlencode "key=${STEAM_API_KEY}" \
    --data-urlencode "query_type=${BY_SUBSCRIPTIONS}" --data-urlencode "appid=${WORKSHOP_APP}" \
    "${tag_args[@]}" --data-urlencode "numperpage=100" --data-urlencode "cursor=${cursor}" \
    --data-urlencode "ids_only=true" "${STEAM_QUERY}")" \
    || ! jq -e '.response.total | type == "number"' <<< "${response}" > /dev/null 2>&1; then
    echo "::error::Steam's Workshop query failed after the ${ranked} most subscribed maps${tagged}"
    exit 1
  fi
  mapfile -t page < <(jq -r '.response.publishedfiledetails[]?.publishedfileid' <<< "${response}")
  for id in "${page[@]}"; do
    ranked=$((ranked + 1))
    rank[${id}]="${ranked}"
  done
  offer "${page[@]}"
  cursor="$(jq -r '.response.next_cursor // empty' <<< "${response}")"
  [ "${#page[@]}" -eq 100 ] && [ -n "${cursor}" ] || break
done

if [ "${opened}" -lt "${wanted}" ]; then
  echo "Queued ${opened} of the ${wanted} items wanted: the index has or queues the rest of the ${ranked} maps${tagged} on the Workshop."
else
  echo "Queued ${opened} items."
fi
