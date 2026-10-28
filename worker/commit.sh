#!/bin/bash
# Commits each index entry that the worker's plan (stdin, as work.sh prints it) says it wrote or removed and that
# differs from the clone in the current folder, with "Closes #<issue>", and pushes it, as the plan comes. Prints what
# came of each issue.
set -euo pipefail

while IFS=$'\t' read -r number kind id result title; do
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
  # A push that finds commits it doesn't have, such as the game's maps of the week, goes on top of them.
  if ! git push --quiet 2> /dev/null; then
    git fetch --quiet
    git rebase --quiet --autostash '@{upstream}' > /dev/null
    git push --quiet
  fi
  echo "#${number} ${title}: ${kind}"
done
