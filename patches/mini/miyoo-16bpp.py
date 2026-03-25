#!/usr/bin/env python3
"""Change MiyooMini graphics backend to use 16bpp instead of 32bpp.

This allows SDL1.2's built-in fbcon rotation (SDL_VIDEO_FBCON_ROTATION=UD)
to work, since the shadow buffer blit only supports 16-bit color.
Most ScummVM games are 8-bit palette or 16-bit — no visible difference.
"""
import sys

PATH = 'backends/graphics/miyoo/miyoomini-graphics.cpp'
with open(PATH) as f:
    src = f.read()

OLD = '	_realHwScreen = SDL_SetVideoMode(_videoMode.hardwareWidth, _videoMode.hardwareHeight, 32,'
NEW = '	_realHwScreen = SDL_SetVideoMode(_videoMode.hardwareWidth, _videoMode.hardwareHeight, 16,'

if OLD not in src:
    print(f'ERROR: cannot find SDL_SetVideoMode 32bpp in {PATH}', file=sys.stderr)
    sys.exit(1)

src = src.replace(OLD, NEW, 1)
with open(PATH, 'w') as f:
    f.write(src)
print(f'Patched {PATH}: changed SDL_SetVideoMode from 32bpp to 16bpp')
