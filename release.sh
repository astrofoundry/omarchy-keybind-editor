#!/bin/bash
# Release: bump manifest version, commit, tag, push, publish GitHub release.
#
# Usage: ./release.sh <patch|minor|major> [--dry-run]
#
# Expects all release content already committed on an up-to-date main; the
# only commit this script creates is the version bump itself.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

bump="${1:?usage: release.sh <patch|minor|major> [--dry-run]}"
dry_run=0
[[ ${2:-} == "--dry-run" ]] && dry_run=1

case $bump in patch|minor|major) ;; *) echo "unknown bump: $bump" >&2; exit 2 ;; esac

branch=$(git rev-parse --abbrev-ref HEAD)
[[ $branch == main ]] || { echo "release: must run on main (on: $branch)" >&2; exit 1; }

[[ -z $(git status --porcelain) ]] || { echo "release: working tree not clean" >&2; exit 1; }

git fetch --quiet origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] \
  || { echo "release: main is not in sync with origin/main — pull or push first" >&2; exit 1; }

omarchy-plugin-validate "$here" >/dev/null || { echo "release: plugin validation failed" >&2; exit 1; }

current=$(jq -r '.version' manifest.json)
IFS=. read -r major minor patch <<<"$current"
case $bump in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac
next="$major.$minor.$patch"

git rev-parse -q --verify "refs/tags/v$next" >/dev/null \
  && { echo "release: tag v$next already exists" >&2; exit 1; }

# The hook is installed into ~/.config/hypr by install.sh, so plugin update
# alone does not deliver changes to it — users must re-run install.sh.
last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
reinstall_note=""
if [[ -n $last_tag ]] && ! git diff --quiet "$last_tag" HEAD -- hypr/ install.sh; then
  echo "NOTE: hypr/ or install.sh changed since $last_tag."
  echo "      Users must re-run install.sh — say so in the release notes."
  reinstall_note="**Re-run \`install.sh\`** — this release changes the config-side hook."
fi

# Release notes: commit subjects since the last tag, short and plain.
if [[ -n $last_tag ]]; then
  notes=$(git log --format='- %s' "$last_tag"..HEAD)
else
  notes="Initial release."
fi
[[ -n $reinstall_note ]] && notes="$reinstall_note"$'\n\n'"$notes"

echo "release: $current -> $next ($bump)"
if (( dry_run )); then
  echo "release: dry run, stopping before any change"
  echo "release: GitHub release notes would be:"
  echo "$notes"
  exit 0
fi

jq --arg v "$next" '.version = $v' manifest.json > manifest.json.tmp
mv manifest.json.tmp manifest.json
git add manifest.json
git commit -q -m "Release v$next"
git tag "v$next"
git push -q origin main "v$next"

gh release create "v$next" --title "v$next" --notes "$notes" \
  || { echo "release: tag v$next pushed, but GitHub release failed." >&2
       echo "         retry with: gh release create v$next --title v$next --notes-from-tag" >&2
       exit 1; }

echo "release: v$next pushed and released (commit $(git rev-parse --short HEAD))"
