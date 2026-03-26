#!/usr/bin/env python3
"""Add SIGUSR1 handler for external save-and-quit.

On SpruceOS handhelds, the GameSwitcher needs to save the game before
killing ScummVM. This patch registers a SIGUSR1 handler that sets a flag,
which the event loop checks on each poll. When set, it triggers an
autosave and then quits cleanly.

Usage from shell: kill -USR1 $(pidof scummvm)
"""
import sys

# --- Patch 1: backends/platform/sdl/sdl.cpp ---
# Add signal handler registration after initSDL()

PATH1 = 'backends/platform/sdl/sdl.cpp'
with open(PATH1) as f:
    src1 = f.read()

# Add #include <signal.h> and the global flag after the FORBIDDEN_SYMBOL defines
OLD1 = '''#define FORBIDDEN_SYMBOL_ALLOW_ALL
#define SDL_FUNCTION_POINTER_IS_VOID_POINTER

#include "backends/platform/sdl/sdl.h"'''

NEW1 = '''#define FORBIDDEN_SYMBOL_ALLOW_ALL
#define SDL_FUNCTION_POINTER_IS_VOID_POINTER

#include <signal.h>

volatile sig_atomic_t g_saveAndQuit = 0;

static void saveAndQuitHandler(int) {
\tg_saveAndQuit = 1;
}

#include "backends/platform/sdl/sdl.h"'''

if OLD1 not in src1:
    print(f'ERROR: cannot find include block in {PATH1}', file=sys.stderr)
    sys.exit(1)

src1 = src1.replace(OLD1, NEW1, 1)

# Register the signal handler after initSDL()
OLD1B = '''\t// Initialize SDL
\tinitSDL();

#if !SDL_VERSION_ATLEAST(2, 0, 0)'''

NEW1B = '''\t// Initialize SDL
\tinitSDL();

\t// Register SIGUSR1 handler for external save-and-quit (SpruceOS GameSwitcher)
\tstruct sigaction sa;
\tsa.sa_handler = saveAndQuitHandler;
\tsa.sa_flags = SA_RESTART;
\tsigemptyset(&sa.sa_mask);
\tsigaction(SIGUSR1, &sa, NULL);

#if !SDL_VERSION_ATLEAST(2, 0, 0)'''

if OLD1B not in src1:
    print(f'ERROR: cannot find initSDL block in {PATH1}', file=sys.stderr)
    sys.exit(1)

src1 = src1.replace(OLD1B, NEW1B, 1)

with open(PATH1, 'w') as f:
    f.write(src1)
print(f'Patched {PATH1}: added SIGUSR1 signal handler')

# --- Patch 2: backends/events/default/default-events.cpp ---
# Check the flag in pollEvent() and trigger save-and-quit

PATH2 = 'backends/events/default/default-events.cpp'
with open(PATH2) as f:
    src2 = f.read()

# Add the extern declaration after the first include
OLD2 = '''#include "common/scummsys.h"

#if !defined(DISABLE_DEFAULT_EVENTMANAGER)'''

NEW2 = '''#include "common/scummsys.h"

#include <signal.h>
extern volatile sig_atomic_t g_saveAndQuit;

#if !defined(DISABLE_DEFAULT_EVENTMANAGER)'''

if OLD2 not in src2:
    print(f'ERROR: cannot find include block in {PATH2}', file=sys.stderr)
    sys.exit(1)

src2 = src2.replace(OLD2, NEW2, 1)

# Add the save-and-quit check before handleAutoSave
OLD2B = '''\tif (g_engine)
\t\t// Handle autosaves if enabled
\t\tg_engine->handleAutoSave();'''

NEW2B = '''\tif (g_engine && g_saveAndQuit) {
\t\tg_saveAndQuit = 0;
\t\tg_engine->saveAutosaveIfEnabled();
\t\tevent.type = Common::EVENT_QUIT;
\t\t_shouldQuit = true;
\t\treturn true;
\t}

\tif (g_engine)
\t\t// Handle autosaves if enabled
\t\tg_engine->handleAutoSave();'''

if OLD2B not in src2:
    print(f'ERROR: cannot find handleAutoSave block in {PATH2}', file=sys.stderr)
    sys.exit(1)

src2 = src2.replace(OLD2B, NEW2B, 1)

with open(PATH2, 'w') as f:
    f.write(src2)
print(f'Patched {PATH2}: added save-and-quit check in pollEvent()')
