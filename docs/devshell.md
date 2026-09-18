# Devshells & Build Presets

The two Nix devShells (`flake.nix`) and the `scripts/devshell/` helper scripts.
Cross-compile history and pitfalls: [cross-compile.md](cross-compile.md).

## Shells

| Shell | Enter | Purpose |
|---|---|---|
| `default` | `nix develop` | Native Linux: tools + engine core libs (`xrCore`, `xrSound`, `xrNetServer`) and the compressor. The playable engine is **not** natively buildable yet (unconditional d3d9/d3d11 includes in `xrAbstractions`). |
| `winCross` | `nix develop .#winCross` | Windows x64 cross-compile (clang-cl + lld-link + llvm-rc, MSVC ABI). Builds the complete game — the intended path for playing/testing. |

Both are x86_64-linux only (the NuGet runtime packages are linux-x64 prebuilts).
Direnv users: `use flake` / `use flake .#winCross` in `.envrc`.

## Helper scripts (`scripts/devshell/`)

Checked-in bash scripts, put on PATH by both shellHooks (direnv/nix develop can
only carry exported env vars across shell boundaries, not aliases/functions —
so they must be executables). A gitignored `.devshell-helpers/` dir, if
present, wins on PATH for personal overrides.

### Windows cross-compile (winCross shell)

```
ixray-configure-win [--pdbs] [--dev] [--editors] [--profile] [extra cmake args]
ixray-build-win   [preset] [--editors] [extra cmake --build args...]
```

`ixray-build-win` presets — each asserts its CMake option state (reconfiguring
only when the cache differs, so no needless NuGet restore), then builds:

| Preset | Dir | Config | Options | Use |
|---|---|---|---|---|
| `release` (default) | `build-win` | Release | — | The shippable game build (`MASTER_GOLD`, MP parity) |
| `release-pdbs` | `build-win` | Release | `IXRAY_PDB=ON` | Release + PDBs for crash symbolization |
| `debug` | `build-win` | Debug | — | `DEBUG`/`DEBUG_DRAW` defined, PDBs automatic |
| `dev` | `build-win` | Debug | `IXRAY_UTILS=ON` (+`IXRAY_EDITORS=ON` with `--editors`) | Dev tools; Editors cross-build is untested territory |
| `profile` | `build-win-profile` | Release | `IXRAY_PROFILER=ON`, `IXRAY_PDB=ON` | Optick profiling build (see below) |

`profile` gets its own build dir because `IXRAY_PROFILER` changes compile
definitions for every target (the `PROF_*` macros in `src/xrCore/profiler.h`
become real Optick calls) — toggling it in `build-win` would force full
rebuilds between normal and profiling sessions.

Extra args pass through to the underlying cmake command, e.g.
`ixray-build-win release --target xrEngine`.

### Native Linux (default shell)

```
ixray-configure [extra cmake args]     # cmake -B build -G Ninja, R1/R2 off
ixray-build [extra args]               # xrCore xrSound xrNetServer xrCompress
```

### clangd

```
ixray-clangd-db    # regenerate build-lsp/ + root compile_commands.json symlink
```

`build-win`'s compile database is unity-chunked (xrGame builds via UnityBuild),
so individual sources have no entries and clangd falls back to wrong commands
→ false-error storms. `ixray-clangd-db` configures a unity-free dir
(`build-lsp/`, configure-only, never built) purely to emit per-file compile
commands; the root `compile_commands.json` symlink points at it. Regenerate
after CMake changes. The clang-cl driver flags in it give clangd the real
Windows SDK/STL headers; the raw (resource-dir-wrapped) clangd in the winCross
shell is required — see below.

`ixray-clangd-db` also post-processes the db to inject `/FI <targetdir>/stdafx.h`
into every command of a target whose source dir has one (6762 entries / 33
targets at the time of writing). Reason: clangd parses a header standalone with
the inferred TU's flags but never replays the TU's include order, and X-Ray
headers are not self-contained — they assume the target's stdafx was
force-fed first. The real build does that via `target_precompile_headers` →
`/FI cmake_pch.hxx`, which `.clangd` must strip (`/Yu*` `/Fp*` `/Yc*` — the .pch
never exists in configure-only `build-lsp/`). Without the injected `/FI`,
headers die in cascades starting from a single real error (typically
`ENGINE_API`/xrCore never being included), the 19-error limit trips, and the
fatal "too many errors emitted" gets pinned at line 1 (`#pragma once` / include
guard) with "unknown type BOOL/LPCSTR" noise behind it. `.clangd` therefore
does NOT strip `/FI*` — don't re-add it, it would neuter the injection.

## Profiling & benchmarking

```bash
nix develop .#winCross
ixray-build-win profile
```

