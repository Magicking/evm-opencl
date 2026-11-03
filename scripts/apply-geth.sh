#!/usr/bin/env bash
# Applies the fastevm integration to a go-ethereum checkout (default ../go-ethereum)
# and builds libfastevm if needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GETH="${1:-$HERE/../go-ethereum}"
[ -f "$HERE/build/libfastevm.so" ] || { cmake -B "$HERE/build" -S "$HERE" && cmake --build "$HERE/build"; }
cd "$GETH"
if git apply --check "$HERE/integrations/geth.patch" 2>/dev/null; then
  git apply "$HERE/integrations/geth.patch"
else
  echo "geth.patch already applied or conflicts; skipping" >&2
fi
go mod edit -require=github.com/fastevm/fastevm/bindings/go@v0.0.0 \
  -replace=github.com/fastevm/fastevm/bindings/go="$HERE/bindings/go"
echo "done: go test -tags fastevm ./tests -run TestExecutionSpecState"
