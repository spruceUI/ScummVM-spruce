#!/usr/bin/env python3
"""Patch ScummVM's surfacesdl-graphics.cpp for direct /dev/fb0 rendering on Miyoo Mini.

The device SDL2's MMIYOO renderer uses MI_GFX_BitBlit which fails on SpruceOS.
This patch bypasses SDL2 rendering entirely when DIRECT_FB env is set, instead
writing pixels directly to /dev/fb0 via mmap with double buffering.
"""
import sys

PATH = 'backends/graphics/surfacesdl/surfacesdl-graphics.cpp'
with open(PATH) as f:
    src = f.read()

# ── Patch 1: Add includes and static fb state after the include block ──
# Insert fb includes BEFORE ScummVM headers to avoid forbidden symbol conflicts
BEFORE_SCUMMVM = '#include "common/scummsys.h"'
FB_HEADER_TOP = '''// Direct framebuffer rendering for Miyoo Mini (bypasses broken MI_GFX)
// Must be included before ScummVM headers which set up forbidden symbol traps
#if defined(__linux__)
#include <linux/fb.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#endif

#include "common/scummsys.h"'''

AFTER_INCLUDES = '#include "common/text-to-speech.h"'
FB_HEADER = '''#include "common/text-to-speech.h"

#if defined(__linux__)
static int _directFbFd = -1;
static void *_directFbMmap = (void*)-1; // MAP_FAILED
static int _directFbW = 0;
static int _directFbH = 0;
static int _directFbStride = 0;
static int _directFbSize = 0;
static int _directFbYOffset = 0;
static int _directFbRotation = 0;
#endif'''

