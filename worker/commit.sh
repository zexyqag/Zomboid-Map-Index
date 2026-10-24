#!/bin/bash
# Commits each index entry that the worker's plan (stdin, as work.sh prints it) says it wrote or removed and that
# differs from the clone in the current folder, with "Closes #<issue>", and pushes it, as the plan comes. Prints what
# came of each issue.
set -euo pipefail

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
  git push --quiet
  echo "#${number} ${title}: ${kind}"
done
