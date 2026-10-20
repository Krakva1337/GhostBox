#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

if [[ $# -lt 1 || -z "${*//[[:space:]]/}" ]]; then
  echo 'Usage: ./tool/publish_release.sh "Short summary of this update"' >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || {
  echo 'Git is required to publish a release.' >&2
  exit 1
}

branch="$(git branch --show-current)"
if [[ "$branch" != main ]]; then
  echo "Switch to the main branch before publishing (current: $branch)." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit all intended changes before publishing the release.' >&2
  exit 1
fi

version="$(awk '/^version:/ {split($2, parts, "+"); print parts[1]}' pubspec.yaml)"
if [[ -z "$version" ]]; then
  echo 'Could not read the app version from pubspec.yaml.' >&2
  exit 1
fi
tag="v$version"
summary="$*"

git remote get-url origin >/dev/null 2>&1 || {
  echo 'Configure the GitHub repository as the origin remote first.' >&2
  exit 1
}
git fetch origin main --tags
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || \
   git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  echo "Release tag $tag already exists. Increase pubspec.yaml version first." >&2
  exit 1
fi
if ! git merge-base --is-ancestor origin/main HEAD; then
  echo 'Local main does not contain origin/main. Pull/rebase before releasing.' >&2
  exit 1
fi

echo "Pushing main for GhostBox $tag…"
git push origin HEAD:main
git tag -a "$tag" -m "$summary"
echo "Pushing $tag; GitHub Actions will build and publish the release…"
git push origin "$tag"
echo "Release requested: https://github.com/Krakva1337/GhostBox/releases/tag/$tag"
