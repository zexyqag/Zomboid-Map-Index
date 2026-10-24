#!/bin/bash
# Prints the Workshop's figures of every item in the index as {"<workshop id>": {...}}, read with the Web API key in
# STEAM_API_KEY: subscribers, favorites and their lifetime totals, unique visitors, votes up and down with Steam's
# score, public comments, download size, creation and update times, the preview image and the items it requires.
# Items Steam no longer has are left out.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ci/lib.sh

if ! details="$(indexed_ids | full_details)"; then
  echo "::error::Steam's Workshop details of the index's items could not be read" >&2
  exit 1
fi
jq -s -c 'map(select(.result == 1) | {key: .publishedfileid, value: {
    subscribers: .subscriptions, lifetimeSubscribers: .lifetime_subscriptions,
    favorites: .favorited, lifetimeFavorites: .lifetime_favorited, visitors: .views,
    votesUp: .vote_data.votes_up, votesDown: .vote_data.votes_down, score: .vote_data.score, comments: .num_comments_public,
    fileSize: (.file_size | tonumber), timeCreated: .time_created, timeUpdated: .time_updated, preview: .preview_url,
    requires: [.children[]?.publishedfileid]}})
  | from_entries' <<< "${details}"
