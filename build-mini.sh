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

# Apply Python patches (common + mini)
for dir in /patches/common /patches/mini; do
    if [ -d "$dir" ] && ls "$dir"/*.py 1>/dev/null 2>&1; then
        for patch in "$dir"/*.py; do
            echo "Applying: $(basename "$patch")"
            python3 "$patch"
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

# SDL2 is NOT bundled — device SDL2 from spruce/miyoomini/lib/ is used at runtime
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

# Build joyinfo helper (prints joystick GUID and mapping info)
cat > /tmp/joyinfo.c << 'JOYEOF'
#include <SDL2/SDL.h>
#include <stdio.h>
int main() {
    SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER);
    int n = SDL_NumJoysticks();
    printf("Joysticks: %d\n", n);
    for (int i = 0; i < n; i++) {
        printf("Joy %d: %s\n", i, SDL_JoystickNameForIndex(i));
        SDL_JoystickGUID guid = SDL_JoystickGetDeviceGUID(i);
        char gs[64];
        SDL_JoystickGetGUIDString(guid, gs, sizeof(gs));
        printf("  GUID: %s\n", gs);
        printf("  IsGameController: %d\n", SDL_IsGameController(i));
        if (SDL_IsGameController(i))
            printf("  GC Name: %s\n", SDL_GameControllerNameForIndex(i));
        SDL_Joystick *j = SDL_JoystickOpen(i);
        if (j) {
            printf("  Axes: %d  Buttons: %d  Hats: %d\n",
                SDL_JoystickNumAxes(j), SDL_JoystickNumButtons(j), SDL_JoystickNumHats(j));
            SDL_JoystickClose(j);
        }
    }
    SDL_Quit();
    return 0;
}
JOYEOF
${CROSS}-gcc -o "$OUTPUT_DIR/joyinfo" /tmp/joyinfo.c \
    -I"$SYSROOT/usr/include/SDL2" -L"$SYSROOT/usr/lib" -lSDL2 -static-libgcc
${CROSS}-strip "$OUTPUT_DIR/joyinfo"
echo "Built joyinfo helper"

echo "=== Build complete: ${OUTPUT_DIR}/scummvm ==="
