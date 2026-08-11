#!/usr/bin/env bash
set -e
cd /app
PATCH="/solution/golden.patch"
# Idempotent: already applied -> exit 0 without modifying the tree.
if git apply -p1 --reverse --check --whitespace=nowarn "$PATCH" 2>/dev/null; then
  exit 0
fi
if git apply -p1 --whitespace=nowarn "$PATCH" 2>/dev/null; then
  exit 0
fi
git apply -p1 --3way --whitespace=nowarn "$PATCH"
