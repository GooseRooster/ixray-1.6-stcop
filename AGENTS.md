# AGENTS.md — IX-Ray 1.6 STCOP (Old World fork)

## Project identity

This is a **fork of the IX-Ray 1.6 STCOP engine** (modernized X-Ray 1.6.02 for
S.T.A.L.K.E.R.: Call of Pripyat), focused on the **Old World mod**. The end goal is to
migrate the **Old World level pack and game mechanics** onto this engine.

- **Old World mod repo**: A private repo separate from this engine. — read its `AGENTS.md` first when
  doing anything mod-side. Key facts: `_GAME/` is the active gamedata tree; **R4 (DX11) is
  the only supported renderer**; DLTX/DXML/LuaJIT engine features are required; game
  configs are Windows-1251 encoded

## Build targets — read this first

- **Windows x64 is the only playable target.** Two supported build flows (see
  `docs/cross-compile.md` for full status/history):
  1. **Cross-compile from Linux** (primary here): `nix develop .#winCross`, then
     `ixray-configure-win && ixray-build-win`. Output: `build-win/bin/Release/` — copy
     contents over the game's `bin/`. Build config is `Release` (= `MASTER_GOLD` defined,
     matching upstream's published player builds).
  2. **MSVC on Windows/CI** (upstream's path): CI workflows build **RelWithDebInfo**;
     upstream packs releases manually with `util/pack-builds.bat` from the *Server* preset
     (`IXRAY_MP=ON`).

## Configuration semantics

- `MASTER_GOLD` is defined only for `Release` (and `Shipping` with `DEVIXRAY_ENABLE_SHIPPING`)
  CMake configs. **CI builds RelWithDebInfo, which never defines it** — so anything gated
  under `MASTER_GOLD` is absent from CI artifacts. Upstream's published zips are Release
  builds (MASTER_GOLD defined). Don't gate player-facing features under it.
- `DEBUG`/`DEBUG_DRAW` are config-gated (Debug / RelWithDebInfo).
- CRT is managed centrally: `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL` + sanitizer in
  root `CMakeLists.txt`. Never hand-pin `/MD`/`/MDd` — mixing CRT selectors in one command
  = two heaps = heap corruption.

## Repository structure

```
CMakeLists.txt        root build (options: IXRAY_MP, IXRAY_USE_R1/R2, IXRAY_COMPRESSOR_ONLY, ...)
CMakePresets.json     VS/Ninja presets; CI uses RelWithDebInfo; Linux presets disable R1/R2
cmake/                msvc.cmake (MSVC/clang-cl flags), clang.cmake (native Linux),
                      msvc-cross.cmake (Linux→Windows toolchain), nuget.cmake per-OS,
                      modules/Find* (SDL3, LuaBind, Ogg, Opus, SpeexDSP, OpenalSoft)
flake.nix             devShells: `default` (native Linux), `winCross` (Windows cross);
                      helper PATH scripts in `.devshell-helpers/`; .dev.local.sh personal hook
src/
  xrCore/             core library: FS/LocatorAPI, memory (xrMemory), logging, threading,
                      Platform/{Windows,Linux,BSD} abstraction
  xrEngine/          engine core → builds `xrAbstractions.dll` (shared engine lib)
  xrPlay/            the game executable target → `xrEngine.exe`
  xrGame/            singleplayer game logic → `xrGame.dll` (unity build; MP when IXRAY_MP)
  xrServerEntities/  server entities, object factory/loader/saver
  xrScripts/         Lua script exports (luabind)
  xrSound, xrNetServer, xrPhysics (ODE), xrParticles, xrUI, xrServer, xrGameSpy (MP)
  Layers/            renderers: xrRender (shared), xrRenderDX9 (R1/R2), xrRenderDX10 (R4
                     backend), xrRenderPC_R1/R2/R4, xrRenderDS_R0 (dedicated server, MP)
  utils/             xrCompress, xrDXT, xrLC(Light), xrAI, ETools... (IXRAY_UTILS gate)
  Editors/           IXR SDK editors (IXRAY_EDITORS gate)
  3rd-party/         vendored: ODE, opcode, imgui, crypto, dxerr, MagicSoftware, NvMender2003
gamedata/             in-repo gamedata subset (anims, configs, scripts, shaders...) — NOTE:
                      active Old World gamedata lives in the oldworld repo `_GAME/`
sdk/                  bundled headers (incl. nvapi, lua) + libraries (meshoptimizer)
util/                 build/pack .bat scripts (local dev machine tooling, 7-Zip based)
docs/                 engine docs site; `docs/cross-compile.md` = cross-build status
```

## Environment / workflow

- Direnv (`use flake`) activates the native shell; `use flake .#winCross` for cross work.
- Helpers are **PATH scripts** (`.devshell-helpers/`), not aliases — direnv/nix-direnv only
  carries exported env vars, aliases/functions die with the hook's bash.
- Helper scripts: `ixray-configure-win`, `ixray-build-win` (`IXRAY_MP=ON`, matches upstream
  game builds), `ixray-clangd-db`, `ixray-configure`, `ixray-build`.
- First configure needs network (NuGet restore + FetchContent: SDL3, yaml-cpp, nvtt,
  openal-soft). xwin provisions the MSVC SDK into `~/.cache/ixray/msvc-sdk`.
- `cmake -B build-lsp ... -DIXRAY_UNITYBUILD=OFF` exists purely for clangd (per-file
  compile commands; unity chunks otherwise have no per-source entries).
- `CMAKE_POLICY_VERSION_MINIMUM=3.5` is exported by the shells (yaml-cpp/nvtt declare
  ancient `cmake_minimum_required`).

## Cross-compile pitfalls (learned the hard way — see docs/cross-compile.md)

- Host is case-sensitive; the engine assumes Windows' case-insensitivity everywhere.
  `file(GLOB)` **silently drops** patterns that don't match casing.
- `llvm-rc` can't parse Windows-1251 `©` and can't get `/c 65001` through CMake's shared RC
  flags → keep `.rc` files UTF-8 (BOM) with ASCII-safe strings.
- `__declspec(allocate(...))` is honored by clang-cl but silently dropped by MSVC; and
  `#pragma section(..., read)` sections are genuinely read-only (this killed the engine at
  xrCore init — see `xrMemory.cpp`).
- CMake's `CMAKE_MSVC_RUNTIME_LIBRARY` owns CRT selectors — never hand-pin `/MD`/`/MDd`
  alongside it.
- PDBs: Debug build emits `*.pdb` (use for winedbg symbolization); Release currently doesn't.
- Wine is not a Windows oracle: builtin dbghelp's `MiniDumpWriteDump` and similar can fail
  under Wine; validate user-visible behavior in Proton/Windows before blaming the build.

## Upstream-relation notes

- Upstream repo: `github.com/ixray-team/ixray-1.6-stcop` (this repo is a fork, branch
  `default`). Upstream docs: https://ixray-team.github.io/ixray-1.6-stcop/en/
- Upstream releases are packed manually (Release config, `MASTER_GOLD` defined); the public
  CI only uploads raw artifacts. Don't assume CI artifacts equal published builds.
- Several Linux/clang fixes here (case normalization, resource encodings, `init_seg`
  `.Hook` fix) are candidates for upstream PRs.

## Old World integration (the goal)

- Target: get the cross-compiled engine running the Old World `_GAME/` gamedata under
  Proton, then migrate the Old World level pack and game mechanics wholesale.
- Renderer: R4 only — `IXRAY_USE_R4` equivalents stay on; intention is to port OW's custom DX11 Static Renderer 
- Engine↔mod sync points to keep in mind: DLTX/DXML systems (configs), LuaJIT bindings
  (`src/xrScripts/exports/`), console commands (`src/xrEngine/xr_ioc_cmd.cpp`), and the
  launcher option sync described in the oldworld `AGENTS.md`.
