#!/usr/bin/env bash
# Print the CHANGELOG section for a release tag, after checking the tag, VERSION in
# coaster.sh and the CHANGELOG agree. Used by the release workflows.
#   Usage: tools/release-notes.sh vX.Y.Z
set -euo pipefail

cd "$(dirname "$0")/.."
tag="${1:?usage: $0 vX.Y.Z}"
[[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "not a release tag: $tag" >&2; exit 1; }
version="${BASH_REMATCH[1]}"
script_version="$(sed -n 's/^VERSION=//p' coaster.sh)"
[ "$script_version" = "$version" ] || { echo "$tag but coaster.sh has VERSION=$script_version" >&2; exit 1; }

notes="$(awk -v v="$version" '
    index($0, "## [" v "]") == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found && /^\[[0-9]+\.[0-9]+\.[0-9]+\]: / { exit }
    found { print }' CHANGELOG.md)"
notes="$(sed -e '/./,$!d' <<<"$notes")"   # drop leading blank lines
[ -n "$notes" ] || { echo "no CHANGELOG section for $version" >&2; exit 1; }
printf '%s\n' "$notes"
