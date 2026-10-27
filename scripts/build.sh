
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/openttd-wasm-source"
DIST="$ROOT/dist"

: "${SOURCE_REPOSITORY:=https://github.com/OpenTTD/OpenTTD.git}"
: "${SOURCE_REF:=master}"

rm -rf "$WORK" "$DIST"
mkdir -p "$WORK" "$DIST"

echo "=== Fetching OpenTTD ==="
git clone --depth 1 --branch "$SOURCE_REF" \
  "$SOURCE_REPOSITORY" "$WORK"

cd "$WORK"

echo "=== Building OpenTTD Emscripten image ==="
docker build \
  -t openttd-emscripten \
  -f os/emscripten/Dockerfile \
  os/emscripten

# Use the container's native toolchain for host tools,
# and its Emscripten toolchain for the actual game.
run_build() {
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$WORK:$WORK" \
    -w "$WORK" \
    openttd-emscripten \
    "$@"
}

echo "=== Building native host tools ==="
run_build cmake \
  -S . \
  -B build-host \
  -DOPTION_TOOLS_ONLY=ON \
  -DCMAKE_BUILD_TYPE=Release

run_build cmake \
  --build build-host \
  --target tools \
  --parallel 2

echo "=== Configuring WebAssembly build ==="
run_build emcmake cmake \
  -S . \
  -B build \
  -DHOST_BINARY_DIR="$WORK/build-host" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPTION_USE_ASSERTS=OFF

echo "=== Compiling WebAssembly ==="
run_build cmake \
  --build build \
  --target openttd \
  --parallel 2

echo "=== Inspecting artifacts ==="
ls -lh build/openttd.*

for ext in html js wasm data; do
  test -s "build/openttd.$ext" || {
    echo "Missing build/openttd.$ext" >&2
    exit 1
  }
done

echo "=== Staging site ==="
cp build/openttd.js "$DIST/"
cp build/openttd.wasm "$DIST/"
cp build/openttd.data "$DIST/"
cp build/openttd.html "$DIST/index.html"

touch "$DIST/.nojekyll"

echo "=== Final output ==="
ls -lh "$DIST"

echo "Build complete: $DIST"
