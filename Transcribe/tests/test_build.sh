#!/bin/bash
# Both binaries must build, be universal, and run without a dynamic sherpa-onnx.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

"$HERE/../tools/build.sh" >/tmp/build.log 2>&1 || fail "build failed; see /tmp/build.log"

# The build script targets both arm64 and x86_64 and lipo's them together, so
# a genuinely universal binary must report exactly these two architectures —
# not a subset (a silently-thin lipo output) and not extras.
for b in transcribe-en transcribe-ru; do
  [ -x "$HERE/../bin/$b" ] || fail "$b not produced"
  archs="$(lipo -archs "$HERE/../bin/$b")"
  [ "$(echo "$archs" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" = "arm64 x86_64" ] \
    || fail "$b architectures are '$archs', expected exactly 'arm64 x86_64'"
done

# transcribe-ru must be self-contained: no sherpa-onnx or onnxruntime dylib.
if otool -L "$HERE/../bin/transcribe-ru" | grep -qiE 'sherpa|onnxruntime'; then
  fail "transcribe-ru links a dynamic sherpa-onnx/onnxruntime — must be static"
fi

echo "PASS: test_build"
