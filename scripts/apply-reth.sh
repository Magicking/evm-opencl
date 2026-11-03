#!/usr/bin/env bash
# Applies the fastevm integration to a reth checkout (default ../reth), builds libfastevm if
# needed and fetches reth's pinned EF/EEST fixtures.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RETH="${1:-$HERE/../reth}"
[ -f "$HERE/build/libfastevm.so" ] || { cmake -B "$HERE/build" -S "$HERE" && cmake --build "$HERE/build"; }
cd "$RETH"
if git apply --check "$HERE/integrations/reth.patch" 2>/dev/null; then
  git apply "$HERE/integrations/reth.patch"
else
  echo "reth.patch already applied or conflicts; skipping" >&2
fi
# The patch points the workspace at ../fastevm; adjust when fastevm lives elsewhere.
if [ "$(cd "$RETH/.." && pwd)/fastevm" != "$HERE" ]; then
  sed -i "s|path = \"../fastevm/bindings/rust/fastevm\"|path = \"$HERE/bindings/rust/fastevm\"|" Cargo.toml
fi
make testing/ef-tests/ethereum-tests testing/ef-tests/execution-spec-tests
echo "done: FASTEVM_BACKEND=cpu cargo test --release -p ef-tests --features ef-tests,fastevm"
