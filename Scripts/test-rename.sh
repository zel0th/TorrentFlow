#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp/}torrentflow-rename-tests"
mkdir -p "$OUT"
clang++ -std=c++17 -O1 -fobjc-arc -mmacosx-version-min=27.0 -DTORRENT_ABI_VERSION=2 -DTORRENT_USE_RTC=0 -DTORRENT_USE_LIBCRYPTO=1 -DTORRENT_USE_OPENSSL=1 -DTORRENT_SSL_PEERS=1 \
 -I"$ROOT/Vendor/include" -I"$ROOT/Sources/TorrentBridge/include" -I"$ROOT/Sources/TorrentBridge" \
 "$ROOT/Sources/TorrentBridge/TorrentBridge.mm" "$ROOT/Tests/RenameIntegration.mm" \
 -L"$ROOT/Vendor/lib" -ltorrent-rasterbar -lssl -lcrypto -framework Foundation -framework Security -framework SystemConfiguration \
 -o "$OUT/rename-tests"
if [ "${TORRENTFLOW_COMPILE_ONLY:-0}" != 1 ]; then
 "$OUT/rename-tests" "$OUT/run-$(date +%s)-$$"
fi
