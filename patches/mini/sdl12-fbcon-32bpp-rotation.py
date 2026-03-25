#!/usr/bin/env python3
"""Patch SDL 1.2's fbcon video driver to support 32bpp shadow buffer rotation.

Stock SDL 1.2.15's fbcon rotation (SDL_VIDEO_FBCON_ROTATION) only has blit
functions for 16bpp. This patch adds 32bpp versions so rotation works with
32-bit color depth (used by ScummVM's miyoo backend).
"""
import sys

PATH = 'src/video/fbcon/SDL_fbvideo.c'
with open(PATH) as f:
    src = f.read()

# 1. Add FB_blit32 declarations after FB_blit16 declarations
OLD_DECL = '''static FB_bitBlit FB_blit16;
static FB_bitBlit FB_blit16blocked;'''

NEW_DECL = '''static FB_bitBlit FB_blit16;
static FB_bitBlit FB_blit16blocked;
static FB_bitBlit FB_blit32;
static FB_bitBlit FB_blit32blocked;'''

if OLD_DECL not in src:
    print(f'ERROR: cannot find blit16 declarations in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_DECL, NEW_DECL, 1)
print('Patch 1: Added FB_blit32 declarations')

# 2. Add 32bpp to blitFunc assignment
OLD_ASSIGN = '''	if (shadow_fb) {
		if (vinfo.bits_per_pixel == 16) {
			blitFunc = (rotate == FBCON_ROTATE_NONE ||
					rotate == FBCON_ROTATE_UD) ?
				FB_blit16 : FB_blit16blocked;
		} else {'''

NEW_ASSIGN = '''	if (shadow_fb) {
		if (vinfo.bits_per_pixel == 16) {
			blitFunc = (rotate == FBCON_ROTATE_NONE ||
					rotate == FBCON_ROTATE_UD) ?
				FB_blit16 : FB_blit16blocked;
		} else if (vinfo.bits_per_pixel == 32) {
			blitFunc = (rotate == FBCON_ROTATE_NONE ||
					rotate == FBCON_ROTATE_UD) ?
				FB_blit32 : FB_blit32blocked;
		} else {'''

if OLD_ASSIGN not in src:
    print(f'ERROR: cannot find blitFunc assignment in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_ASSIGN, NEW_ASSIGN, 1)
print('Patch 2: Added 32bpp blitFunc assignment')

# 3. Add FB_blit32 functions after FB_blit16blocked
OLD_BLIT = '''static void FB_DirectUpdate(_THIS, int numrects, SDL_Rect *rects)'''

NEW_BLIT = '''static void FB_blit32(Uint8 *byte_src_pos, int src_right_delta, int src_down_delta,
		Uint8 *byte_dst_pos, int dst_linebytes, int width, int height)
{
	int w;
	Uint32 *src_pos = (Uint32 *)byte_src_pos;
	Uint32 *dst_pos = (Uint32 *)byte_dst_pos;

	while (height) {
		Uint32 *src = src_pos;
		Uint32 *dst = dst_pos;
		for (w = width; w != 0; w--) {
			*dst = *src;
			src += src_right_delta;
			dst++;
		}
		dst_pos = (Uint32 *)((Uint8 *)dst_pos + dst_linebytes);
		src_pos += src_down_delta;
		height--;
	}
}

static void FB_blit32blocked(Uint8 *byte_src_pos, int src_right_delta, int src_down_delta,
		Uint8 *byte_dst_pos, int dst_linebytes, int width, int height)
{
	int w;
	Uint32 *src_pos = (Uint32 *)byte_src_pos;
	Uint32 *dst_pos = (Uint32 *)byte_dst_pos;

	while (height > 0) {
		Uint32 *src = src_pos;
		Uint32 *dst = dst_pos;
		for (w = width; w > 0; w -= BLOCKSIZE_W) {
			FB_blit32((Uint8 *)src,
					src_right_delta,
					src_down_delta,
					(Uint8 *)dst,
					dst_linebytes,
					min(w, BLOCKSIZE_W),
					min(height, BLOCKSIZE_H));
			src += src_right_delta * BLOCKSIZE_W;
			dst += BLOCKSIZE_W;
		}
		dst_pos = (Uint32 *)((Uint8 *)dst_pos + dst_linebytes * BLOCKSIZE_H);
		src_pos += src_down_delta * BLOCKSIZE_H;
		height -= BLOCKSIZE_H;
	}
}

static void FB_DirectUpdate(_THIS, int numrects, SDL_Rect *rects)'''

if OLD_BLIT not in src:
    print(f'ERROR: cannot find FB_DirectUpdate in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_BLIT, NEW_BLIT, 1)
print('Patch 3: Added FB_blit32 and FB_blit32blocked functions')

# 4. Fix the 16bpp-only check in FB_DirectUpdate
OLD_CHECK = '''	if (cache_vinfo.bits_per_pixel != 16) {
		SDL_SetError("Shadow copy only implemented for 16 bpp");
		return;
	}'''

NEW_CHECK = '''	if (cache_vinfo.bits_per_pixel != 16 && cache_vinfo.bits_per_pixel != 32) {
		SDL_SetError("Shadow copy only implemented for 16/32 bpp");
		return;
	}'''

if OLD_CHECK not in src:
    print(f'ERROR: cannot find 16bpp check in {PATH}', file=sys.stderr)
    sys.exit(1)
src = src.replace(OLD_CHECK, NEW_CHECK, 1)
print('Patch 4: Updated bpp check to allow 32bpp')

with open(PATH, 'w') as f:
    f.write(src)
print(f'All patches applied to {PATH}')
