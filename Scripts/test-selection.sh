#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp/}TorrentFlow-selection-tests"
mkdir -p "$OUT/cache"
swiftc -parse-as-library -swift-version 6 -module-cache-path "$OUT/cache" \
 "$ROOT/Sources/TorrentFlow/TransferSelection.swift" "$ROOT/Tests/SelectionTests.swift" \
 -o "$OUT/selection-tests"
"$OUT/selection-tests"