Deploy the **whole** `build-win-profile/bin/Release/` over the game's `bin/`
(includes `OptickCore.dll` and matching PDBs). The engine's `PROF_FRAME`
covers the main thread loop (`src/xrEngine/device.cpp`), xrRender has ~75
`GPU_EVENT` sites, and more `PROF_EVENT`s exist across the engine.

Capture: in-game ImGui **Debug → Optick Start Capture**, later **Optick Stop
Capture** — writes `ixray-optick-<date>-<time>-<user>.opt` (viewable in the
Optick GUI on Windows). The profile build also carries Release PDBs, so
ETW/xperf-style sampling symbolizes cleanly.

Notes:

- A profile build is a distinct binary set — don't mix its PDBs with
  `build-win` artifacts (PDB GUIDs only match their own link).
- `MASTER_GOLD` is defined (Release config), so behavior matches the shipped
  engine apart from the profiler instrumentation itself.

## Why the shells are built this way

### Native shell

- **`llvmPackages_18.libcxxStdenv`, not the default gcc stdenv**: the build
  unconditionally passes `-stdlib=libc++` / `-fuse-ld=lld`
  (`cmake/clang.cmake`) and the Linux CI uses clang 18 + libc++.
- **clangd via `llvm.clang-tools`**: version-matched to the compiler. NOT
  nvim's mason — mason ships prebuilt native binaries that cannot run on
  NixOS; nvim's environment profile only expects it from PATH.
- **codelldb**: the vscode-lldb standalone adapter on PATH (same mason story;
  nvim's C/C++ DAP locates it via PATH).
- **nuget CLI on PATH**: so `cmake/linux/nuget.cmake`'s `find_program()` picks
  it up instead of downloading nuget.exe (which would need mono binfmt).
  `nuget restore` fetches the prebuilt linux-x64 runtime packages (LuaJIT,
  GameNetworkingSockets, mimalloc, ...) from the ImeSense feed.
- **Libraries as `buildInputs`, not `packages`**: the stdenv propagates
  buildInputs into `CMAKE_SYSTEM_PREFIX_PATH` — that is how the hardcoded
  `PATHS /usr/include` fallbacks in `cmake/linux/packages.cmake` and the
  `Find*` modules resolve to the Nix store without any CMake patches.
- **No system openal-soft**: `cmake/modules/FindOpenalSoft.cmake` expects to
  FetchContent openal-soft on Linux; a system copy would satisfy
  `find_package(OpenAL)` and break the xrSound link.
- **`LD_LIBRARY_PATH`**: dev-shell builds aren't patchelf'd like nixpkgs
  derivations; the nix clang wrapper doesn't embed RPATHs for the linked libs.

### winCross shell

- **LLVM 20** (≥ 19 required by the MSVC STL in current VC CRT headers —
  STL1000: "expected Clang 19.0.0 or newer").
- **Raw clang-cl/clangd wrapped with `-resource-dir`**: nixpkgs splits
  clang's builtin headers into the `lib` output; the raw clang-cl binary
  looks for them next to itself and doesn't find them, so MSVC's intrinsic
  headers from the SDK shadow clang's and every `_mm_*` intrinsic fails to
  inline. The wrapped clangd (nixpkgs) would additionally inject the host
  toolchain (GCC libstdc++, glibc headers) into every parse, burying
  MSVC-targeted IntelliSense in errors.
- **`libllvm`, not `llvm`**: the wrapped multi-output llvm package breaks
  nix-shell dependency validation. `libllvm` carries llvm-rc, llvm-lib,
  llvm-mt; `lld` carries lld-link.
- **xwin**: provisions the MSVC CRT + Windows SDK (`xwin splat
  --include-debug-libs`, ~1 GB one-off) into `~/.cache/ixray/msvc-sdk`
  (override with `XRAY_MSVC_SDK`).
- **`INCLUDE`/`LIB` env vars**: cl-style — clang-cl resolves includes from
  INCLUDE, lld-link resolves import libs from LIB (';'-separated). Layout is
  xwin 0.9's splat: `crt/` + `sdk/` (no version dirs).
- **`link.exe` shim → lld-link** (`~/.cache/ixray/bin`): clang-cl's default
  linker is link.exe; CMake doesn't need this (it uses `CMAKE_LINKER` from
  `cmake/msvc-cross.cmake`) but manual compile+link invocations do.

### Both shells

- **`CMAKE_POLICY_VERSION_MINIMUM=3.5`**: FetchContent subprojects (yaml-cpp
  0.8.0, nvtt) declare `cmake_minimum_required(<3.5>)`, which CMake ≥ 4
  rejects. CMake reads this env var without any repo CMake changes.
- **`./.dev.local.sh`**: sourced on shell entry if present — the per-developer
  personalization hook (gitignored; template: `.dev.local.sh.example`).
- First configure needs network (NuGet restore + FetchContent: SDL3,
  yaml-cpp, nvtt, openal-soft; xwin provisioning in winCross).
  direnv/nix develop don't sandbox, so this works out of the box.
