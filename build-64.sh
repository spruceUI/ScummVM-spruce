#!/bin/bash
set -e

SCUMMVM_VERSION="${SCUMMVM_VERSION:-v2026.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
OUT_DIR="$OUTPUT_DIR/Emu/SCUMMVM"

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

# Configure for universal 64-bit: SDL2 + OpenGL ES2, all engines
./configure \
    --host=aarch64-linux-gnu \
    --backend=sdl \
    --opengl-mode=gles2 \
    --enable-all-engines \
    --enable-optimizations \
    --enable-release \
    --disable-debug \
    --disable-eventrecorder \
    --enable-vkeybd \
    --enable-fluidsynth | tee configure_summary.txt

# Build
make -j$(nproc)

# Output
mkdir -p "$OUT_DIR/LICENSES" "$OUT_DIR/Theme" "$OUT_DIR/Extra" "$OUT_DIR/lib" "$OUT_DIR/logs"

cp scummvm "$OUT_DIR/scummvm.64"
aarch64-linux-gnu-strip "$OUT_DIR/scummvm.64"

cp -f LICENSES/* "$OUT_DIR/LICENSES/"
[ -f dists/soundfonts/COPYRIGHT.Roland_SC-55 ] && cp -f dists/soundfonts/COPYRIGHT.Roland_SC-55 "$OUT_DIR/LICENSES/"
cp -f gui/themes/*.dat gui/themes/*.zip "$OUT_DIR/Theme/"
cp -f dists/networking/wwwroot.zip "$OUT_DIR/Theme/"
cp -f -r dists/engine-data/* "$OUT_DIR/Extra/"
rm -rf "$OUT_DIR/Extra/patches"
rm -rf "$OUT_DIR/Extra/testbed-audiocd-files"
rm -f "$OUT_DIR/Extra/README"
rm -f "$OUT_DIR/Extra/"*.mk
rm -f "$OUT_DIR/Extra/"*.sh
cp -f backends/vkeybd/packs/vkeybd_default.zip "$OUT_DIR/Extra/"
cp -f backends/vkeybd/packs/vkeybd_small.zip "$OUT_DIR/Extra/"
[ -f dists/soundfonts/Roland_SC-55.sf2 ] && cp -f dists/soundfonts/Roland_SC-55.sf2 "$OUT_DIR/Extra/"
mkdir -p "$OUT_DIR/Extra/shaders"
find engines/ -type f \( -name "*.fragment" -o -name "*.vertex" \) -exec cp -f {} "$OUT_DIR/Extra/shaders/" \;

LIBS=(
  "liba52-0.7.4.so" "libasn1.so.8" "libasound.so.2" "libbrotlicommon.so.1"
  "libbrotlidec.so.1" "libbsd.so.0" "libcom_err.so.2" "libcrypt.so.1"
  "libcrypto.so.1.1" "libcurl.so.4" "libcurl-gnutls.so.4" "libfaad.so.2"
  "libffi.so.7" "libFLAC.so.8" "libfluidsynth.so.3" "libfreetype.so.6"
  "libfribidi.so.0" "libgif.so.7" "libgmp.so.10" "libgnutls.so.30"
  "libgssapi.so.3" "libgssapi_krb5.so.2" "libhcrypto.so.4" "libheimbase.so.1"
  "libheimntlm.so.0" "libhogweed.so.5" "libhx509.so.5" "libidn2.so.0"
  "libk5crypto.so.3" "libkeyutils.so.1" "libkrb5.so.3" "libkrb5.so.26"
  "libkrb5support.so.0" "liblber-2.4.so.2" "libldap_r-2.4.so.2" "liblzma.so.5"
  "libmikmod.so.3" "libmpeg2.so.0" "libnettle.so.7" "libnghttp2.so.14"
  "libp11-kit.so.0" "libpng16.so.16" "libpsl.so.5" "libroken.so.18"
  "librtmp.so.1" "libsasl2.so.2" "libsndio.so.7.0" "libspeechd.so.2"
  "libsqlite3.so.0" "libssh.so.4" "libssl.so.1.1" "libtasn1.so.6"
  "libunistring.so.2" "libwind.so.0" "libz.so.1" "libvpx.so.6"
)

for lib in "${LIBS[@]}"; do
    TARGET=$(find /usr/lib/aarch64-linux-gnu -name "$lib*" -print -quit)
    if [ -n "$TARGET" ]; then
        cp -L "$TARGET" "$OUT_DIR/lib/$lib"
    fi
done

cp -f configure_summary.txt config.log config.h config.mk "$OUT_DIR/logs/"

cd "$OUTPUT_DIR"
7z a -t7z -m0=lzma2 -mx=9 scummvm.64.7z Emu/

echo "=== Build complete: ${OUTPUT_DIR}/scummvm.64.7z ==="
