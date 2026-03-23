#!/usr/bin/env python3
"""Retry SDL_CreateRenderer on failure (e.g. EGL not ready after UI exit).

On devices like the Miyoo A30 with Mali GPU, the first SDL_CreateRenderer
call can fail if the previous process (UI) hasn't fully released the EGL
context. This patch adds a retry loop with short delays.
"""
import sys

PATH = 'backends/graphics/surfacesdl/surfacesdl-graphics.cpp'
with open(PATH) as f:
    src = f.read()

# Find the renderer creation block and wrap it with retries.
# The existing code already retries once without VSYNC. We wrap the
# entire block in a retry loop that handles transient EGL failures.

OLD = '''	_renderer = SDL_CreateRenderer(_window->getSDLWindow(), -1, rendererFlags);
#endif
	if (!_renderer) {
		if (_videoMode.vsync) {
			// VSYNC might not be available, so retry without VSYNC
			warning("SDL_SetVideoMode: SDL_CreateRenderer() failed with VSYNC option, retrying without it...");
			_videoMode.vsync = false;
#if SDL_VERSION_ATLEAST(3, 0, 0)
			props = SDL_CreateProperties();
			SDL_SetPointerProperty(props, SDL_PROP_RENDERER_CREATE_WINDOW_POINTER, _window->getSDLWindow());
			SDL_SetNumberProperty(props, SDL_PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, 0);
			_renderer = SDL_CreateRendererWithProperties(props);
			SDL_DestroyProperties(props);
#else
			rendererFlags &= ~SDL_RENDERER_PRESENTVSYNC;
			_renderer = SDL_CreateRenderer(_window->getSDLWindow(), -1, rendererFlags);
#endif
		}
		if (!_renderer) {
			deinitializeRenderer();
			return nullptr;
		}
	}'''

NEW = '''	_renderer = SDL_CreateRenderer(_window->getSDLWindow(), -1, rendererFlags);
#endif
	if (!_renderer) {
		if (_videoMode.vsync) {
			// VSYNC might not be available, so retry without VSYNC
			warning("SDL_SetVideoMode: SDL_CreateRenderer() failed with VSYNC option, retrying without it...");
			_videoMode.vsync = false;
#if SDL_VERSION_ATLEAST(3, 0, 0)
			props = SDL_CreateProperties();
			SDL_SetPointerProperty(props, SDL_PROP_RENDERER_CREATE_WINDOW_POINTER, _window->getSDLWindow());
			SDL_SetNumberProperty(props, SDL_PROP_RENDERER_CREATE_PRESENT_VSYNC_NUMBER, 0);
			_renderer = SDL_CreateRendererWithProperties(props);
			SDL_DestroyProperties(props);
#else
			rendererFlags &= ~SDL_RENDERER_PRESENTVSYNC;
			_renderer = SDL_CreateRenderer(_window->getSDLWindow(), -1, rendererFlags);
#endif
		}
		// Retry with delay — GPU/EGL may not be ready yet (e.g. previous process still releasing)
		for (int _retry = 0; !_renderer && _retry < 3; _retry++) {
			warning("SDL_SetVideoMode: SDL_CreateRenderer() failed (attempt %d/3), retrying in 500ms...", _retry + 1);
			SDL_Delay(500);
			_renderer = SDL_CreateRenderer(_window->getSDLWindow(), -1, rendererFlags);
		}
		if (!_renderer) {
			deinitializeRenderer();
			return nullptr;
		}
	}'''

if OLD not in src:
    print(f'ERROR: cannot find renderer creation block in {PATH}', file=sys.stderr)
    sys.exit(1)

src = src.replace(OLD, NEW, 1)
with open(PATH, 'w') as f:
    f.write(src)
print(f'Patched {PATH}: added SDL_CreateRenderer retry loop (3 attempts, 500ms delay)')
