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

# Handle display rotation at the rendering level instead of using ScummVM's
# rotation_mode (which breaks mouse input). Check DISPLAY_ROTATION env var.
# Approach: swap reported window dimensions so ScummVM works in landscape,
# then rotate the final SDL_RenderCopy output to fit the portrait panel.
# This matches the RetroArch approach (RA patches the GL viewport similarly).

# Patch 1: Swap window dimensions so ScummVM sees 640x480 (landscape)
python3 << 'PYEOF'
with open('backends/graphics/surfacesdl/surfacesdl-graphics.cpp', 'r') as f:
    code = f.read()

# After getWindowSizeFromSdl, swap dimensions if DISPLAY_ROTATION is set
old = '''\tgetWindowSizeFromSdl(&_windowWidth, &_windowHeight);
\thandleResize(_windowWidth, _windowHeight);'''

new = '''\tgetWindowSizeFromSdl(&_windowWidth, &_windowHeight);
\t// Swap dimensions for rotated portrait panels (e.g. A30 480x640 used as landscape)
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0)) {
\t\tint tmp = _windowWidth; _windowWidth = _windowHeight; _windowHeight = tmp;
\t}
\thandleResize(_windowWidth, _windowHeight);'''

assert old in code, 'Could not find getWindowSizeFromSdl/handleResize block'
code = code.replace(old, new)

# Also swap in notifyResize for runtime resize events
old = '''void SurfaceSdlGraphicsManager::notifyResize(const int width, const int height) {
#if SDL_VERSION_ATLEAST(2, 0, 0)
\thandleResize(width, height);'''

new = '''void SurfaceSdlGraphicsManager::notifyResize(const int width, const int height) {
#if SDL_VERSION_ATLEAST(2, 0, 0)
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0))
\t\thandleResize(height, width);
\telse
\t\thandleResize(width, height);'''

assert old in code, 'Could not find notifyResize'
code = code.replace(old, new)

# Force viewport swap AND rotation in SDL_UpdateRects
old = '''\t/* Destination rectangle represents the texture before rotation */
\tif (_rotationMode == Common::kRotation90 || _rotationMode == Common::kRotation270) {'''

new = '''\t/* Destination rectangle represents the texture before rotation */
\tint _effectiveRotation = (int)_rotationMode;
\tif (_effectiveRotation == 0 && SDL_getenv("DISPLAY_ROTATION"))
\t\t_effectiveRotation = SDL_atoi(SDL_getenv("DISPLAY_ROTATION"));
\tif (_effectiveRotation != (int)_rotationMode
\t\t&& (_effectiveRotation == 90 || _effectiveRotation == 270)) {
\t\t// DISPLAY_ROTATION without rotation_mode: drawRect is in logical
\t\t// (swapped) space. Center content on physical surface.
\t\tviewport.w = drawRect.width();
\t\tviewport.h = drawRect.height();
\t\tviewport.x = (_windowHeight - viewport.w) / 2;
\t\tviewport.y = (_windowWidth - viewport.h) / 2;
\t} else if (_rotationMode == Common::kRotation90 || _rotationMode == Common::kRotation270) {'''

assert old in code, 'Could not find viewport rotation check'
code = code.replace(old, new)

# Use _effectiveRotation for the angle too
old2 = '''\tint rotangle = (int)_rotationMode;'''
new2 = '''\tint rotangle = _effectiveRotation;'''
assert old2 in code, 'Could not find rotangle assignment'
code = code.replace(old2, new2)

with open('backends/graphics/surfacesdl/surfacesdl-graphics.cpp', 'w') as f:
    f.write(code)
PYEOF
echo "Patched surfacesdl for display rotation without rotation_mode"

