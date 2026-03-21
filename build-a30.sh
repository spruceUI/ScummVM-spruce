#!/bin/bash
set -e

SCUMMVM_VERSION="${SCUMMVM_VERSION:-v2026.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== Building ScummVM ${SCUMMVM_VERSION} for A30 (armhf) ==="

# Clone ScummVM
if [ ! -d "scummvm" ]; then
    git clone --depth 1 --branch "$SCUMMVM_VERSION" \
        https://github.com/scummvm/scummvm.git
fi

cd scummvm

# Apply patches
for dir in /patches/common /patches/a30; do
    if [ -d "$dir" ] && ls "$dir"/*.patch 1>/dev/null 2>&1; then
        for patch in "$dir"/*.patch; do
            echo "Applying: $(basename "$patch")"
            git apply "$patch"
        done
    fi
done

# Fix SDL_WarpMouseInWindow on fbdev: the warp does not reliably generate
# a motion event with correct coordinates (Y stays stale). Push a synthetic
# SDL_MOUSEMOTION after every warp so the position is always up to date.
python3 << 'PYEOF'
with open('backends/platform/sdl/sdl-window.cpp', 'r') as f:
    code = f.read()

old = '''\t\t\tSDL_WarpMouseInWindow(_window, x, y);
\t\t\treturn true;'''

new = '''\t\t\t// Skip SDL_WarpMouseInWindow on fbdev — it generates motion
\t\t\t// events with a stale Y coordinate, corrupting mouse position.
\t\t\t// Push a synthetic motion event with correct coords instead.
\t\t\tSDL_Event syntheticMotion;
\t\t\tmemset(&syntheticMotion, 0, sizeof(syntheticMotion));
\t\t\tsyntheticMotion.type = SDL_MOUSEMOTION;
\t\t\tsyntheticMotion.motion.x = x;
\t\t\tsyntheticMotion.motion.y = y;
\t\t\tSDL_PushEvent(&syntheticMotion);
\t\t\treturn true;'''

assert old in code, 'Could not find SDL_WarpMouseInWindow call to patch'
code = code.replace(old, new)

with open('backends/platform/sdl/sdl-window.cpp', 'w') as f:
    f.write(code)
PYEOF
echo "Patched SDL_WarpMouseInWindow for fbdev"

# Fix warpMouse() comparison: the cursor transform stores pre-rotation coords
# in _cursorX/_cursorY, but warpMouse reads them as window coords through
# convertWindowToVirtual, producing wrong results and skipping warps.
# Remove the comparison so warps always execute.
python3 << 'PYEOF'
with open('backends/graphics/windowed.h', 'r') as f:
    code = f.read()

old = '''\t\tconst Common::Point virtualCursor = convertWindowToVirtual(_cursorX, _cursorY);
\t\tif (virtualCursor.x != x || virtualCursor.y != y) {
\t\t\tconst Common::Point windowCursor = convertVirtualToWindow(x, y);
\t\t\tsetMousePosition(windowCursor.x, windowCursor.y);
\t\t\tsetSystemMousePosition(windowCursor.x, windowCursor.y);
\t\t}'''

new = '''\t\tconst Common::Point windowCursor = convertVirtualToWindow(x, y);
\t\tsetMousePosition(windowCursor.x, windowCursor.y);
\t\tsetSystemMousePosition(windowCursor.x, windowCursor.y);'''

assert old in code, 'Could not find warpMouse comparison to patch'
code = code.replace(old, new)

with open('backends/graphics/windowed.h', 'w') as f:
    f.write(code)
PYEOF
echo "Patched warpMouse to skip position comparison"

# Fix cursor rendering for rotated displays on fbdev.
# The cursor is drawn in the pre-rotation framebuffer, so setMousePosition
# needs pre-rotation coordinates. convertWindowToVirtual already handles
# rotation for game events, so it must keep the original window coords.
python3 << 'PYEOF'
with open('backends/graphics/sdl/sdl-graphics.cpp', 'r') as f:
    code = f.read()

old = '''\tif (valid) {
\t\tsetMousePosition(mouse.x, mouse.y);
\t\tmouse = convertWindowToVirtual(mouse.x, mouse.y);
\t}'''

new = '''\tif (valid) {
\t\t// Cursor is drawn in pre-rotation space, so transform window
\t\t// coords to pre-rotation coords for setMousePosition.
\t\t// convertWindowToVirtual handles rotation internally.
\t\tif (_rotationMode == Common::kRotation270) {
\t\t\tsetMousePosition((_windowHeight - 1) - mouse.y, mouse.x);
\t\t} else if (_rotationMode == Common::kRotation90) {
\t\t\tsetMousePosition(mouse.y, (_windowWidth - 1) - mouse.x);
\t\t} else {
\t\t\tsetMousePosition(mouse.x, mouse.y);
\t\t}
\t\tmouse = convertWindowToVirtual(mouse.x, mouse.y);
\t}'''

assert old in code, 'Could not find setMousePosition/convertWindowToVirtual block to patch'
code = code.replace(old, new)

with open('backends/graphics/sdl/sdl-graphics.cpp', 'w') as f:
    f.write(code)
PYEOF
echo "Patched cursor position for rotated display"

# A30 buildroot toolchain
TOOLCHAIN=/opt/a30
SYSROOT=$TOOLCHAIN/arm-a30-linux-gnueabihf/sysroot
CROSS=arm-a30-linux-gnueabihf

export PATH="$TOOLCHAIN/bin:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CC="ccache ${CROSS}-gcc"
export CXX="ccache ${CROSS}-g++"
export AR="${CROSS}-ar"
export STRIP="${CROSS}-strip"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export CFLAGS="--sysroot=$SYSROOT -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/usr/lib -static-libstdc++"

# Remove fontconfig from sysroot so configure won't auto-detect it
# (not present on the A30 device, and drags in libexpat/libpng16)
rm -f "$SYSROOT/usr/lib/libfontconfig"* "$SYSROOT/usr/lib/pkgconfig/fontconfig.pc"

# Configure for A30: SDL2 backend
./configure \
    --host=arm-linux-gnueabihf \
    --backend=sdl \
    --enable-optimizations \
    --enable-release \
    --disable-debug \
    --disable-eventrecorder \
    --with-sdl-prefix="$SYSROOT/usr"

# Build
make -j$(nproc)

# Output
mkdir -p "$OUTPUT_DIR"
cp scummvm "$OUTPUT_DIR/"
${CROSS}-strip "$OUTPUT_DIR/scummvm"

# Bundle libs not on device
cp "$SYSROOT/usr/lib/libtheoradec.so.1"* "$OUTPUT_DIR/"
cp "$SYSROOT/usr/lib/libSDL2_net-2.0.so.0"* "$OUTPUT_DIR/"

echo "=== Build complete: ${OUTPUT_DIR}/scummvm ==="
