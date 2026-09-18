# common.sh — shared logic for the ixray-* devshell helpers.
# Sourced, never executed directly.

set -euo pipefail

# Repo root (scripts/devshell/ → two levels up).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Windows cross-compile build dirs (Ninja Multi-Config, cmake/msvc-cross.cmake).
WIN_BUILD_DIR="build-win"
WIN_PROFILE_DIR="build-win-profile"

# Native Linux build dir.
NATIVE_BUILD_DIR="build"

# fail <message> — print to stderr and exit 1.
fail() {
    echo "error: $*" >&2
    exit 1
}

# require_configured <build-dir> — make sure a CMake cache exists.
require_configured() {
    [ -f "$1/CMakeCache.txt" ] || \
        fail "$1 is not configured — run ixray-configure-win first (see docs/devshell.md)"
}

# ensure_cache_var <build-dir> <VAR> <ON|OFF>
# Reconfigure only when the cached value differs — a needless reconfigure
# re-runs the NuGet restore at configure time.
ensure_cache_var() {
    local dir="$1" var="$2" val="$3"
    local cached=""
    if [ -f "$dir/CMakeCache.txt" ]; then
        cached="$(grep -m1 "^${var}:" "$dir/CMakeCache.txt" | cut -d= -f2 || true)"
    fi
    if [ "$cached" != "$val" ]; then
        echo "==> ${var}=${val} (reconfiguring ${dir})"
        cmake -S "$REPO_ROOT" -B "$dir" -D"${var}=${val}"
    fi
}

# configure_win <build-dir> [extra cmake args...]
configure_win() {
    local dir="$1"
    shift
    cmake -S "$REPO_ROOT" -B "$dir" -G "Ninja Multi-Config" \
        -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT/cmake/msvc-cross.cmake" \
        -DIXRAY_MP=ON "$@"
}

# build_dir <build-dir> <config> [extra cmake --build args...]
build_dir() {
    local dir="$1" cfg="$2"
    shift 2
    cmake --build "$dir" --config "$cfg" "$@"
}
