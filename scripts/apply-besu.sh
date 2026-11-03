#!/usr/bin/env bash
# Applies the fastevm integration to a Besu checkout (default ../besu).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BESU="${1:-$HERE/../besu}"
[ -f "$HERE/build/libfastevm.so" ] || { cmake -B "$HERE/build" -S "$HERE" && cmake --build "$HERE/build"; }
cd "$BESU"
if git apply --check "$HERE/integrations/besu.patch" 2>/dev/null; then
  git apply "$HERE/integrations/besu.patch"
else
  echo "besu.patch already applied or conflicts; skipping" >&2
fi
echo "done: run with -Dbesu.fastevm=cpu -Dbesu.fastevm.lib=$HERE/build/libfastevm.so"
