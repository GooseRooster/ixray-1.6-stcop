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
  # What builds on Linux today (matching upstream's Linux CI scope — the
  # playable engine itself is still Windows-only upstream: no GL renderer,
  # D3D-only renders, xrAbstractions has unported code):
  #   cmake -B build -G Ninja -DIXRAY_USE_R1=OFF -DIXRAY_USE_R2=OFF
  #   cmake --build build --target xrCore xrSound xrCompress
  #
  # Note: the first configure needs network (NuGet restore + FetchContent for
  # SDL3 / yaml-cpp / nvtt / openal-soft). direnv/nix develop don't sandbox,
  # so this works out of the box.
  # Cross-compilation to Windows x64 (MSVC ABI) from Linux — see the
  # winCross shell below. The Linux shell above builds native ELF binaries.
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

              # Runtime loader path for libs the build links against but the
              # nix clang wrapper doesn't embed RPATHs for (dev-shell builds
              # aren't patchelf'd like nixpkgs derivations).
              export LD_LIBRARY_PATH="${llvm.libcxx}/lib:${pkgs.tbb}/lib:${pkgs.lzo}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              echo "IX-Ray dev shell: clang $(clang --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'), cmake $(cmake --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
              echo "  cmake -B build -G Ninja -DIXRAY_USE_R1=OFF -DIXRAY_USE_R2=OFF"
              echo "  cmake --build build --target xrCompress   # full 'ALL' does not build yet: see notes below"
            '';
          };

          # Windows x64 cross-compile shell (MSVC ABI, no MinGW, no Wine SDK):
          # clang-cl + lld-link + llvm-rc, with the MSVC CRT and Windows SDK
          # provisioned by `xwin` on first entry (cached in
          # ~/.cache/ixray/msvc-sdk, override with XRAY_MSVC_SDK).
          #
          #   cmake -B build-win -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/msvc-cross.cmake
          #   cmake --build build-win
          #
          # Artifacts are regular Windows .exe/.dll — run via Proton/Wine.
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

              echo "IX-Ray winCross shell: $(clang-cl --version | head -n1), lld-link $(lld-link --version | head -n1), SDK: $XRAY_MSVC_SDK"
              echo "  cmake -B build-win -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/msvc-cross.cmake"
              echo "  cmake --build build-win"
            '';
          };
        });
    };
}