# Patch 2: Scale mouse X from physical window to logical (swapped) space.
# SDL constrains mouse to the physical portrait window (e.g. 480x640), but after
# our dimension swap ScummVM expects landscape width (640). The X axis can't reach
# the right edge without scaling. Y axis is fine — excess range gets clipped by
# the drawRect bounds in notifyMousePosition.
python3 << 'PYEOF'
with open('backends/graphics/sdl/sdl-graphics.cpp', 'r') as f:
    code = f.read()

# Scale mouse X in notifyMousePosition right after DPI scaling
old = '''\tmouse.x = (int)(mouse.x * dpiScale + 0.5f);
\tmouse.y = (int)(mouse.y * dpiScale + 0.5f);'''

new = '''\tmouse.x = (int)(mouse.x * dpiScale + 0.5f);
\tmouse.y = (int)(mouse.y * dpiScale + 0.5f);
\t// Scale mouse X from physical to logical width for rotated display.
\t// Y is left alone — it has more range than needed and gets clipped by drawRect.
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0)) {
\t\tmouse.x = (mouse.x * _windowWidth + _windowHeight / 2) / _windowHeight;
\t}'''

assert old in code, 'Could not find dpiScale mouse assignment in sdl-graphics.cpp'
code = code.replace(old, new)

# Inverse-scale X in setSystemMousePosition so SDL warp uses physical coords
old2 = '''void SdlGraphicsManager::setSystemMousePosition(const int x, const int y) {
\tassert(_window);
\tif (!_window->warpMouseInWindow(x, y)) {'''

new2 = '''void SdlGraphicsManager::setSystemMousePosition(const int x, const int y) {
\tassert(_window);
\tint warpX = x;
\t// Convert logical X back to physical for SDL warp on rotated display
\tif (SDL_getenv("DISPLAY_ROTATION") && (SDL_atoi(SDL_getenv("DISPLAY_ROTATION")) % 180 != 0)) {
\t\twarpX = (x * _windowHeight + _windowWidth / 2) / _windowWidth;
\t}
\tif (!_window->warpMouseInWindow(warpX, y)) {'''

assert old2 in code, 'Could not find setSystemMousePosition in sdl-graphics.cpp'
code = code.replace(old2, new2)

with open('backends/graphics/sdl/sdl-graphics.cpp', 'w') as f:
    f.write(code)
PYEOF
echo "Patched sdl-graphics for mouse X scaling on rotated display"

# Apply common Python patches
if [ -d /patches/common ] && ls /patches/common/*.py 1>/dev/null 2>&1; then
    for patch in /patches/common/*.py; do
        echo "Applying: $(basename "$patch")"
        python3 "$patch"
    done
fi

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
    --enable-fluidlite \
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
cp "$SYSROOT/usr/lib/libfluidlite.so"* "$OUTPUT_DIR/"

# Build fixjoy helper: reads and fixes evdev axis calibration
cat > /tmp/fixjoy.c << 'FIXJOY'
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    const char *dev = argc > 1 ? argv[1] : "/dev/input/event4";
    int range = argc > 2 ? atoi(argv[2]) : 128;
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    int i;
    for (i = 0; i < 6; i++) {
        struct input_absinfo info;
        if (ioctl(fd, EVIOCGABS(i), &info) == 0) {
            printf("axis %d: val=%d min=%d max=%d fuzz=%d flat=%d\n",
                   i, info.value, info.minimum, info.maximum, info.fuzz, info.flat);
            if (info.minimum < -range || info.maximum > range) {
                printf("  -> fixing range to [%d, %d]\n", -range, range);
                info.minimum = -range;
                info.maximum = range;
                info.fuzz = 0;
                info.flat = 0;
                ioctl(fd, EVIOCSABS(i), &info);
            }
        }
    }
    close(fd);
    return 0;
}
FIXJOY
${CROSS}-gcc -static -o "$OUTPUT_DIR/fixjoy" /tmp/fixjoy.c
${CROSS}-strip "$OUTPUT_DIR/fixjoy"
echo "Built fixjoy helper"

echo "=== Build complete: ${OUTPUT_DIR}/scummvm ==="
