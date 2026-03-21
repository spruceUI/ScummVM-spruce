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

# Fix mouse cursor position for rotated displays on fbdev.
# The cursor is rendered in pre-rotation (logical) space, so setMousePosition
# needs transformed coords. But convertWindowToVirtual already handles rotation
# internally, so it must receive the original physical window coords.
python3 << 'PYEOF'
with open('backends/graphics/sdl/sdl-graphics.cpp', 'r') as f:
    code = f.read()

old = '''\tif (valid) {
\t\tsetMousePosition(mouse.x, mouse.y);
\t\tmouse = convertWindowToVirtual(mouse.x, mouse.y);
\t}'''

new = '''\tif (valid) {
\t\t// Debug: log window dims and mouse coords (temporary)
\t\t{
\t\t\tstatic int logCount = 0;
\t\t\tif (logCount < 200 && logCount % 10 == 0) {
\t\t\t\twarning("MOUSE wW=%d wH=%d mx=%d my=%d drL=%d drT=%d drR=%d drB=%d rot=%d",
\t\t\t\t\t_windowWidth, _windowHeight, mouse.x, mouse.y,
\t\t\t\t\t_activeArea.drawRect.left, _activeArea.drawRect.top,
\t\t\t\t\t_activeArea.drawRect.right, _activeArea.drawRect.bottom,
\t\t\t\t\t(int)_rotationMode);
\t\t\t}
\t\t\tlogCount++;
\t\t}
\t\tsetMousePosition(mouse.x, mouse.y);
\t\tmouse = convertWindowToVirtual(mouse.x, mouse.y);
\t}'''

assert old in code, 'Could not find setMousePosition/convertWindowToVirtual block to patch'
code = code.replace(old, new)

with open('backends/graphics/sdl/sdl-graphics.cpp', 'w') as f:
    f.write(code)
PYEOF
echo "Patched mouse coordinates for rotated display"

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
