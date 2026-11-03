#!/usr/bin/env bash
# Downloads the execution-spec-tests fixtures pinned by go-ethereum (tests@v21.0.1),
# verifies the checksum and extracts them where geth's tests expect them.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GETH="${1:-$HERE/../go-ethereum}"
SUM=b9b14391ed1a625e4ca9a058c055d0eacd98a42b76c7a6127c640cdc2d3c9439
mkdir -p "$HERE/.cache"
cd "$HERE/.cache"
[ -f fixtures.tar.gz ] || curl -fsSL -o fixtures.tar.gz \
  'https://github.com/ethereum/execution-specs/releases/download/tests%40v21.0.1/fixtures.tar.gz'
echo "$SUM  fixtures.tar.gz" | sha256sum -c
mkdir -p "$GETH/tests/spec-tests"
tar -xzf fixtures.tar.gz -C "$GETH/tests/spec-tests"
git -C "$GETH" submodule update --init tests/evm-benchmarks
