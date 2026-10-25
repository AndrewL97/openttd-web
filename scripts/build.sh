#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/openttd-wasm-source"
DIST="$ROOT/dist"

rm -rf "$WORK" "$DIST"
mkdir -p "$DIST"

: "${SOURCE_REPOSITORY:=https://github.com/OpenTTD/OpenTTD.git}"
: "${SOURCE_REF:=master}"

echo "Fetching Simutrans source: $SOURCE_REPOSITORY ($SOURCE_REF)"
git clone --depth 1 --branch "$SOURCE_REF" "$SOURCE_REPOSITORY" "$WORK"
cd "$WORK"

cat > config.default <<'CONFIG'
BACKEND = sdl2
COLOUR_DEPTH = 16
OSTYPE = linux
OPTIMISE = 1
CONFIG

echo "=== Emscripten configuration ==="
emcc --version
emcc --show-ports || true

EM_CACHE="$(em-config CACHE)"
echo "Emscripten cache: $EM_CACHE"

find "$EM_CACHE" \
  \( -name 'sdl2.pc' -o -name 'freetype2.pc' \) \
  -print 2>/dev/null || true

# Bypass host pkg-config discovery for SDL2 and FreeType.
# Emscripten's ports must provide the actual WASM libraries.
set +e
emmake make -j2 \
  CFG=default \
  SDL2_CONFIG=true \
  FREETYPE_CONFIG=true \
  "FLAGS=-sUSE_SDL=2 -sUSE_FREETYPE=1 -sUSE_BZIP2=1 -sUSE_ZLIB=1 -sUSE_LIBPNG=1" \
  "LDFLAGS=-sUSE_SDL=2 -sUSE_FREETYPE=1 -sUSE_BZIP2=1 -sUSE_ZLIB=1 -sUSE_LIBPNG=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=2GB"
BUILD_STATUS=$?
set -e

if [[ $BUILD_STATUS -ne 0 ]]; then
  echo "ERROR: Simutrans failed to build with Emscripten." >&2
  echo "Inspect the first compiler/linker error and patch upstream dependency handling if required." >&2
  exit "$BUILD_STATUS"
fi

BUILD_DIR="$WORK/build/default"
JS_FILE="$BUILD_DIR/openttd.js"
WASM_FILE="$BUILD_DIR/openttd.wasm"

echo "=== Inspecting build outputs ==="
find "$BUILD_DIR" -maxdepth 1 -type f \
  -printf '%f (%s bytes)\n' 2>/dev/null || true
file "$BUILD_DIR/openttd" "$BUILD_DIR/openttd.wasm" 2>/dev/null || true

# Some Makefile configurations emit the JavaScript launcher without .js.
if [[ ! -f "$JS_FILE" && -f "$BUILD_DIR/openttd" ]]; then
  if head -c 512 "$BUILD_DIR/openttd" |
      grep -qE '(^|[[:space:]])(var|let|const|import|function)[[:space:]]'; then
    JS_FILE="$BUILD_DIR/openttd"
  fi
fi

if [[ ! -f "$JS_FILE" || ! -f "$WASM_FILE" ]]; then
  echo "ERROR: Expected a JavaScript launcher and WebAssembly file." >&2
  find "$BUILD_DIR" -maxdepth 2 -type f \
    -printf '%p\n' 2>/dev/null | head -n 120 || true
  exit 1
fi

# Keep the JS and WASM basenames aligned with the generated loader.
cp "$JS_FILE" "$DIST/openttd.js"
cp "$WASM_FILE" "$DIST/openttd.wasm"

# Optional direct HTTPS ZIP URL for a legally redistributable pakset.
if [[ -n "${PAKSET_URL:-}" ]]; then
  mkdir -p "$DIST/game"
  curl --fail --location --retry 3 \
    "$PAKSET_URL" -o "$RUNNER_TEMP/pakset.zip"
  unzip -q "$RUNNER_TEMP/pakset.zip" -d "$DIST/game"
else
  echo "WARNING: PAKSET_URL is unset; game data may be missing."
fi

cp "$ROOT/web/index.html" "$DIST/index.html"
touch "$DIST/.nojekyll"

test -s "$DIST/index.html"
test -s "$DIST/openttd.js"
test -s "$DIST/openttd.wasm"

file "$DIST/openttd.js" "$DIST/openttd.wasm"

echo "Staged WebAssembly site in $DIST"