# Cross-Compilation Status

Goal: **Windows x64 binaries built from Linux as a viable target, without compromising the MSVC/Windows build.**

Toolchain: clang-cl (MSVC ABI) + lld-link + llvm-rc, MSVC CRT/Windows SDK provisioned by `xwin`,
driven by CMake/Ninja. Everything lives in `flake.nix` (`winCross` devShell) and
`cmake/msvc-cross.cmake`. Native Linux shell (`nix develop`) remains for tools + engine core libs.

## Current state

- **Full engine cross-builds**: 48-file `build-win/bin/Release/` parity with the upstream
  published game build (engine + MP layer + all runtime DLLs).
- **Engine boots under Wine**: `xrEngine.exe -dedicated` initializes xrCore, resolves
  `fsgame.ltx` when started from `bin/`, loads `system.ltx` from gamedata.
- **clangd works**: raw `clangd` (not the nix wrapper) + per-file compile DB from
  `build-lsp/` (unity-free) via the root `compile_commands.json` symlink; root `.clangd`
  strips MSVC PCH flags and suppresses known MSVC-drift warnings.
- Windows/MSVC build is untouched: all changes are either guarded by compiler checks or
  bug fixes that are no-ops for MSVC.

## What was done (chronological)

1. **Toolchain**: `winCross` shell — clang-cl wrapped with explicit `-resource-dir`
   (nixpkgs splits clang's builtin headers into the `lib` output; without this, MSVC's
   intrinsic headers shadow clang's and every `_mm_*` fails to inline). Same for `clangd`
   (the wrapped clangd injects host GCC headers into MSVC-targeted parses → false-error
   storms). LLVM ≥ 19 required by current MSVC STL (STL1000). `link.exe` shim → `lld-link`.
2. **CRT/SDK**: `xwin splat --include-debug-libs` into `~/.cache/ixray/msvc-sdk`;
   `INCLUDE`/`LIB` env vars (cl/lld-link style); `link.exe` shim for manual clang-cl runs.
3. **CMake toolchain** (`cmake/msvc-cross.cmake`): `CMAKE_SYSTEM_NAME=Windows`, clang-cl,
   `lld-link`, `llvm-rc` (+`llvm-mt`, `llvm-lib`), and `CMAKE_VS_PLATFORM_NAME=x64` injected
   (VS-generator variable the NuGet/SDK paths depend on; empty under Ninja).
4. **msvc.cmake compat**: `/GL`+`/LTCG` gated to real MSVC (clang-cl can't), `/ZI`→`/Zi`,
   `/EHsc` kept for all configs (engine code uses try/catch in Release — `fast_dynamic_cast`),
   `-msse4.2` for crc32 intrinsics.
5. **PCH**: MSVC `/Yc`+`/Yu` pipeline disabled under clang-cl (`target_validate_pch`); sources
   include their own `stdafx.h`.
6. **Case-sensitive-filesystem sweep**: `stdafx.*` normalized to lowercase repo-wide (git mv),
   dozens of include-path fixes, `xrGameSpy/CMakeLists.txt` `Gamespy/`→`gamespy/` globs
   (**`file(GLOB)` silently drops non-matching patterns**), `Sector.h`, `CustomHud`, etc.
7. **Platform-aware deps**: `xrEngine` links FreeType/Theora/Ogg via system (nixpkgs) on
   non-WIN32, NuGet `.lib` paths guarded by `WIN32`; `xrRender_R4`/`xrGame`/`xrPlay` WIN32-gated
   (same pattern as R1/R2) so native Linux `ALL` stops at buildable targets.
8. **Resources**: `llvm-rc` can't parse Windows-1251 `©` and can't take `/c 65001` through
   CMake's shared RC flags → `.rc` files converted to UTF-8 with BOM and ASCII-safe strings.
9. **CRT uniformity**: `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`; removed hand-pinned
   `/MD` (`cmake/msvc.cmake`) that mixed with CMake's CMP0091-mapped `-MDd`/`-MD` in single
   commands (two CRT heaps). Sanitizer in root `CMakeLists.txt` strips stray selectors.
10. **MP parity**: upstream packs the *Server* preset (`IXRAY_MP=ON`) for game builds —
    `ixray-configure-win` now passes it. Fixed on the way: `XrEngine`→`xrEngine` include
    casing, `xrServer/resource.rc` encoding, xrGameSpy glob casing.
11. **Runtime init crash (the big one)**: `src/xrCore/memory/xrMemory.cpp` — ForserX's
    `__declspec(allocate(".Hook"))` hack: MSVC silently ignores it (no `.Hook` in shipped
    DLL; `Memory` lands in writable `.data`), clang-cl honors it → read-only `.Hook`
    section → `xrMemory::xrMemory()` write fault → `DllMain` FALSE → instant death before
    any logging. Fixed by dropping the `allocate`, keeping `init_seg(lib)`.
12. **fsgame.ltx from bin/**: `LocatorAPI.cpp` fallback chain (CWD → parent → binary folder
    parent) was gated on a custom `-fsltx` being present; now probes the effective ltx name
    so starting from `bin/` resolves the game root and chdirs there.
13. **rs_fullscreen**: gated under `MASTER_GOLD` upstream (2024) but CI ships `RelWithDebInfo`
    which never defines it → fullscreen command missing from CI-built artifacts. Ungated.
    Note: upstream's published zips *are* Release-config builds with MASTER_GOLD (verified:
    `rs_fullscreen` string present in shipped DLL) — releases are packed manually
    (`util/pack-builds.bat` + local 7-Zip), not by the public CI.

## Remaining gaps / immediate focus

- **Init pipeline validation**: the static-init crash is fixed and verified under local Wine
  (engine log reaches `system.ltx`), but a full interactive launch (Proton, D3D) is still
  user-validated territory. If Proton reproduces an instant-death, use interactive
  `winedbg` + the Debug config PDBs (`build-win/bin/Debug/*.pdb`).
- **"File already exists." on game exit** (present in MSVC CI builds too): `xrDebug`
  `UnhandledFilter` fires during teardown logging leftover Win32 error 183 with an empty
  stack trace. Deploy `*.pdb` next to the exe to symbolize `BuildStackTrace` output.
- **Hidden cross-compile bug surface**: ABI boundary with prebuilt MSVC NuGet libs (built
  by older MSVC generations, e.g. `_MSC_VER=1900` in DirectXTex) — linker-checked
  (`FAILIFMISMATCH`) for CRT/iterator level but semantically unchecked. Debug PDBs +
  winedbg is the toolchain for anything that surfaces.
- **`/GL`+`/LTCG` loss**: whole-program optimization is MSVC-only; optional follow-up is
  LTO (`-flto` + lld-link supports it) for size/perf parity.
- **Native Linux playable engine**: still not buildable (unconditional `d3d9/d3d11.h`
  includes in `xrAbstractions`, no GL renderer). Separate long-term effort; cross build is
  the supported path.

## PDBs & crash symbolization

All cross configs now emit PDBs next to the binaries: `cmake/msvc.cmake` links `/DEBUG`
for Release (clang-cl builds only — upstream MSVC/CI binaries are untouched), and
`/Zi` was already applied per-object for every config.

- Grab them from `build-win/bin/Release/*.pdb` (must be copied together with the
  *same build's* binaries — the PDB GUID only matches the DLLs it was linked with).
- The runtime stack tracer (`src/xrCore/StackTrace/StackTrace.h`) prints each frame as
  `module at 0xABS (base 0xBASE, rva 0xRVA)`; if Wine's builtin dbghelp can't load the
  PDB under Proton (symbol line missing from the log), symbolize offline on Linux:
  `llvm-symbolizer --relative-address --obj=xrRender_R4.dll 0xRVA...` (verified working
  with the winCross LLVM 20 toolchain; alternative: `llvm-pdbutil dump -lines`).
  Note `bin/Release` PDBs match Release (MASTER_GOLD) builds — Debug/RelWithDebInfo
  PDBs must not be mixed in, those configs compile different code.
- `IXRAY_CONFIG=RelWithDebInfo ixray-build-win` builds a different config with the
  same helper (no `MASTER_GOLD`, so not a drop-in for Release crash debugging).

## MSVC-semantics flags for clang-cl

GSC-era code relies on UB that MSVC never exploits but clang -O2 does. Two crashes
surfaced this way before the fix (`Shader::equal` null-`this` guard erased, and a
null-reference `if (&ref)` check folded in HudSound), so `cmake/msvc.cmake` applies
these for all non-MSVC (clang-cl) builds:

- `-fno-strict-aliasing` — the engine puns types (e.g. `*(float*)&u32` in sound
  occlusion code); MSVC never uses TBAA.
- `-fwrapv` — MSVC wraps on signed overflow.
- `-fno-delete-null-pointer-checks` — stop clang erasing null guards via
  dereference inference (the direct cause of the `Shader::equal` crash).

These don't cover *all* MSVC-tolerated UB: member calls on a null `this` at the
call site remain UB regardless of flags — if a crash shows a member call on a
null receiver, fix it with a plain pointer check at the call site (see HudSound).

## Quick reference

| Thing | Where |
|---|---|
| Native Linux shell | `nix develop` — tools, `ixray-configure`/`ixray-build` |
| Cross shell | `nix develop .#winCross` (or `use flake .#winCross` in `.envrc`) |
| Helper scripts | `.devshell-helpers/` (PATH scripts, not aliases — direnv drops functions) |
| Build dirs | `build/` (native), `build-win/` (game), `build-lsp/` (clangd DB, unity-free) |
| Game output | `build-win/bin/Release/` — copy contents over the game's `bin/` |
| MSVC CRT/SDK cache | `~/.cache/ixray/msvc-sdk` (xwin), override with `XRAY_MSVC_SDK` |
| Personal hook | `./.dev.local.sh` (gitignored), template `.dev.local.sh.example` |
| clangd | root `compile_commands.json` symlink → `build-lsp/`; `.clangd` for suppressions |

## Cross-compile pitfalls learned (for future changes)

- `file(GLOB)` silently drops patterns whose casing doesn't match the case-sensitive host.
- `__declspec(allocate(...))` is honored by clang-cl but not reliably by MSVC — avoid.
- `#pragma section(..., read)` sections are genuinely read-only; never allocate written
  globals into them.
- CMake's `CMAKE_MSVC_RUNTIME_LIBRARY` (CMP0091) owns CRT selectors — never hand-pin `/MD`.
- `#pragma init_seg` + section hacks only work when the section is writable.
- NuGet restore, FetchContent (SDL3, yaml-cpp, nvtt, openal-soft), and xwin provisioning all
  need network at configure time.
- Never mix `/MD` and `/MDd` (or `-MDd`) in one command — two CRT heaps → corruption.
