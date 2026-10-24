#!/bin/bash
# Runs the worker as a service for the repository REPO (owner/name). Every POLL (a duration sleep takes, 5m by
# default) it asks GitHub which open issue labelled ready changed last, and starts a round when one changed since the
# last round began, or when INTERVAL (whole seconds, or minutes, hours or days with m, h or d; 6h by default) has
# passed since then, so what failed is tried again. A round brings its clone of REMOTE (git@github.com:<REPO>.git by
# default) in CLONE_DIR (/repo by default) up to date, works through the queued requests with work.sh and commits and
# pushes what comes of each as it comes. DEPLOY_KEY can name a private SSH key for the remote, such as a deploy key
# with write access, which it makes when there is none; each start prints its public key. The hosts it reaches are
# remembered in CACHE_DIR. Commits carry git's GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME and
# GIT_COMMITTER_EMAIL.
set -euo pipefail
here="$(dirname "$0")"
# shellcheck source=ci/lib.sh
. "${here}/../ci/lib.sh"

repo="${REPO:?}"
remote="${REMOTE:-git@github.com:${repo}.git}"
clone="${CLONE_DIR:-/repo}"
poll="${POLL:-5m}"
interval="${INTERVAL:-6h}"
if ! retry="$(duration_seconds "${interval}")"; then
  echo "INTERVAL is '${interval}', not a duration such as 6h" >&2
  exit 1
fi

if [ -n "${DEPLOY_KEY:-}" ]; then
  [ -f "${DEPLOY_KEY}" ] || ssh-keygen -q -t ed25519 -N '' -f "${DEPLOY_KEY}"
  # ssh takes only a key no one else can read.
  key="$(mktemp)"
  trap 'rm -f "${key}"' EXIT
  cat "${DEPLOY_KEY}" > "${key}"
  echo "Deploy key: $(ssh-keygen -y -f "${key}")"
  export GIT_SSH_COMMAND="ssh -i ${key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${CACHE_DIR:-/cache}/known_hosts"
fi

round() {
  { [ -d "${clone}/.git" ] || git clone --quiet "${remote}" "${clone}"; } \
    && git -C "${clone}" remote set-url origin "${remote}" \
    && git -C "${clone}" fetch --quiet origin \
    && git -C "${clone}" reset --quiet --hard origin/HEAD \
    && git -C "${clone}" clean --quiet --force -d \
    && ITEMS_DIR="${clone}/items" "${here}/work.sh" | (cd "${clone}" && "${here}/commit.sh")
}

changed() {
  # Prints when the open issue labelled ready that changed last changed, by GitHub's clock, or nothing when none is.
  curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${repo}/issues?state=open&labels=ready&sort=updated&direction=desc&per_page=1" \
    | jq -r '.[0].updated_at // ""'
}

# When the last round began: the last change it saw, and the time to try again what it left.
seen=''
due=0
while true; do
  if ! last="$(changed)"; then
    echo "GitHub's list of queued requests could not be read; asking again in ${poll}" >&2
  elif [ -n "${last}" ] && { [[ "${last}" > "${seen}" ]] || [ "$(date +%s)" -ge "${due}" ]; }; then
    seen="${last}"
    due=$(($(date +%s) + retry))
    echo "Working through the queued requests"
    round || echo "This round failed; what it didn't push is tried again in ${interval}, or sooner when a request changes" >&2
  fi
  sleep "${poll}"
done
