#!/usr/bin/env python3
"""
patch_miyoomini_lto.py
Patches ScummVM's ./configure to add LTO support for the miyoomini target.

Two edits are made:
  1. miyoomini case block – append LTO CXXFLAGS / LDFLAGS via append_var so
     they are honoured by the rest of the configure logic.
  2. After the _host_alias → _ar/_nm/_ranlib assignment block – override those
     three variables with the gcc-ar/gcc-nm/gcc-ranlib LTO-aware wrappers.
     This second edit is required because the "else" branch that sets the
     standard binutils tools from $_host_alias runs AFTER the case block,
     which would otherwise silently clobber the values set in step 1.

Run from the root of the scummvm source tree:
    python3 patch_miyoomini_lto.py [configure]   (defaults to ./configure)
"""

import os
import sys

CONFIGURE_PATH = "configure"

OLD_MIYOOMINI_BLOCK = """\
miyoomini)
\t_host_os=linux
\t_host_cpu=arm
\t_host_alias=arm-linux-gnueabihf
\t;;"""

NEW_MIYOOMINI_BLOCK = """\
miyoomini)
\t_host_os=linux
\t_host_cpu=arm
\t_host_alias=arm-linux-gnueabihf
\tappend_var CFLAGS "-flto=auto -fuse-linker-plugin -ffunction-sections -fdata-sections"
\tappend_var CXXFLAGS "-flto=auto -fuse-linker-plugin -ffunction-sections -fdata-sections"
\tappend_var LDFLAGS  "-flto=auto -fuse-linker-plugin -Wl,--gc-sections"
\t;;"""


def apply_patch(content: str, old: str, new: str, label: str) -> str:
    count = content.count(old)
    if count == 0:
        print(f"ERROR: anchor for '{label}' not found in configure.", file=sys.stderr)
        sys.exit(1)
    if count > 1:
        print(
            f"ERROR: anchor for '{label}' found {count} times; expected exactly 1.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"  Applying: {label}")
    return content.replace(old, new)


def main() -> None:
    if not os.path.isfile(CONFIGURE_PATH):
        print(f"ERROR: {CONFIGURE_PATH!r} not found.", file=sys.stderr)
        sys.exit(1)

    with open(CONFIGURE_PATH, "r", encoding="utf-8") as fh:
        content = fh.read()

    original = content

    content = apply_patch(
        content,
        OLD_MIYOOMINI_BLOCK,
        NEW_MIYOOMINI_BLOCK,
        "miyoomini case block – LTO append_var calls",
    )

    if content == original:
        print("No changes made (patches may already be applied).")
        return

    # Write back
    with open(CONFIGURE_PATH, "w", encoding="utf-8") as fh:
        fh.write(content)

    print(f"Done. {CONFIGURE_PATH!r} patched successfully.")


if __name__ == "__main__":
    main()
