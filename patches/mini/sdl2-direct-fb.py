#!/usr/bin/env python3
"""Patch SDL2 MMIYOO framebuffer to write directly to /dev/fb0 via mmap.

The MMIYOO video driver's UpdateWindowFramebuffer is a no-op — it never
copies pixels to the display. This patch makes it memcpy the surface pixels
directly to the mmap'd framebuffer, bypassing MI_GFX.
"""
import sys

# Patch SDL_framebuffer_mmiyoo.c
fb_path = 'sdl2/src/video/mmiyoo/SDL_framebuffer_mmiyoo.c'
with open(fb_path) as f:
    src = f.read()

# Add required includes
src = src.replace(
    '#include "SDL_framebuffer_mmiyoo.h"',
    '#include "SDL_framebuffer_mmiyoo.h"\n#include "SDL_video_mmiyoo.h"\n#include <string.h>'
)

# Replace the no-op UpdateWindowFramebuffer with direct framebuffer write
old = '''int MMIYOO_UpdateWindowFramebuffer(_THIS, SDL_Window *window, const SDL_Rect *rects, int numrects)
{
    static int frame_number;
    SDL_Surface *surface;

    surface = (SDL_Surface *) SDL_GetWindowData(window, MMIYOO_SURFACE);
    if(!surface) {
        return SDL_SetError("Couldn't find mmiyoo surface for window");
    }

    if(SDL_getenv("SDL_VIDEO_MMIYOO_SAVE_FRAMES")) {
        char file[128];
        SDL_snprintf(file, sizeof(file), "SDL_window%" SDL_PRIu32 "-%8.8d.bmp",
                     SDL_GetWindowID(window), ++frame_number);
        SDL_SaveBMP(surface, file);
    }
    return 0;
}'''

new = '''int MMIYOO_UpdateWindowFramebuffer(_THIS, SDL_Window *window, const SDL_Rect *rects, int numrects)
{
    SDL_Surface *surface;
    surface = (SDL_Surface *) SDL_GetWindowData(window, MMIYOO_SURFACE);
    if(!surface) {
        return SDL_SetError("Couldn't find mmiyoo surface for window");
    }
    if (gfx.fb.virAddr) {
        int h;
        int copy_w = (surface->w < FB_W) ? surface->w : FB_W;
        int copy_h = (surface->h < FB_H) ? surface->h : FB_H;
        int dst_pitch = FB_W * FB_BPP;
        uint8_t *src = (uint8_t *)surface->pixels;
        uint8_t *dst = (uint8_t *)gfx.fb.virAddr + (FB_W * gfx.vinfo.yoffset * FB_BPP);
        for (h = 0; h < copy_h; h++) {
            memcpy(dst + h * dst_pitch, src + h * surface->pitch, copy_w * FB_BPP);
        }
        GFX_Flip();
    }
    return 0;
}'''

if old not in src:
    print(f'ERROR: Could not find UpdateWindowFramebuffer in {fb_path}', file=sys.stderr)
    sys.exit(1)

src = src.replace(old, new)
with open(fb_path, 'w') as f:
    f.write(src)
print(f'Patched {fb_path}: direct framebuffer write in UpdateWindowFramebuffer')

# Patch SDL_video_mmiyoo.c — add standard mmap fallback
vid_path = 'sdl2/src/video/mmiyoo/SDL_video_mmiyoo.c'
with open(vid_path) as f:
    vid = f.read()

old_mmap = 'MI_SYS_Mmap(gfx.fb.phyAddr, gfx.finfo.smem_len, &gfx.fb.virAddr, TRUE);'
new_mmap = old_mmap + '''
    if (!gfx.fb.virAddr) {
        gfx.fb.virAddr = mmap(0, gfx.finfo.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, gfx.fb_dev, 0);
    }'''

if old_mmap not in vid:
    print(f'WARNING: Could not find MI_SYS_Mmap in {vid_path} (may already be patched)', file=sys.stderr)
else:
    vid = vid.replace(old_mmap, new_mmap)
    with open(vid_path, 'w') as f:
        f.write(vid)
    print(f'Patched {vid_path}: added mmap fallback for framebuffer')
