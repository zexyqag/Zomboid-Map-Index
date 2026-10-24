#!/bin/bash
# Runs the worker as a service: every INTERVAL (a duration sleep takes, 6h by default) it brings its clone of REMOTE
# (git@github.com:<REPO>.git by default) in CLONE_DIR (/repo by default) up to date, works through the queued requests
# with work.sh and commits and pushes what came of them. DEPLOY_KEY can name a private SSH key for the remote, such
# as a deploy key with write access, which it makes when there is none; each start prints its public key. The hosts
# it reaches are remembered in CACHE_DIR. Commits carry git's
# GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL. A round that fails is tried again
# the next time.
set -euo pipefail
here="$(dirname "$0")"

remote="${REMOTE:-git@github.com:${REPO:?}.git}"
clone="${CLONE_DIR:-/repo}"
interval="${INTERVAL:-6h}"

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
    && plan="$(ITEMS_DIR="${clone}/items" "${here}/work.sh")" \
    && (cd "${clone}" && "${here}/commit.sh" <<< "${plan}")
}

while true; do
  echo "Working through the queued requests"
  round || echo "This round failed; the next one is in ${interval}" >&2
  sleep "${interval}"
done
