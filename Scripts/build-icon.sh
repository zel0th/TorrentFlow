#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="${TMPDIR:-/tmp/}TorrentFlow.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
 sips -z "$SIZE" "$SIZE" "$ROOT/Design/Icon-Master.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
 DOUBLE=$((SIZE * 2))
 sips -z "$DOUBLE" "$DOUBLE" "$ROOT/Design/Icon-Master.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
python3 - "$ICONSET" "$ROOT/Design/AppIcon.icns" <<'PYICON'
from pathlib import Path
import struct, sys
source=Path(sys.argv[1]); chunks=[]
for name, code in [('icon_16x16.png', b'icp4'), ('icon_32x32.png', b'icp5'), ('icon_32x32@2x.png', b'icp6'), ('icon_128x128.png', b'ic07'), ('icon_256x256.png', b'ic08'), ('icon_512x512.png', b'ic09'), ('icon_512x512@2x.png', b'ic10')]:
    data=(source/name).read_bytes()
    chunks.append(code+struct.pack('>I',len(data)+8)+data)
body=b''.join(chunks)
Path(sys.argv[2]).write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
PYICON
