# Hazard checklist (why each parity gate check exists)

Companion to `docs/cross-compile.md` — the gate checks these mechanically;
this doc explains them so fixes are obvious when one fires.

## Include casing vs the case-sensitive host

Windows builds are case-insensitive; the Linux cross host is not, and
`file(GLOB)` **silently drops** patterns whose casing doesn't match (this bit
xrGameSpy's `Gamespy/` glob). The gate resolves every quoted `#include` in
changed files and fails when the on-disk casing differs. Fix the include
(or rename the file to the repo's convention). New source files must also
match their `file(GLOB)` pattern's casing exactly.

## `__declspec(allocate(...))`

MSVC silently ignores it; clang-cl honors it — the engine died at xrCore
init when `.Hook` turned read-only and `xrMemory::xrMemory()` faulted before
any logging (`src/xrCore/memory/xrMemory.cpp` history). `#pragma init_seg`
plus writable data only.

## `#pragma section(..., read)` sections

Genuinely read-only under clang-cl (lenient under MSVC). Never allocate
globals that get written into them.

## Hand-pinned `/MD` / `/MDd` in cmake files

`CMAKE_MSVC_RUNTIME_LIBRARY` (CMP0091) owns CRT selectors. A hand-pinned
selector in the same command as the mapped one = two CRT heaps = corruption.
Never re-introduce, even "just for one target".

## `.rc` files must be valid UTF-8

llvm-rc has no codepage auto-detection and can't take `/c 65001` through
CMake's shared RC flags. CP1251 bytes (e.g. `©`) kill the configure. Convert
to UTF-8 **with BOM** and ASCII-safe strings.

## Build half (winCross shell required)

- `ixray-build-win <preset>` — the real cross compile; any MSVC-only
  construct that clang-cl rejects (or miscompiles) shows up here. Note the
  MSVC-semantics flags in `cmake/msvc.cmake` (UB adoption, fp semantics) —
  new engine code that adds *new* MSVC-tolerated UB may need a flag or a
  code fix; prefer the code fix.
- `ixray-clangd-db` — regenerates the per-file compile DB; a CMake change
  that breaks clangd (unity globbing, new dirs) fails here or silently
  degrades IntelliSense. After any CMakeLists change, always regenerate.

## What the gate does NOT cover

- MSVC/CI (RelWithDebInfo) breakage — the fork's GitHub CI is the backstop.
- Runtime behavior — crashes and gameplay need the Debug/PDB builds and an
  actual launch (see `docs/cross-compile.md` remaining-gaps section).
- ABI drift with prebuilt MSVC NuGet libs — linker-checked for CRT level,
  semantically unchecked; Debug PDBs + winedbg when something surfaces.
