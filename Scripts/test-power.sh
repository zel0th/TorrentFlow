#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp/}TorrentFlow-power-tests"
mkdir -p "$OUT/cache"
swiftc -parse-as-library -swift-version 6 -module-cache-path "$OUT/cache" \
 "$ROOT/Sources/TorrentFlow/Localization.swift" "$ROOT/Sources/TorrentFlow/Models.swift" "$ROOT/Sources/TorrentFlow/PowerManagement.swift" \
 "$ROOT/Tests/PowerManagementTests.swift" -framework IOKit -o "$OUT/power-tests"
"$OUT/power-tests"
