#!/bin/bash
set -e

SCUMMVM_VERSION="${SCUMMVM_VERSION:-v2026.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== Building ScummVM ${SCUMMVM_VERSION} for aarch64 (universal 64-bit) ==="

# Clone ScummVM
if [ ! -d "scummvm" ]; then
    git clone --depth 1 --branch "$SCUMMVM_VERSION" \
        https://github.com/scummvm/scummvm.git
fi

cd scummvm

# Apply patches
for dir in /patches/common /patches/64; do
    if [ -d "$dir" ] && ls "$dir"/*.patch 1>/dev/null 2>&1; then
        for patch in "$dir"/*.patch; do
            echo "Applying: $(basename "$patch")"
            git apply "$patch"
        done
    fi
done

# Apply Python patches
for dir in /patches/common /patches/64; do
    if [ -d "$dir" ] && ls "$dir"/*.py 1>/dev/null 2>&1; then
        for patch in "$dir"/*.py; do
            echo "Applying: $(basename "$patch")"
            python3 "$patch"
        done
    fi
done

# Cross-compilation environment
export CC="ccache aarch64-linux-gnu-gcc"
export CXX="ccache aarch64-linux-gnu-g++"
export AR="aarch64-linux-gnu-ar"
export STRIP="aarch64-linux-gnu-strip"
export PKG_CONFIG_PATH="/usr/lib/aarch64-linux-gnu/pkgconfig"
export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"

export CFLAGS="-O3 -flto=auto"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-flto=auto"

echo "ac_cv_c_bigendian=no" > config.cache

# Configure without optimization flags so probe tests work correctly
./configure \
    --cache-file=config.cache \
    --host=aarch64-linux-gnu \
    --backend=sdl \
    --opengl-mode=gles2 \
    --enable-all-engines \
    --enable-optimizations \
    --enable-release \
    --disable-debug \
    --disable-eventrecorder \
    --enable-vkeybd \
    --enable-fluidsynth

# Build
make -j$(nproc)

# Output
mkdir -p "$OUTPUT_DIR"
cp scummvm "$OUTPUT_DIR/"
aarch64-linux-gnu-strip -s "$OUTPUT_DIR/scummvm"

echo "=== Build complete: ${OUTPUT_DIR}/scummvm ==="
