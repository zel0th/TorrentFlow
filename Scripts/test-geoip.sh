#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp/}torrentflow-geoip-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/fixture.csv" <<'CSV'
8.8.8.0,8.8.8.127,US
8.8.8.128,8.8.8.255,US
2001:4860::,2001:4860:ffff:ffff:ffff:ffff:ffff:ffff,US
CSV
python3 "$ROOT/Scripts/build-geoip.py" --source "$OUT/fixture.csv" --output "$OUT/fixture.bin" --source-url fixture --release fixture
clang++ -std=c++17 -O2 -I"$ROOT/Sources/TorrentBridge" "$ROOT/Tests/GeoIPTests.cpp" -o "$OUT/tests"
if [ -f "$ROOT/Resources/GeoIP.bin" ]; then
 "$OUT/tests" "$OUT/fixture.bin" "$OUT" "$ROOT/Resources/GeoIP.bin"
else
 "$OUT/tests" "$OUT/fixture.bin" "$OUT"
fi