if BEFORE_SCUMMVM not in src:
    print(f'ERROR: cannot find scummsys.h include in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(BEFORE_SCUMMVM, FB_HEADER_TOP, 1)
print('Patch 1a: Added fb system includes before ScummVM headers')

if AFTER_INCLUDES not in src:
    print(f'ERROR: cannot find include anchor in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(AFTER_INCLUDES, FB_HEADER, 1)
print('Patch 1b: Added fb state variables')

# ── Patch 2: In SDL_SetVideoMode, add direct fb init path (early return) ──
# Insert before the format/texture creation, right after handleResize
RESIZE_ANCHOR = '''	getWindowSizeFromSdl(&_windowWidth, &_windowHeight);
	handleResize(_windowWidth, _windowHeight);

#if !SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, _videoMode.filtering ? "linear" : "nearest");
#endif

#if SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_PixelFormat format = SDL_PIXELFORMAT_RGB565;
#else
	Uint32 format = SDL_PIXELFORMAT_RGB565;
#endif'''

FB_INIT = '''	getWindowSizeFromSdl(&_windowWidth, &_windowHeight);
	handleResize(_windowWidth, _windowHeight);

#if defined(__linux__)
	// Direct framebuffer mode: bypass SDL renderer, write to /dev/fb0
	if (SDL_getenv("DIRECT_FB")) {
		Uint32 fbfmt = SDL_PIXELFORMAT_RGB888; // 32bpp XRGB, compatible with ARGB8888 fb
		SDL_Surface *screen = SDL_CreateRGBSurfaceWithFormat(0, width, height,
			SDL_BITSPERPIXEL(fbfmt), fbfmt);
		if (!screen) return nullptr;
		if (_directFbFd < 0) {
			struct fb_var_screeninfo vinfo;
			struct fb_fix_screeninfo finfo;
			_directFbFd = open("/dev/fb0", O_RDWR);
			if (_directFbFd >= 0) {
				ioctl(_directFbFd, FBIOGET_VSCREENINFO, &vinfo);
				ioctl(_directFbFd, FBIOGET_FSCREENINFO, &finfo);
				_directFbW = vinfo.xres;
				_directFbH = vinfo.yres;
				_directFbStride = finfo.line_length;
				vinfo.yres_virtual = vinfo.yres * 2;
				vinfo.yoffset = 0;
				ioctl(_directFbFd, FBIOPUT_VSCREENINFO, &vinfo);
				ioctl(_directFbFd, FBIOGET_FSCREENINFO, &finfo);
				_directFbSize = finfo.smem_len;
				_directFbYOffset = 0;
				_directFbMmap = mmap(0, _directFbSize, PROT_READ | PROT_WRITE, MAP_SHARED, _directFbFd, 0);
				if (_directFbMmap == MAP_FAILED) {
					close(_directFbFd);
					_directFbFd = -1;
				} else {
					memset(_directFbMmap, 0, _directFbSize);
				}
			}
			const char *rotEnv = SDL_getenv("DISPLAY_ROTATION");
			if (rotEnv) _directFbRotation = SDL_atoi(rotEnv);
		}
		return screen;
	}
#endif

#if !SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, _videoMode.filtering ? "linear" : "nearest");
#endif

#if SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_PixelFormat format = SDL_PIXELFORMAT_RGB565;
#else
	Uint32 format = SDL_PIXELFORMAT_RGB565;
#endif'''

if RESIZE_ANCHOR not in src:
    print(f'ERROR: cannot find resize anchor in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(RESIZE_ANCHOR, FB_INIT, 1)
print('Patch 2: Added direct fb init in SDL_SetVideoMode')

# ── Patch 3: In SDL_UpdateRects, add direct fb write path ──
OLD_UPDATE = '''void SurfaceSdlGraphicsManager::SDL_UpdateRects(SDL_Surface *screen, int numrects, SDL_Rect *rects) {
	SDL_UpdateTexture(_screenTexture, nullptr, screen->pixels, screen->pitch);'''

NEW_UPDATE = '''void SurfaceSdlGraphicsManager::SDL_UpdateRects(SDL_Surface *screen, int numrects, SDL_Rect *rects) {
#if defined(__linux__)
	if (SDL_getenv("DIRECT_FB") && _directFbMmap != MAP_FAILED) {
		int srcW = screen->w;
		int srcH = screen->h;
		int srcPitch = screen->pitch;
		uint8_t *srcPx = (uint8_t *)screen->pixels;
		int dstX = (_directFbW > srcW) ? (_directFbW - srcW) / 2 : 0;
		int dstY = (_directFbH > srcH) ? (_directFbH - srcH) / 2 : 0;
		int copyW = (srcW < _directFbW) ? srcW : _directFbW;
		int copyH = (srcH < _directFbH) ? srcH : _directFbH;
		uint8_t *dstBase = (uint8_t *)_directFbMmap + (_directFbYOffset * _directFbStride);
		// Clear top/bottom borders
		for (int y = 0; y < dstY; y++)
			memset(dstBase + y * _directFbStride, 0, _directFbStride);
		for (int y = dstY + copyH; y < _directFbH; y++)
			memset(dstBase + y * _directFbStride, 0, _directFbStride);
		// Copy rows with side border clearing (with optional 180° rotation)
		for (int y = 0; y < copyH; y++) {
			int outY = (_directFbRotation == 180) ? (dstY + copyH - 1 - y) : (dstY + y);
			uint8_t *row = dstBase + outY * _directFbStride;
			if (dstX > 0) memset(row, 0, dstX * 4);
			if (_directFbRotation == 180) {
				// Reverse pixels in row for 180° rotation
				uint32_t *dst32 = (uint32_t *)(row + dstX * 4);
				uint32_t *src32 = (uint32_t *)(srcPx + y * srcPitch);
				for (int x = 0; x < copyW; x++)
					dst32[x] = src32[copyW - 1 - x];
			} else {
				memcpy(row + dstX * 4, srcPx + y * srcPitch, copyW * 4);
			}
			int right = (dstX + copyW) * 4;
			if (right < _directFbStride) memset(row + right, 0, _directFbStride - right);
		}
		struct fb_var_screeninfo vinfo;
		ioctl(_directFbFd, FBIOGET_VSCREENINFO, &vinfo);
		vinfo.yoffset = _directFbYOffset;
		ioctl(_directFbFd, FBIOPAN_DISPLAY, &vinfo);
		_directFbYOffset = (_directFbYOffset == 0) ? _directFbH : 0;
		return;
	}
#endif
	SDL_UpdateTexture(_screenTexture, nullptr, screen->pixels, screen->pitch);'''

if OLD_UPDATE not in src:
    print(f'ERROR: cannot find SDL_UpdateRects in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_UPDATE, NEW_UPDATE, 1)
print('Patch 3: Added direct fb write in SDL_UpdateRects')

# ── Patch 4: Skip SDL_RenderPresent when using direct fb ──
OLD_PRESENT = '''	if (doPresent) {
		SDL_RenderPresent(_renderer);
	}'''

NEW_PRESENT = '''	if (doPresent && !SDL_getenv("DIRECT_FB")) {
		SDL_RenderPresent(_renderer);
	}'''

if OLD_PRESENT not in src:
    print(f'ERROR: cannot find SDL_RenderPresent block in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_PRESENT, NEW_PRESENT, 1)
print('Patch 4: Skip SDL_RenderPresent when DIRECT_FB')

# ── Patch 5: Cleanup fb in deinitializeRenderer ──
OLD_DEINIT = '''void SurfaceSdlGraphicsManager::deinitializeRenderer() {'''

NEW_DEINIT = '''void SurfaceSdlGraphicsManager::deinitializeRenderer() {
#if defined(__linux__)
	if (_directFbMmap != MAP_FAILED) {
		munmap(_directFbMmap, _directFbSize);
		_directFbMmap = MAP_FAILED;
	}
	if (_directFbFd >= 0) {
		close(_directFbFd);
		_directFbFd = -1;
	}
#endif'''

if OLD_DEINIT not in src:
    print(f'ERROR: cannot find deinitializeRenderer in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_DEINIT, NEW_DEINIT, 1)
print('Patch 5: Added fb cleanup in deinitializeRenderer')

with open(PATH, 'w') as f:
    f.write(src)
print(f'All patches applied to {PATH}')
