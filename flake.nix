{
  # IX-Ray 1.6 STCOP — Nix devShells for the two supported build flows.
  # Full rationale for every shell ingredient: docs/devshell.md.
  # Cross-compile status/history: docs/cross-compile.md.
  #
  #   nix develop           native Linux — tools + engine core libs only
  #                         (the playable engine is not natively buildable yet)
  #   nix develop .#winCross  Windows x64 cross-compile (clang-cl + lld-link)
  #                         — the intended path for playing/testing the game
  #
  # Build helpers (ixray-configure*, ixray-build*, ixray-clangd-db) are
  # checked-in scripts in scripts/devshell/, put on PATH by both shellHooks.
  # Both x86_64-linux only (NuGet runtime packages are linux-x64 prebuilts).
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
            # Tools in `packages`, libraries in `buildInputs` (the stdenv
            # propagates buildInputs into CMAKE_SYSTEM_PREFIX_PATH — that is
            # how the hardcoded PATHS in cmake/linux/packages.cmake resolve
            # to the Nix store; see docs/devshell.md).
            packages = with pkgs; [
              llvm.lld
              llvm.clang-tools # clangd, version-matched to the compiler
              vscode-extensions.vadimcn.vscode-lldb.adapter # codelldb (nvim DAP)
              neocmakelsp
              cmake
              ninja
              git
              pkg-config
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

              # Audio. No openal-soft here on purpose: FindOpenalSoft.cmake
              # FetchContents openal-soft on Linux; a system copy would
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
              # Personal hook (gitignored; template: .dev.local.sh.example).
              if [ -f ./.dev.local.sh ]; then
                # shellcheck source=/dev/null
                . ./.dev.local.sh
              fi

              # yaml-cpp 0.8.0 / nvtt declare ancient cmake_minimum_required;
              # CMake >= 4 rejects them without this.
              export CMAKE_POLICY_VERSION_MINIMUM=3.5

              # Project helpers (checked in). A gitignored .devshell-helpers/
              # dir, if present, wins on PATH for personal overrides.
              export PATH="$PWD/.devshell-helpers:$PWD/scripts/devshell:$PATH"

              # Runtime loader path for libs the nix clang wrapper doesn't
              # embed RPATHs for.
              export LD_LIBRARY_PATH="${llvm.libcxx}/lib:${pkgs.tbb}/lib:${pkgs.lzo}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              echo "IX-Ray dev shell (native Linux — tools + engine core libs; the playable engine needs the winCross shell):"
              echo "  clang $(clang --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'), cmake $(cmake --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
              echo "  ixray-configure && ixray-build"
            '';
          };

          # ── Windows x64 cross-compile shell (MSVC ABI) — the intended flow
          # for building the playable game from Linux. clang-cl + lld-link +
          # llvm-rc, MSVC CRT/Windows SDK provisioned by xwin into
          # ~/.cache/ixray/msvc-sdk (override with XRAY_MSVC_SDK).
          winCross = let
            # LLVM >= 19 required by current MSVC STL headers (STL1000).
            llvmCross = pkgs.llvmPackages_20;
            # Wrap clang-cl/clangd with an explicit -resource-dir: nixpkgs
            # splits clang's builtin headers into the `lib` output, and the
            # wrapped clangd would inject host GCC headers into MSVC-targeted
            # parses. See docs/devshell.md.
            wrapRawClang = name: bin: pkgs.runCommand "${name}-msvc" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
              mkdir -p $out/bin
              makeWrapper ${llvmCross.clang-unwrapped}/bin/${bin} $out/bin/${bin} \
                --add-flags "-resource-dir ${llvmCross.clang-unwrapped.lib}/lib/clang/${nixpkgs.lib.versions.major llvmCross.clang-unwrapped.version}"
            '';
            clangCl = wrapRawClang "clang-cl" "clang-cl";
            clangdRaw = wrapRawClang "clangd" "clangd";
          in
            pkgs.mkShell {
            # libllvm (not the wrapped multi-output `llvm` package — it breaks
            # nix-shell dependency validation) carries llvm-rc, llvm-lib,
            # llvm-mt; lld carries lld-link.
            packages = (with llvmCross; [
              lld
              libllvm
            ]) ++ (with pkgs; [
              clangCl
              clangdRaw
              vscode-extensions.vadimcn.vscode-lldb.adapter # codelldb (nvim DAP)
              neocmakelsp
              cmake
              ninja
              git
              pkg-config
              xwin
              nuget
            ]);

            shellHook = ''
              # Personal hook (gitignored; template: .dev.local.sh.example).
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

              # Route clang-cl's default link.exe to lld-link for manual
              # invocations (CMake uses CMAKE_LINKER from the toolchain file).
              binshim="$HOME/.cache/ixray/bin"
              mkdir -p "$binshim"
              command -v lld-link >/dev/null && ln -sf "$(command -v lld-link)" "$binshim/link.exe"
              export PATH="$binshim:$PWD/.devshell-helpers:$PWD/scripts/devshell:$PATH"

              echo "IX-Ray winCross shell (Windows x64 MSVC cross-compile — the playable game):"
              echo "  $(clang-cl --version | head -n1), lld-link $(lld-link --version | head -n1), SDK: $XRAY_MSVC_SDK"
              echo "  ixray-configure-win && ixray-build-win [release|release-pdbs|debug|dev|profile]"
              echo "  ixray-clangd-db   # regenerate per-file compile_commands for clangd"
              echo "  → build-win/bin/Release/  (copy contents over the game's bin/ for Proton)"
            '';
          };
        });
    };
}
