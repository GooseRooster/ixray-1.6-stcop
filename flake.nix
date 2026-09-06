{
  # IX-Ray 1.6 STCOP — self-contained Nix devShell for the Linux build.
  #
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
  # Configure + build (GL renderer preset; D3D renderers are Windows-only):
  #   cmake -B build -G Ninja
  #   cmake --build build
  #
  # Note: the first configure needs network (NuGet restore + FetchContent for
  # SDL3 / yaml-cpp / nvtt). direnv/nix develop don't sandbox, so this works
  # out of the box.
  description = "IX-Ray 1.6 STCOP Linux dev shell";

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

              # Audio
              libogg
              libvorbis
              opus
              speexdsp
              openal-soft

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

              # Runtime loader path for libs the build links against but the
              # nix clang wrapper doesn't embed RPATHs for (dev-shell builds
              # aren't patchelf'd like nixpkgs derivations).
              export LD_LIBRARY_PATH="${llvm.libcxx}/lib:${pkgs.tbb}/lib:${pkgs.lzo}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              echo "IX-Ray dev shell: clang $(clang --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'), cmake $(cmake --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
              echo "  cmake -B build -G Ninja && cmake --build build"
            '';
          };
        });
    };
}
