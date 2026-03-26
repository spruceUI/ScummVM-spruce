#!/bin/bash
set -e

SCUMMVM_VERSION="${SCUMMVM_VERSION:-v2026.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

echo "=== Building ScummVM ${SCUMMVM_VERSION} for Miyoo Mini (SDL1.2, --host=miyoomini) ==="

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

# Apply Python patches
for dir in /patches/common /patches/mini; do
    if [ -d "$dir" ] && ls "$dir"/*.py 1>/dev/null 2>&1; then
        for patch in "$dir"/*.py; do
            echo "Applying: $(basename "$patch")"
            python3 "$patch"
        done
    fi
done

# OnionOS miyoomini toolchain (SDL1.2 + MMIYOO drivers, cortex-a7)
TOOLCHAIN=/opt/miyoomini-toolchain
SYSROOT=$TOOLCHAIN/arm-linux-gnueabihf/libc
export PATH="$TOOLCHAIN/bin:$SYSROOT/usr/bin:$PATH"
export CXX="ccache arm-linux-gnueabihf-g++"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"

# Configure using upstream --host=miyoomini
# This sets SDL1.2, miyoo backend, MIYOOMINI define, correct CPU flags,
# and enables d-pad-as-mouse input mapping automatically
./configure \
    --host=miyoomini \
    --enable-release \
    --enable-plugins --default-dynamic \
    --disable-detection-full \
    --enable-fluidlite

# Build
make -j$(nproc)

# Output — binary + plugins + data
mkdir -p "$OUTPUT_DIR"

# Binary
cp scummvm "$OUTPUT_DIR/"
arm-linux-gnueabihf-strip "$OUTPUT_DIR/scummvm"

# Plugins
mkdir -p "$OUTPUT_DIR/plugins"
cp plugins/*.so "$OUTPUT_DIR/plugins/"
arm-linux-gnueabihf-strip "$OUTPUT_DIR/plugins/"*.so

# Themes
mkdir -p "$OUTPUT_DIR/Theme"
cp gui/themes/*.dat gui/themes/*.zip "$OUTPUT_DIR/Theme/"

# Extra data
mkdir -p "$OUTPUT_DIR/Extra"
cp -r dists/engine-data/* "$OUTPUT_DIR/Extra/"
rm -rf "$OUTPUT_DIR/Extra/patches" "$OUTPUT_DIR/Extra/testbed-audiocd-files"
rm -f "$OUTPUT_DIR/Extra/README" "$OUTPUT_DIR/Extra/"*.mk "$OUTPUT_DIR/Extra/"*.sh

# Virtual keyboard
cp backends/vkeybd/packs/vkeybd_default.zip "$OUTPUT_DIR/Extra/"
cp backends/vkeybd/packs/vkeybd_small.zip "$OUTPUT_DIR/Extra/"

# Soundfont
cp dists/soundfonts/Roland_SC-55.sf2 "$OUTPUT_DIR/Extra/" 2>/dev/null || true

# Bundle shared libs not available on the Mini device
LIBS_DIR="$OUTPUT_DIR/libs"
mkdir -p "$LIBS_DIR"
for lib in libjpeg.so.62 libvorbisfile.so.3 libvorbis.so.0 libogg.so.0 \
           libgif.so.7 libtheoradec.so.1 libfluidlite.so; do
    found=$(find "$SYSROOT" -name "${lib}*" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        cp "$found" "$LIBS_DIR/$lib"
        echo "Bundled: $lib"
    else
        echo "WARNING: $lib not found in sysroot"
    fi
done

echo "=== Build complete ==="
