#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp/}torrentflow-ui-render.XXXXXX")"
APP="$OUT/TorrentFlow Render Tests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUT/module" "$OUT/clang" "$OUT/swift"
cp -X "$ROOT/Sources/TorrentBridge/include/TorrentBridge.h" "$OUT/module/TorrentBridge.h"
cat > "$OUT/module/module.modulemap" <<'MODULE'
module TorrentBridge { header "TorrentBridge.h" export * }
MODULE
clang++ -std=c++17 -O1 -c -fobjc-arc -mmacosx-version-min=27.0 -DTORRENT_ABI_VERSION=2 -DTORRENT_USE_RTC=0 -DTORRENT_USE_LIBCRYPTO=1 -DTORRENT_USE_OPENSSL=1 -DTORRENT_SSL_PEERS=1 \
 -fmodules-cache-path="$OUT/clang" -I"$ROOT/Vendor/include" -I"$ROOT/Sources/TorrentBridge/include" \
 "$ROOT/Sources/TorrentBridge/TorrentBridge.mm" -o "$OUT/TorrentBridge.o"
SOURCES=()
for source in "$ROOT/Sources/TorrentFlow/"*.swift; do
    [ "$(basename "$source")" = TorrentFlowApp.swift ] || SOURCES+=("$source")
done
swiftc -swift-version 6 -parse-as-library -O -target arm64-apple-macos27.0 -module-cache-path "$OUT/swift" -I "$OUT/module" \
 "${SOURCES[@]}" "$ROOT/Tests/RenderUI.swift" "$OUT/TorrentBridge.o" -L"$ROOT/Vendor/lib" \
 -ltorrent-rasterbar -lssl -lcrypto -lc++ -framework Foundation -framework Security -framework SystemConfiguration -framework AppKit -framework SwiftUI -framework IOKit \
 -o "$APP/Contents/MacOS/TorrentFlowRender"
python3 - "$ROOT/Info.plist" "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys,uuid
with open(sys.argv[1],'rb') as f:info=plistlib.load(f)
info['CFBundleIdentifier']='com.zel0th.TorrentFlow.RenderTests.'+uuid.uuid4().hex
info['CFBundleExecutable']='TorrentFlowRender'
info['CFBundleName']='TorrentFlow Render Tests'
info['CFBundleDisplayName']='TorrentFlow Render Tests'
info['LSUIElement']=True
info.pop('CFBundleDocumentTypes',None)
info.pop('CFBundleURLTypes',None)
with open(sys.argv[2],'wb') as f:plistlib.dump(info,f)
PY
for language in ru en; do
    ditto --norsrc --noextattr "$ROOT/Resources/$language.lproj" "$APP/Contents/Resources/$language.lproj"
done
codesign --force --sign - "$APP"
printf 'RENDER_APP %s\nRENDER_ROOT %s\n' "$APP" "$OUT/results"
if [ "${TORRENTFLOW_COMPILE_ONLY:-0}" != 1 ]; then
    TORRENTFLOW_UI_RENDER_ROOT="$OUT/results" TORRENTFLOW_STATE_ROOT="$OUT/results/state" "$APP/Contents/MacOS/TorrentFlowRender"
fi
