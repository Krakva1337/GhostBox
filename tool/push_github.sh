#!/usr/bin/env bash
set -euo pipefail

REMOTE="${GHOSTBOX_GIT_REMOTE:-origin}"
BRANCH="$(git branch --show-current)"

if [[ -z "$BRANCH" ]]; then
  echo "Detached HEAD: switch to a branch before pushing." >&2
  exit 2
fi
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "Git remote '$REMOTE' is not configured." >&2
  exit 2
fi
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "A merge is in progress. Resolve it and commit before running this script." >&2
  exit 2
fi
if git rev-parse -q --verify REBASE_HEAD >/dev/null; then
  echo "A rebase is in progress. Resolve it and continue before running this script." >&2
  exit 2
fi

git add -A
git diff --cached --check
if ! git diff --cached --quiet; then
  MESSAGE="${*:-Update GhostBox}"
  git commit -m "$MESSAGE"
fi

git fetch "$REMOTE"
if git show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH"; then
  git pull --rebase --autostash "$REMOTE" "$BRANCH"
fi
git push -u "$REMOTE" "$BRANCH"
