#!/bin/sh
# Builds and runs the unit tests for Artemis's plain-C code
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
xcrun clang -std=c11 -Wall -Wextra -Werror -arch arm64 -I"$ROOT/Limelight/Stream" \
    "$ROOT/Tests/VideoTests.c" "$ROOT/Limelight/Stream/VideoBitstream.c" "$ROOT/Limelight/Stream/ColorConversion.c" \
    -o "$OUT/VideoTests"
"$OUT/VideoTests"
