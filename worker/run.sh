#!/bin/bash
# Works through the requests the checks queued: builds the worker image, runs it on the open issues labelled ready,
# commits each new, changed or removed index entry with "Closes #<issue>", and pushes. Run it in a clone of this
# repository on a machine with Docker; downloads stay in the Docker volume zomboid-map-index-cache, or with
# --drop-downloads are deleted once they are read. WORKSHOP_DIR can name a Steam library's steamapps/workshop folder,
# whose items as new as the Workshop's aren't downloaded.
set -euo pipefail
cd "$(dirname "$0")/.."

drop=0
for arg; do
  case "${arg}" in
    --drop-downloads) drop=1 ;;
    *)
      echo "usage: run.sh [--drop-downloads]" >&2
      exit 2 ;;
  esac
done

git pull --ff-only --quiet
repo="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
docker build --quiet --file worker/Dockerfile --tag zomboid-map-index-worker . > /dev/null
args=(--rm --volume zomboid-map-index-cache:/cache --volume "${PWD}/items:/items" --env "REPO=${repo}" --env "DROP_DOWNLOADS=${drop}")
[ -z "${WORKSHOP_DIR:-}" ] || args+=(--volume "${WORKSHOP_DIR}:/workshop:ro")
plan="$(docker run "${args[@]}" zomboid-map-index-worker)"

commits=0
while IFS=$'\t' read -r number kind id title result; do
  [ -n "${number}" ] || continue
  if [ "${result}" != "done" ]; then
    echo "#${number} ${title}: ${result}"
    continue
  fi
  git add --all "items/${id}.json"
  if git diff --cached --quiet; then
    echo "#${number} ${title}: unchanged"
    continue
  fi
  git commit --quiet --message "data: ${kind} ${title} (${id})" --message "Closes #${number}"
  echo "#${number} ${title}: ${kind}"
  commits=$((commits + 1))
done <<< "${plan}"
if [ "${commits}" -gt 0 ]; then
  git push --quiet
fi
