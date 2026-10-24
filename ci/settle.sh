#!/bin/bash
# Waits after a push until the site may be built: QUIET (whole seconds, or minutes, hours or days with m, h or d; 10m by
# default), which the next push's wait cuts short by cancelling this one, unless the last run of WORKFLOW that went
# through, building the site, ended MAX_WAIT (6h by default) ago or there is none.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ci/lib.sh

quiet="${QUIET:-10m}"
max_wait="${MAX_WAIT:-6h}"
if ! wait_seconds="$(duration_seconds "${quiet}")"; then
  echo "::error::QUIET is '${quiet}', not a duration such as 10m"
  exit 1
fi
if ! max_seconds="$(duration_seconds "${max_wait}")"; then
  echo "::error::MAX_WAIT is '${max_wait}', not a duration such as 6h"
  exit 1
fi

last="$(gh run list --workflow "${WORKFLOW:?}" --branch main --status success --limit 1 --json updatedAt --jq '.[0].updatedAt // ""')"
if [ -z "${last}" ]; then
  echo "The site was never built: building it now."
elif [ $(($(date +%s) - $(date -d "${last}" +%s))) -ge "${max_seconds}" ]; then
  echo "The site was last built at ${last}, ${max_wait} or more ago: building it now."
else
  echo "Waiting ${quiet} for more changes."
  sleep "${wait_seconds}"
fi
