#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp/}torrentflow-magnet-tests"
mkdir -p "$OUT"
# An optional first argument selects a captured bridge source for regression evidence.
BRIDGE="${1:-$ROOT/Sources/TorrentBridge/TorrentBridge.mm}"
EXTRA_FLAGS=()
if [ "$#" = 0 ]; then EXTRA_FLAGS=(-DTF_DIAGNOSTICS_TEST=1 -DTF_021_API_TEST=1); else EXTRA_FLAGS=(-DTF_021_LATENCY_ONLY=1); fi
clang++ -std=c++17 -O1 -fobjc-arc -mmacosx-version-min=27.0 -DTORRENT_ABI_VERSION=2 -DTORRENT_USE_RTC=0 -DTORRENT_USE_LIBCRYPTO=1 -DTORRENT_USE_OPENSSL=1 -DTORRENT_SSL_PEERS=1 \
 "${EXTRA_FLAGS[@]}" -I"$ROOT/Vendor/include" -I"$ROOT/Sources/TorrentBridge/include" -I"$ROOT/Sources/TorrentBridge" \
 "$BRIDGE" "$ROOT/Tests/MagnetDiscovery.mm" \
 -L"$ROOT/Vendor/lib" -ltorrent-rasterbar -lssl -lcrypto -framework Foundation -framework Security -framework SystemConfiguration \
 -o "$OUT/magnet-discovery-tests"
if [ "${TORRENTFLOW_COMPILE_ONLY:-0}" != 1 ]; then
 "$OUT/magnet-discovery-tests" "$OUT/run-$(date +%s)-$$"
fi
