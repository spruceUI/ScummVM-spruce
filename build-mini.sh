#!/bin/bash
set -e

SCUMMVM_VERSION="${SCUMMVM_VERSION:-v2026.2.0}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

# UPLOAD STRUCTURE
EMU_DIR="$OUTPUT_DIR/Emu/SCUMMVM"
LIB_DIR="$OUTPUT_DIR/Emu/SCUMMVM/libmini"
LOGS_DIR="$OUTPUT_DIR/logs"

echo "=== Building ScummVM ${SCUMMVM_VERSION} for Miyoo Mini (SDL1.2, --host=miyoomini) ==="

# Clone ScummVM
if [ ! -d "scummvm" ]; then
    git clone --depth 1 --branch "$SCUMMVM_VERSION" \
        https://github.com/scummvm/scummvm.git
fi

cd scummvm

# Patch Directory
PATCH_DIRS="/patches/common /patches/mini"

# Apply patches
for dir in $PATCH_DIRS; do
    if [ -d "$dir" ] && ls "$dir"/*.patch 1>/dev/null 2>&1; then
        for patch in "$dir"/*.patch; do
            echo "Applying: $(basename "$patch")"
            git apply "$patch"
        done
    fi
done

# Apply Python patches
for dir in $PATCH_DIRS; do
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
    --enable-fluidlite | tee configure_summary.txt

# Build
make -j$(nproc)

# OUTPUT STRUCTURE
mkdir -p "$EMU_DIR/LICENSES" "$EMU_DIR/Theme" "$EMU_DIR/Extra" "$EMU_DIR/plugins"
mkdir -p "$LIB_DIR"
mkdir -p "$LOGS_DIR"

# Binary and Strip
cp scummvm "$EMU_DIR/scummvm.mini"
arm-linux-gnueabihf-strip "$EMU_DIR/scummvm.mini"

# Plugins
cp plugins/*.so "$EMU_DIR/plugins/"
arm-linux-gnueabihf-strip "$EMU_DIR/plugins/"*.so

# Assets
cp -f LICENSES/* "$EMU_DIR/LICENSES/"
[ -f dists/soundfonts/COPYRIGHT.Roland_SC-55 ] && cp -f dists/soundfonts/COPYRIGHT.Roland_SC-55 "$EMU_DIR/LICENSES/"
cp -f gui/themes/*.dat gui/themes/*.zip "$EMU_DIR/Theme/"
cp -f dists/networking/wwwroot.zip "$EMU_DIR/Theme/"
cp -f -r dists/engine-data/* "$EMU_DIR/Extra/"
rm -rf "$EMU_DIR/Extra/patches"
rm -rf "$EMU_DIR/Extra/testbed-audiocd-files"
rm -f "$EMU_DIR/Extra/README"
rm -f "$EMU_DIR/Extra/"*.mk
rm -f "$EMU_DIR/Extra/"*.sh
cp -f backends/vkeybd/packs/vkeybd_default.zip "$EMU_DIR/Extra/"
cp -f backends/vkeybd/packs/vkeybd_small.zip "$EMU_DIR/Extra/"
[ -f dists/soundfonts/Roland_SC-55.sf2 ] && cp -f dists/soundfonts/Roland_SC-55.sf2 "$EMU_DIR/Extra/"

mkdir -p "$EMU_DIR/Extra/shaders"
find engines/ -type f \( -name "*.fragment" -o -name "*.vertex" \) -exec cp -f {} "$EMU_DIR/Extra/shaders/" \;

# Bundle shared libs not available on the Mini device
for lib in libjpeg.so.62 libvorbisfile.so.3 libvorbis.so.0 libogg.so.0 \
           libgif.so.7 libtheoradec.so.1 libfluidlite.so libmad.so.0 \
           libfribidi.so.0; do
    found=$(find "$SYSROOT" -name "${lib}*" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        cp -L "$found" "$LIB_DIR/$lib"
        echo "Bundled: $lib"
    else
        echo "WARNING: $lib not found in sysroot"
    fi
done

# Logs Collection
cp -f configure_summary.txt config.log config.h config.mk "$LOGS_DIR/"

cd "$OUTPUT_DIR"
# Archive
BUILD_DATE=$(date +%m%d)
OUT_FILENAME="scummvm.mini.${BUILD_DATE}.7z"
7z a -t7z -m0=lzma2 -mx=9 "$OUT_FILENAME" Emu/ logs/

echo "=== Build complete: ${OUTPUT_DIR}/${OUT_FILENAME} ==="
