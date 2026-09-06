{
  # IX-Ray 1.6 STCOP — Nix devShells for the two supported build flows.
  #
  # ── Intended flow ──────────────────────────────────────────────────────
  # 1. `nix develop` (default shell, native Linux ELF):
  #      Tools + engine core libraries (xrCore, xrSound, xrNetServer) and
  #      the compressor. The playable engine itself is NOT buildable natively
  #      yet — xrAbstractions and above include d3d9/d3d11 headers and
  #      Windows APIs unconditionally, which needs real porting work.
  # 2. `nix develop .#winCross` (Windows x64 cross-compile, MSVC ABI):
  #      Builds the COMPLETE game (xrEngine.exe + xrGame + R1/R2/R4 render
  #      DLLs) from Linux — the artifacts run on Windows and under
  #      Wine/Proton. This is the intended path for playing/testing.
  #
  # ── Default (native Linux) shell ───────────────────────────────────────
  # Provides:
  #   * clang 18 + libc++ + lld — matches the Linux CI (build-utilities.yml)
  #     and satisfies the -stdlib=libc++ / -fuse-ld=lld flags hardcoded in
  #     cmake/clang.cmake. Use llvmPackages_18.libcxxStdenv, NOT the default
  #     gcc stdenv: the build unconditionally passes -stdlib=libc++.
  #   * clangd — via llvmPackages_18.clang-tools, version-matched to the
  #     compiler. NOT nvim's mason: mason ships prebuilt native binaries that
  #     cannot run on NixOS; nvim's environment profile
  #     (files/nvim/lua/config/profile.lua) only ever expects this from PATH.
  #   * codelldb — the vscode-lldb standalone adapter on PATH (same mason
  #     story; nvim's C/C++ DAP locates it via PATH).
  #   * cmake + ninja + neocmakelsp — the cmake nvim feature's LSP.
  #   * nuget — the CLI, so cmake/linux/nuget.cmake's find_program() picks it
  #     up instead of downloading nuget.exe (which would need mono binfmt).
  #     `nuget restore` fetches the prebuilt linux-x64 runtime .so packages
  #     (LuaJIT, GameNetworkingSockets, mimalloc, ...) from the ImeSense feed.
  #   * All system libraries the build searches for (cmake/linux/packages.cmake
  #     and cmake/modules/Find*.cmake): TBB, lzo2, ogg/opus/speexdsp/openal,
  #     plus the full SDL3 build dependency set. Listed as buildInputs so the
  #     stdenv propagates them into CMAKE_SYSTEM_PREFIX_PATH — that is how
  #     the hardcoded `PATHS /usr/include` fallbacks in packages.cmake resolve
  #     to the Nix store without any CMake patches.
  #   * ./.dev.local.sh sourced on shell entry if present — the per-developer
  #     personalization hook (see .dev.local.sh.example).
  #
  # x86_64-linux only: the NuGet runtime packages are linux-x64 prebuilts.
  #
  # Entry points:
  #   * direnv users:  `direnv allow`   (auto-activates via .envrc)
  #   * everyone else: `nix develop`
  #
  # Native build (tools + engine core libs only — see "Intended flow" above):
  #   cmake -B build -G Ninja -DIXRAY_USE_R1=OFF -DIXRAY_USE_R2=OFF
  #   cmake --build build --target xrCore xrSound xrNetServer xrCompress
  #
  # Note: the first configure needs network (NuGet restore + FetchContent for
  # SDL3 / yaml-cpp / nvtt / openal-soft). direnv/nix develop don't sandbox,
  # so this works out of the box.
  description = "IX-Ray 1.6 STCOP dev shells";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      devShells = forAllSystems (pkgs:
        let
          llvm = pkgs.llvmPackages_18;
        in
        {
          default = pkgs.mkShell.override { stdenv = llvm.libcxxStdenv; } {
            # Intentionally nvim-relevant tooling + build tools in `packages`;
            # libraries in `buildInputs` (see header comment on path
            # propagation).
            packages = with pkgs; [
              # Toolchain — libcxxStdenv provides clang 18 / libc++
              llvm.lld
              # nvim environment-sourced tools (clangd, DAP, cmake LSP)
              llvm.clang-tools
              vscode-extensions.vadimcn.vscode-lldb.adapter
              neocmakelsp
              # Build
              cmake
              ninja
              git
              pkg-config
              # NuGet CLI for cmake/linux/nuget.cmake
              nuget
            ];

            buildInputs = with pkgs; [
              # IX-Ray core
              tbb
              lzo
              util-linux.dev # libuuid
              openssl
              protobuf
              freetype
              libtheora

              # Audio. Deliberately NO openal-soft here: cmake/modules/
              # FindOpenalSoft.cmake expects to FetchContent openal-soft on
              # Linux (its target is named `OpenAL`); a system openal would
              # satisfy find_package(OpenAL) and break the xrSound link.
              libogg
              libvorbis
              opus
              speexdsp

              # SDL3 (built via FetchContent) dependency set
              alsa-lib
              libpulseaudio
              fribidi
              libjack2
              libx11
              libxext
              libxrandr
              libxcursor
              libxfixes
              libxi
              libxscrnsaver
              libxtst
              libxdmcp
              libxau
              libxcb
              libxcb-util
              libxcb-image
              libxcb-wm
              libxcb-keysyms
              libxcb-cursor
              libxkbcommon
              libdrm
              mesa
              dbus
              systemd # udev
              vulkan-loader
              vulkan-headers
              wayland
              wayland-protocols
              libusb1
              libdecor
              ibus
            ];

            shellHook = ''
              # ── Personal hook. Gitignored; teammates without one see nothing.
              #    Create .dev.local.sh to opt in (template: .dev.local.sh.example).
              if [ -f ./.dev.local.sh ]; then
                # shellcheck source=/dev/null
                . ./.dev.local.sh
              fi

              # FetchContent subprojects (yaml-cpp 0.8.0, nvtt) declare
              # cmake_minimum_required(<3.5), which CMake >= 4 rejects.
              # CMake reads this env var without any repo CMake changes.
              export CMAKE_POLICY_VERSION_MINIMUM=3.5

              # ── Project helper commands, as PATH scripts. direnv/nix
              #    develop can only carry exported env vars across shell
              #    boundaries, NOT aliases/functions (and the hook runs in
              #    bash regardless of the user's shell) — so zsh/fish users
              #    would never see them. Executables on PATH work everywhere.
              #    Project-local dir; gitignored; personalize via PATH in
              #    .dev.local.sh if you want your own versions first.
              helpers=".devshell-helpers"
              mkdir -p "$helpers"
              printf '#!/usr/bin/env bash\ncmake -B build -G Ninja -DIXRAY_USE_R1=OFF -DIXRAY_USE_R2=OFF "$@"\n' > "$helpers/ixray-configure"
              printf '#!/usr/bin/env bash\ncmake --build build --target xrCore xrSound xrNetServer xrCompress "$@"\n' > "$helpers/ixray-build"
              chmod +x "$helpers"/ixray-*
              export PATH="$PWD/$helpers:$PATH"

              # Runtime loader path for libs the build links against but the
              # nix clang wrapper doesn't embed RPATHs for (dev-shell builds
              # aren't patchelf'd like nixpkgs derivations).
              export LD_LIBRARY_PATH="${llvm.libcxx}/lib:${pkgs.tbb}/lib:${pkgs.lzo}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              echo "IX-Ray dev shell (native Linux — tools + engine core libs; the playable engine needs the winCross shell):"
              echo "  clang $(clang --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'), cmake $(cmake --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
              echo "  ixray-configure && ixray-build   (PATH scripts in .devshell-helpers/)"
            '';
          };

          # ── Windows x64 cross-compile shell (MSVC ABI) — the intended flow
          # for building the playable game from Linux:
          # clang-cl + lld-link + llvm-rc, with the MSVC CRT and Windows SDK
          # provisioned by `xwin` on first entry (cached in
          # ~/.cache/ixray/msvc-sdk, override with XRAY_MSVC_SDK).
          #
          #   cmake -B build-win -G "Ninja Multi-Config" \
          #         -DCMAKE_TOOLCHAIN_FILE=cmake/msvc-cross.cmake
          #   cmake --build build-win --config Release --target xrEngine
          #
          # Output dir: build-win/bin/Release/ — xrEngine.exe + xrGame.dll +
          # R1/R2/R4 render DLLs + all third-party DLLs (complete runtime).
          # Artifacts are regular Windows .exe/.dll — run via Proton/Wine
          # (Linux gamers: point Proton at the game install with these
          # binaries copied over bin/).
          # clangd also benefits: compile_commands.json from this build
          # carries the clang-cl driver flags, so IntelliSense sees the real
          # Windows SDK/STL headers.
          winCross = let
            # LLVM >= 19 is required by the MSVC STL that ships in current
            # VC CRT headers (STL1000: "expected Clang 19.0.0 or newer").
            llvmCross = pkgs.llvmPackages_20;
            # nixpkgs splits clang's builtin headers into the `lib` output;
            # the raw clang-cl binary looks for them next to itself and
            # doesn't find them, so wrap it with an explicit -resource-dir.
            # Without this, MSVC's intrinsic headers from the SDK shadow
            # clang's and every _mm_* intrinsic fails to inline.
            clangCl = pkgs.runCommand "clang-cl-msvc" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
              mkdir -p $out/bin
              makeWrapper ${llvmCross.clang-unwrapped}/bin/clang-cl $out/bin/clang-cl \
                --add-flags "-resource-dir ${llvmCross.clang-unwrapped.lib}/lib/clang/${nixpkgs.lib.versions.major llvmCross.clang-unwrapped.version}"
            '';
          in
            pkgs.mkShell {
            # libllvm (not `llvm`: the wrapped multi-output llvm package
            # breaks nix-shell dependency validation) carries llvm-rc,
            # llvm-lib, llvm-mt; lld carries lld-link.
            packages = (with llvmCross; [
              lld # lld-link
              libllvm # llvm-rc, llvm-lib, llvm-mt
            ]) ++ (with pkgs; [
              clangCl # clang-cl (resource-dir-wrapped)
              cmake
              ninja
              git
              pkg-config
              xwin
              nuget
            ]);

            shellHook = ''
              # ── Personal hook. Gitignored; teammates without one see nothing.
              if [ -f ./.dev.local.sh ]; then
                # shellcheck source=/dev/null
                . ./.dev.local.sh
              fi

              export XRAY_MSVC_SDK="''${XRAY_MSVC_SDK:-$HOME/.cache/ixray/msvc-sdk}"
              if [ ! -d "$XRAY_MSVC_SDK/sdk/lib/um" ]; then
                echo "==> Provisioning MSVC CRT + Windows SDK via xwin (one-off, ~1 GB download):"
                echo "    $XRAY_MSVC_SDK"
                xwin --accept-license --cache-dir "$HOME/.cache/ixray/xwin-dl" \
                     --arch x86_64 splat --include-debug-libs --output "$XRAY_MSVC_SDK"
              fi

              # cl-style env: clang-cl resolves includes from INCLUDE,
              # lld-link resolves import libs from LIB (';'-separated).
              # Layout is xwin 0.9's splat: crt/ + sdk/ (no version dirs).
              export INCLUDE="$XRAY_MSVC_SDK/crt/include;$XRAY_MSVC_SDK/sdk/include/ucrt;$XRAY_MSVC_SDK/sdk/include/um;$XRAY_MSVC_SDK/sdk/include/shared;$XRAY_MSVC_SDK/sdk/include/winrt;$XRAY_MSVC_SDK/sdk/include/cppwinrt"
              export LIB="$XRAY_MSVC_SDK/crt/lib/x86_64;$XRAY_MSVC_SDK/sdk/lib/um/x86_64;$XRAY_MSVC_SDK/sdk/lib/ucrt/x86_64"

              # clang-cl's default linker is link.exe; route it to lld-link
              # for manual compile+link invocations (CMake uses CMAKE_LINKER
              # = lld-link from the toolchain file and doesn't need this).
              binshim="$HOME/.cache/ixray/bin"
              mkdir -p "$binshim"
              command -v lld-link >/dev/null && ln -sf "$(command -v lld-link)" "$binshim/link.exe"
              export PATH="$binshim:$PATH"

              # ── Project helper commands (see the native shell's comment —
              #    PATH scripts instead of aliases, works in any shell).
              helpers=".devshell-helpers"
              mkdir -p "$helpers"
              printf '#!/usr/bin/env bash\ncmake -B build-win -G "Ninja Multi-Config" -DCMAKE_TOOLCHAIN_FILE=cmake/msvc-cross.cmake "$@"\n' > "$helpers/ixray-configure-win"
              printf '#!/usr/bin/env bash\ncmake --build build-win --config Release "$@"\n' > "$helpers/ixray-build-win"
              chmod +x "$helpers"/ixray-*
              export PATH="$PWD/$helpers:$PATH"

              echo "IX-Ray winCross shell (Windows x64 MSVC cross-compile — the playable game):"
              echo "  $(clang-cl --version | head -n1), lld-link $(lld-link --version | head -n1), SDK: $XRAY_MSVC_SDK"
              echo "  ixray-configure-win && ixray-build-win"
              echo "  → build-win/bin/Release/  (copy contents over the game's bin/ for Proton)"
            '';
          };
        });
    };
}
