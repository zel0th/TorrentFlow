#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp/}torrentflow-localization-tests"
mkdir -p "$OUT/modules" "$OUT/LocalizationTest.bundle/Contents/Resources"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/ru.lproj" "$OUT/LocalizationTest.bundle/Contents/Resources/"
cat > "$OUT/LocalizationTest.bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.zel0th.TorrentFlow.LocalizationTest</string><key>CFBundleDevelopmentRegion</key><string>ru</string><key>CFBundleLocalizations</key><array><string>ru</string><string>en</string></array></dict></plist>
PLIST
swiftc -swift-version 6 -target "$(uname -m)-apple-macos27.0" -parse-as-library -module-cache-path "$OUT/modules" \
  "$ROOT/Sources/TorrentFlow/Localization.swift" "$ROOT/Sources/TorrentFlow/Models.swift" \
  "$ROOT/Tests/LocalizationTests.swift" -o "$OUT/localization-tests"
"$OUT/localization-tests" "$OUT/LocalizationTest.bundle" "$ROOT"
