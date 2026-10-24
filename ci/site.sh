#!/bin/bash
# Builds the site in the folder $1: index.json, every entry of items/ by Workshop ID as {"items": [...]}, and the
# grid script as grid-<major version>.js.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:?usage: site.sh <folder>}"
mkdir -p "${out}"
shopt -s nullglob
files=(items/*.json)
if [ "${#files[@]}" -gt 0 ]; then
  jq -c -s 'sort_by(.id | tonumber) | {items: .}' "${files[@]}" > "${out}/index.json"
else
  echo '{"items":[]}' > "${out}/index.json"
fi
major="$(sed -n "s/^export const VERSION = '\([0-9][0-9]*\)\.[0-9][0-9]*\.[0-9][0-9]*';$/\1/p" site/grid.js)"
if [ -z "${major}" ]; then
  echo "site/grid.js has no VERSION like '1.0.0'" >&2
  exit 1
fi
cp site/grid.js "${out}/grid-${major}.js"
