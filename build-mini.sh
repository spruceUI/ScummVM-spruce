#!/bin/bash
set -e

SCUMMVM_VERSION="${SCUMMVM_VERSION:-v2026.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== Building ScummVM ${SCUMMVM_VERSION} for Miyoo Mini (armhf) ==="

# Clone ScummVM
if [ ! -d "scummvm" ]; then
    git clone --depth 1 --branch "$SCUMMVM_VERSION" \
        https://github.com/scummvm/scummvm.git
fi

cd scummvm

# Apply patches
for dir in /patches/common /patches/mini; do
    if [ -d "$dir" ] && ls "$dir"/*.patch 1>/dev/null 2>&1; then
        for patch in "$dir"/*.patch; do
            echo "Applying: $(basename "$patch")"
            git apply "$patch"
        done
    fi
done

# Miyoo Mini toolchain (steward-fu, cortex-a7)
TOOLCHAIN=/opt/mmiyoo
SYSROOT=$TOOLCHAIN/arm-buildroot-linux-gnueabihf/sysroot
CROSS=arm-linux-gnueabihf

export PATH="$TOOLCHAIN/bin:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
export CC="ccache ${CROSS}-gcc"
export CXX="ccache ${CROSS}-g++"
export AR="${CROSS}-ar"
export STRIP="${CROSS}-strip"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
# No explicit --sysroot: the buildroot compiler has it built-in
export CFLAGS="-marm -mtune=cortex-a7 -march=armv7ve+simd -mfpu=neon-vfpv4 -mfloat-abi=hard -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$SYSROOT/usr/lib"

# Configure for Miyoo Mini: SDL2 backend, static build (Mini has very few system libs)
./configure \
    --host=arm-linux-gnueabihf \
    --backend=sdl \
    --enable-static \
    --enable-optimizations \
    --enable-release \
    --disable-debug \
    --disable-eventrecorder \
    --disable-mikmod \
    --with-sdl-prefix="$SYSROOT/usr"

# Build
make -j$(nproc)

# Output
mkdir -p "$OUTPUT_DIR"
cp scummvm "$OUTPUT_DIR/"
${CROSS}-strip "$OUTPUT_DIR/scummvm"

# Bundle shared libs not available on the Mini device
LIBS_DIR="$OUTPUT_DIR/libs"
mkdir -p "$LIBS_DIR"

# SDL2 must come from the known install path (not find) because the sysroot
# also contains the old buildroot SDL2 and find may pick the wrong one
cp -L "$SYSROOT/usr/lib/libSDL2-2.0.so.0" "$LIBS_DIR/libSDL2-2.0.so.0"
echo "Bundled: libSDL2-2.0.so.0"

for lib in libvorbisfile.so.3 libvorbis.so.0 libogg.so.0 libmad.so.0 \
           libasound.so.2 libjpeg.so.9 libgif.so.7 libfreetype.so.6 \
           libfribidi.so.0 libtheoradec.so.1 libSDL2_net-2.0.so.0; do
    found=$(find "$SYSROOT" -name "${lib}*" -type f | head -1)
    if [ -n "$found" ]; then
        cp "$found" "$LIBS_DIR/$lib"
        echo "Bundled: $lib"
    else
        echo "WARNING: $lib not found in sysroot"
    fi
done

echo "=== Build complete: ${OUTPUT_DIR}/scummvm ==="
