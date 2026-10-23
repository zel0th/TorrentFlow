#!/bin/bash
# Build the pinned static engine and headers for a fresh source checkout.
# Vendor is a local build cache; it is not stored in the GitHub repository.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="${TMPDIR:-/tmp/}TorrentFlow-engine-source"
mkdir -p "$DEPS" "$ROOT/Vendor/include" "$ROOT/Vendor/lib"
cd "$DEPS"
command -v cmake >/dev/null || { echo 'Install CMake before rebuilding the engine.' >&2; exit 1; }
OPENSSL_PREFIX="$(brew --prefix openssl)"
curl --fail --location https://github.com/arvidn/libtorrent/releases/download/v2.1.2/libtorrent-rasterbar-2.1.2.tar.gz -o libtorrent.tar.gz
curl --fail --location https://archives.boost.io/release/1.89.0/source/boost_1_89_0.tar.bz2 -o boost.tar.bz2
shasum -a 256 -c "$ROOT/Documentation/Dependency-SHA256.txt"
tar -xf libtorrent.tar.gz
tar -xf boost.tar.bz2
cmake -S libtorrent-rasterbar-2.1.2 -B engine-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -Dwebtorrent=OFF -DOPENSSL_USE_STATIC_LIBS=TRUE -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" -DBOOST_ROOT="$DEPS/boost_1_89_0" -DCMAKE_INSTALL_PREFIX="$ROOT/Vendor" -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_CXX_STANDARD=17
cmake --build engine-build --parallel 6
cmake --install engine-build
cp -R boost_1_89_0/boost "$ROOT/Vendor/include/"
cp -R "$OPENSSL_PREFIX/include/openssl" "$ROOT/Vendor/include/"
cp "$OPENSSL_PREFIX/lib/libssl.a" "$OPENSSL_PREFIX/lib/libcrypto.a" "$ROOT/Vendor/lib/"
