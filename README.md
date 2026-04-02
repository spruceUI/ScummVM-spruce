# ScummVM builds for spruceOS

CI-built ScummVM binaries for [spruceOS](https://github.com/spruceUI/spruceOS), bundled with needed shared libraries.

## Builds

Static builds have game engines linked into the binary itself (hence the much larger binary size), dynamic builds have game engines separated out as shared libraries known as *plugins*.

| Binary | Build Type | Devices | Rendering | Toolchain |
|--------|---------|-----------|-----------|------------|
| `scummvm.64` | Static | Universal ARM64 | SDL2 / OpenGL ES 2.0 | Ubuntu Focal GCC 9.4.0 |
| `scummvm.a30` | Static | Miyoo A30 | SDL2 / Software | Steward Fu GCC 13.2.0 (static glibcxx) |
| `scummvm.mini` | Dynamic | Miyoo Mini | SDL 1.2 / Software | GNU-A GCC 8.3.0 |
