#!/usr/bin/env python3
"""Patch MiyooMiniGraphicsManager to rotate display 180 degrees.

The Miyoo Mini's framebuffer is upside down relative to the physical screen
on SpruceOS. SDL1.2's fbcon rotation (SDL_VIDEO_FBCON_ROTATION=UD) crashes
on 32bpp (shadow buffer only supports 16bpp). ScummVM's rotation_mode=180
only works in the SDL2 renderer path.

This patch flips _hwScreen in place before blitting to _realHwScreen,
then does a full-screen update to avoid dirty rect flickering.
"""
import sys

PATH = 'backends/graphics/miyoo/miyoomini-graphics.cpp'
with open(PATH) as f:
    src = f.read()

OLD = '''void MiyooMiniGraphicsManager::updateScreen(SDL_Rect *dirtyRectList, int actualDirtyRects) {
	SDL_BlitSurface(_hwScreen, nullptr, _realHwScreen, nullptr);
	SDL_UpdateRects(_realHwScreen, actualDirtyRects, _dirtyRectList);
}'''

NEW = '''void MiyooMiniGraphicsManager::updateScreen(SDL_Rect *dirtyRectList, int actualDirtyRects) {
	// Rotate _hwScreen 180° in place before blitting
	if (SDL_MUSTLOCK(_hwScreen)) SDL_LockSurface(_hwScreen);
	int w = _hwScreen->w;
	int h = _hwScreen->h;
	int pitch = _hwScreen->pitch;
	uint8 *pixels = (uint8 *)_hwScreen->pixels;
	for (int y = 0; y < h / 2; y++) {
		uint32 *top = (uint32 *)(pixels + y * pitch);
		uint32 *bot = (uint32 *)(pixels + (h - 1 - y) * pitch);
		for (int x = 0; x < w; x++) {
			uint32 tmp = top[x];
			top[x] = bot[w - 1 - x];
			bot[w - 1 - x] = tmp;
		}
	}
	if (h % 2 == 1) {
		uint32 *mid = (uint32 *)(pixels + (h / 2) * pitch);
		for (int x = 0; x < w / 2; x++) {
			uint32 tmp = mid[x];
			mid[x] = mid[w - 1 - x];
			mid[w - 1 - x] = tmp;
		}
	}
	if (SDL_MUSTLOCK(_hwScreen)) SDL_UnlockSurface(_hwScreen);

	SDL_BlitSurface(_hwScreen, nullptr, _realHwScreen, nullptr);
	SDL_Rect fullScreen = {0, 0, (Uint16)w, (Uint16)h};
	SDL_UpdateRects(_realHwScreen, 1, &fullScreen);
}'''

if OLD not in src:
    print(f'ERROR: cannot find updateScreen in {PATH}', file=sys.stderr)
    sys.exit(1)

src = src.replace(OLD, NEW, 1)
with open(PATH, 'w') as f:
    f.write(src)
print(f'Patched {PATH}: 180° rotation on _hwScreen with full-screen update')
