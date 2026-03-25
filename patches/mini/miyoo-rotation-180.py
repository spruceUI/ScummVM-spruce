#!/usr/bin/env python3
"""Patch MiyooMiniGraphicsManager to rotate display 180 degrees.

Uses a separate flip buffer so ScummVM's _hwScreen is never modified.
This avoids dirty rect flickering from previous rotation attempts.
"""
import sys

# Patch header first to declare _flipBuffer
HPATH = 'backends/graphics/miyoo/miyoomini-graphics.h'
with open(HPATH) as f:
    hdr = f.read()

OLD_HDR = '\tSDL_Surface *_realHwScreen;'
NEW_HDR = '\tSDL_Surface *_realHwScreen;\n\tSDL_Surface *_flipBuffer = nullptr;'

if OLD_HDR not in hdr:
    print(f'ERROR: cannot find _realHwScreen in {HPATH}', file=sys.stderr)
    sys.exit(1)
hdr = hdr.replace(OLD_HDR, NEW_HDR, 1)
with open(HPATH, 'w') as f:
    f.write(hdr)
print(f'Patched {HPATH}: added _flipBuffer declaration')

# Now patch the implementation
PATH = 'backends/graphics/miyoo/miyoomini-graphics.cpp'
with open(PATH) as f:
    src = f.read()

# 1. Add flip buffer to initGraphicsSurface
OLD_INIT = '''void MiyooMiniGraphicsManager::initGraphicsSurface() {
	_hwScreen = nullptr;
	_realHwScreen = SDL_SetVideoMode(_videoMode.hardwareWidth, _videoMode.hardwareHeight, 32,
					 SDL_HWSURFACE);
	if (!_realHwScreen)
		return;
	_hwScreen = SDL_CreateRGBSurface(SDL_HWSURFACE, _videoMode.hardwareWidth, _videoMode.hardwareHeight,
					 _realHwScreen->format->BitsPerPixel,
					 _realHwScreen->format->Rmask,
					 _realHwScreen->format->Gmask,
					 _realHwScreen->format->Bmask,
					 _realHwScreen->format->Amask);
	_isDoubleBuf = false;
	_isHwPalette = false;
}'''

NEW_INIT = '''void MiyooMiniGraphicsManager::initGraphicsSurface() {
	_hwScreen = nullptr;
	_realHwScreen = SDL_SetVideoMode(_videoMode.hardwareWidth, _videoMode.hardwareHeight, 32,
					 SDL_HWSURFACE);
	if (!_realHwScreen)
		return;
	_hwScreen = SDL_CreateRGBSurface(SDL_HWSURFACE, _videoMode.hardwareWidth, _videoMode.hardwareHeight,
					 _realHwScreen->format->BitsPerPixel,
					 _realHwScreen->format->Rmask,
					 _realHwScreen->format->Gmask,
					 _realHwScreen->format->Bmask,
					 _realHwScreen->format->Amask);
	_flipBuffer = SDL_CreateRGBSurface(SDL_SWSURFACE, _videoMode.hardwareWidth, _videoMode.hardwareHeight,
					 _realHwScreen->format->BitsPerPixel,
					 _realHwScreen->format->Rmask,
					 _realHwScreen->format->Gmask,
					 _realHwScreen->format->Bmask,
					 _realHwScreen->format->Amask);
	_isDoubleBuf = false;
	_isHwPalette = false;
}'''

if OLD_INIT not in src:
    print(f'ERROR: cannot find initGraphicsSurface in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_INIT, NEW_INIT, 1)
print('Patch 1: Added _flipBuffer creation in initGraphicsSurface')

# 2. Free flip buffer in unloadGFXMode
OLD_UNLOAD = '''void MiyooMiniGraphicsManager::unloadGFXMode() {
	if (_realHwScreen) {
		SDL_FreeSurface(_realHwScreen);
		_realHwScreen = nullptr;
	}
	SurfaceSdlGraphicsManager::unloadGFXMode();
}'''

NEW_UNLOAD = '''void MiyooMiniGraphicsManager::unloadGFXMode() {
	if (_flipBuffer) {
		SDL_FreeSurface(_flipBuffer);
		_flipBuffer = nullptr;
	}
	if (_realHwScreen) {
		SDL_FreeSurface(_realHwScreen);
		_realHwScreen = nullptr;
	}
	SurfaceSdlGraphicsManager::unloadGFXMode();
}'''

if OLD_UNLOAD not in src:
    print(f'ERROR: cannot find unloadGFXMode in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_UNLOAD, NEW_UNLOAD, 1)
print('Patch 2: Added _flipBuffer cleanup in unloadGFXMode')

# 3. Rotate in updateScreen using flip buffer
OLD_UPDATE = '''void MiyooMiniGraphicsManager::updateScreen(SDL_Rect *dirtyRectList, int actualDirtyRects) {
	SDL_BlitSurface(_hwScreen, nullptr, _realHwScreen, nullptr);
	SDL_UpdateRects(_realHwScreen, actualDirtyRects, _dirtyRectList);
}'''

NEW_UPDATE = '''void MiyooMiniGraphicsManager::updateScreen(SDL_Rect *dirtyRectList, int actualDirtyRects) {
	// Rotate 180° via separate flip buffer (never modify _hwScreen)
	if (_flipBuffer) {
		if (SDL_MUSTLOCK(_hwScreen)) SDL_LockSurface(_hwScreen);
		if (SDL_MUSTLOCK(_flipBuffer)) SDL_LockSurface(_flipBuffer);
		int w = _hwScreen->w;
		int h = _hwScreen->h;
		int srcPitch = _hwScreen->pitch;
		int dstPitch = _flipBuffer->pitch;
		uint8 *src = (uint8 *)_hwScreen->pixels;
		uint8 *dst = (uint8 *)_flipBuffer->pixels;
		for (int y = 0; y < h; y++) {
			uint32 *srcRow = (uint32 *)(src + y * srcPitch);
			uint32 *dstRow = (uint32 *)(dst + (h - 1 - y) * dstPitch);
			for (int x = 0; x < w; x++) {
				dstRow[w - 1 - x] = srcRow[x];
			}
		}
		if (SDL_MUSTLOCK(_flipBuffer)) SDL_UnlockSurface(_flipBuffer);
		if (SDL_MUSTLOCK(_hwScreen)) SDL_UnlockSurface(_hwScreen);
		SDL_BlitSurface(_flipBuffer, nullptr, _realHwScreen, nullptr);
	} else {
		SDL_BlitSurface(_hwScreen, nullptr, _realHwScreen, nullptr);
	}
	SDL_Rect fullScreen = {0, 0, (Uint16)_realHwScreen->w, (Uint16)_realHwScreen->h};
	SDL_UpdateRects(_realHwScreen, 1, &fullScreen);
}'''

if OLD_UPDATE not in src:
    print(f'ERROR: cannot find updateScreen in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_UPDATE, NEW_UPDATE, 1)
print('Patch 3: Added 180° rotation via flip buffer in updateScreen')

with open(PATH, 'w') as f:
    f.write(src)
print(f'All patches applied to {PATH}')
