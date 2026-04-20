#!/usr/bin/env bash
# Refresh the submodule pointers to the latest main of each repo,
# then commit and push the parent so the bootstrap snapshot is fresh.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "→ Pulling latest main in each submodule..."
git submodule update --remote --merge

if git diff --quiet; then
  echo "No submodule updates — nothing to commit."
  exit 0
fi

echo "→ Committing updated submodule pointers..."
git add Wiki LLM
git commit -m "refresh: update submodule pointers to latest main"
git push origin HEAD
echo "✓ Bootstrap snapshot refreshed."
