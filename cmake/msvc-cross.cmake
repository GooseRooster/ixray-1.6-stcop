# Cross-compilation toolchain: Windows x64 (MSVC ABI) from a Linux host.
#
# Uses clang-cl (MSVC ABI compatible) + lld-link, with the MSVC CRT and
# Windows SDK provisioned by `xwin` (see the winCross devShell in flake.nix,
# which exports INCLUDE/LIB pointing at the splatted SDK and puts the LLVM
# MSVC-frontend tools on PATH).
#
# Usage:
#   cmake -B build-win -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/msvc-cross.cmake
#
# The produced binaries are plain Windows x64 executables/DLLs — no Wine,
# MinGW or MSVC installation involved.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

# Root of the xwin "splat" (CRT + Windows SDK). Prefer the environment the
# devShell sets up; fall back to the default cache location.
set(MSVC_CROSS_SDK "$ENV{XRAY_MSVC_SDK}" CACHE PATH "MSVC CRT/SDK root (xwin splat)")
if(NOT MSVC_CROSS_SDK)
    set(MSVC_CROSS_SDK "$ENV{HOME}/.cache/ixray/msvc-sdk" CACHE PATH "MSVC CRT/SDK root (xwin splat)" FORCE)
endif()
if(NOT EXISTS "${MSVC_CROSS_SDK}/crt")
    message(FATAL_ERROR
        "MSVC SDK not found at '${MSVC_CROSS_SDK}'.\n"
        "Enter the winCross devShell (nix develop .#winCross / direnv) — "
        "its shellHook provisions it via xwin.")
endif()

# LLVM MSVC-frontend toolchain
set(CMAKE_C_COMPILER clang-cl CACHE FILEPATH "")
set(CMAKE_CXX_COMPILER clang-cl CACHE FILEPATH "")
set(CMAKE_RC_COMPILER llvm-rc CACHE FILEPATH "")
set(CMAKE_MT llvm-mt CACHE FILEPATH "")
set(CMAKE_AR llvm-lib CACHE FILEPATH "")
set(CMAKE_LINKER lld-link CACHE FILEPATH "")

# The CMake scripts reference VS-generator variables for NuGet/SDK paths
# (e.g. packages/.../native/lib/${CMAKE_VS_PLATFORM_NAME}/Release/*.lib).
# Without the VS generator it is empty — provide it explicitly.
set(CMAKE_VS_PLATFORM_NAME "x64" CACHE STRING "VS platform name emulation for Ninja cross builds")
