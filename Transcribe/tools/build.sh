#!/bin/zsh
# Build both Transcribe binaries. Downloads the sherpa-onnx SDK on first run.
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$DIR/.sdk"
VER="1.13.6"
TARBALL="sherpa-onnx-v${VER}-osx-universal2-static-no-tts-lib.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VER}/${TARBALL}"
SWIFT_SRC="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VER}/swift-api-examples"
CAPI_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v${VER}/sherpa-onnx/c-api/c-api.h"

mkdir -p "$SDK" "$DIR/bin"

if [ ! -f "$SDK/.ok" ]; then
  echo "Downloading sherpa-onnx v${VER}…"
  curl -fL -o "$SDK/$TARBALL" "$URL"
  tar xf "$SDK/$TARBALL" -C "$SDK"
  rm "$SDK/$TARBALL"
  curl -fL -o "$SDK/SherpaOnnx.swift" "$SWIFT_SRC/SherpaOnnx.swift"
  curl -fL -o "$SDK/SherpaOnnx-Bridging-Header.h" "$SWIFT_SRC/SherpaOnnx-Bridging-Header.h"
  # The "-lib" release artifact ships no include/ directory (confirmed against
  # the real v1.13.6 asset), so the c-api.h search below would find nothing
  # and the build would abort. Fetch the single self-contained C API header
  # separately and lay it out where a normal SDK checkout would have put it.
  mkdir -p "$SDK/include/sherpa-onnx/c-api"
  curl -fL -o "$SDK/include/sherpa-onnx/c-api/c-api.h" "$CAPI_URL"
  touch "$SDK/.ok"
fi

CAPI=$(find "$SDK" -name c-api.h -path '*sherpa-onnx*' | head -1)
[ -n "$CAPI" ] || { echo "c-api.h not found in $SDK" >&2; exit 1; }
INC=$(dirname "$(dirname "$(dirname "$CAPI")")")
LIBDIR=$(dirname "$(find "$SDK" -name 'libsherpa-onnx-c-api.a' | head -1)")
LIBS=$(cd "$LIBDIR" && ls *.a | sed 's/^lib/-l/; s/\.a$//' | tr '\n' ' ')

echo "Building transcribe-en…"
swiftc -O -target arm64-apple-macos26.0 \
  "$DIR/src/swift/en/main.swift" -o "$DIR/bin/transcribe-en.arm64"
swiftc -O -target x86_64-apple-macos26.0 \
  "$DIR/src/swift/en/main.swift" -o "$DIR/bin/transcribe-en.x86_64"
lipo -create "$DIR/bin/transcribe-en.arm64" "$DIR/bin/transcribe-en.x86_64" \
  -output "$DIR/bin/transcribe-en"
rm "$DIR/bin/transcribe-en.arm64" "$DIR/bin/transcribe-en.x86_64"
strip "$DIR/bin/transcribe-en"

echo "Building transcribe-ru…"
for ARCH in arm64 x86_64; do
  swiftc -lc++ -O -target ${ARCH}-apple-macos26.0 \
    -I "$INC" \
    -import-objc-header "$SDK/SherpaOnnx-Bridging-Header.h" \
    "$DIR/src/swift/ru/main.swift" "$SDK/SherpaOnnx.swift" \
    -L "$LIBDIR" ${=LIBS} \
    -o "$DIR/bin/transcribe-ru.$ARCH"
done
lipo -create "$DIR/bin/transcribe-ru.arm64" "$DIR/bin/transcribe-ru.x86_64" \
  -output "$DIR/bin/transcribe-ru"
rm "$DIR/bin/transcribe-ru.arm64" "$DIR/bin/transcribe-ru.x86_64"
strip "$DIR/bin/transcribe-ru"

echo
echo "Built:"
ls -lh "$DIR/bin/transcribe-en" "$DIR/bin/transcribe-ru"
echo
echo "SHA-256 for the release manifest:"
shasum -a 256 "$DIR/bin/transcribe-ru" | awk '{print $1}'
