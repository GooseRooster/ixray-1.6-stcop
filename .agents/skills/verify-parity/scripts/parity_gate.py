#!/usr/bin/env python3
"""verify-parity gate: cross-compile + clangd + hazard scan for a change range.

Every upstream sync and every OW feature port must pass this gate before the
change is trusted. Run inside the winCross devshell (needs clang-cl/ixray-* on
PATH); use --skip-build for the hazard scan alone.

Usage:
  python3 parity_gate.py [--base upstream/default] [--head HEAD] [--preset release]
                         [--skip-build]

Checks (see references/hazards.md for the reasoning behind each):
  1. hazard scan of changed files:
     - #include casing that doesn't match the case-sensitive host filesystem
     - __declspec(allocate(...)) (honored by clang-cl, silently dropped by MSVC)
     - #pragma section(..., read) sections receiving written globals
     - hand-pinned /MD /MDd in cmake files (CRT selector is CMake-owned)
     - .rc files that are not valid UTF-8 (llvm-rc can't parse CP1251)
  2. cross build: ixray-build-win <preset> must succeed (default: release)
  3. clangd DB regeneration: ixray-clangd-db must succeed
"""

import argparse
import difflib
import fnmatch
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

INCLUDE_RX = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)
DECLSPEC_ALLOCATE_RX = re.compile(r"__declspec\s*\(\s*allocate\s*\(")
PRAGMA_SECTION_RX = re.compile(r"#pragma\s+section\s*\(([^)]*)\)")
MD_PIN_RX = re.compile(r'[^/\w]/MD[dt]?\b|^/MD[dt]?\b')

REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))


def git(*args, check=True):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check, cwd=REPO_ROOT)


def changed_files(base, head):
    r = git("diff", "--name-only", "--diff-filter=ACMR", f"{base}..{head}")
    return [l for l in r.stdout.splitlines() if l]


def resolve_include(include, src_file, roots):
    """Return (exact_hit, case_insensitive_hit) for a quoted include."""
    inc_norm = include.replace("\\", "/")
    ci = inc_norm.lower()
    for root in roots:
        candidate = os.path.normpath(os.path.join(root, inc_norm))
        if os.path.isfile(candidate):
            return candidate, None
        # case-insensitive walk
        cur = root
        parts = [p.lower() for p in inc_norm.split("/")]
        for part in parts[:-1]:
            try:
                match = next(p for p in os.listdir(cur) if p.lower() == part)
            except StopIteration:
                break
            cur = os.path.join(cur, match)
        else:
            try:
                match = next(p for p in os.listdir(cur) if p.lower() == parts[-1])
                return None, os.path.join(cur, match)
            except StopIteration:
                pass
    return None, None


def include_roots(src_file):
    roots = [os.path.dirname(src_file)]
    mod_dir = os.path.dirname(src_file)
    # climb to the module root (src/<module>) — includes like "xrCore/xrCore.h"
    while os.path.dirname(mod_dir) != os.path.join(REPO_ROOT, "src") and \
          os.path.dirname(mod_dir).startswith(os.path.join(REPO_ROOT, "src")):
        mod_dir = os.path.dirname(mod_dir)
    roots.append(os.path.join(REPO_ROOT, "src"))
    if mod_dir.startswith(os.path.join(REPO_ROOT, "src")):
        roots.append(mod_dir)
    return roots


def scan_file(path, findings):
    full = os.path.join(REPO_ROOT, path)
    if not os.path.isfile(full):
        return
    try:
        with open(full, encoding="utf-8") as f:
            text = f.read()
    except UnicodeDecodeError:
        if path.lower().endswith(".rc"):
            # llvm-rc cannot parse CP1251 (no codepage auto-detection).
            findings.append(f"{path}: not valid UTF-8 (llvm-rc cannot parse CP1251; convert with BOM)")
        # Non-UTF-8 .cpp/.h (CP1251 comments) is tolerated by clang-cl — not a gate failure.
        return

    code_lines = [l for l in text.splitlines() if not l.lstrip().startswith("//")]

    if path.lower().endswith((".h", ".hpp", ".cpp", ".cxx", ".c")):
        for inc in INCLUDE_RX.findall(text):
            if inc.startswith(("..", "./", "/")) or "/" in inc or inc.endswith(".h"):
                exact, ci_hit = resolve_include(inc, full, include_roots(full))
                if ci_hit and not exact:
                    findings.append(
                        f"{path}: include \"{inc}\" does not match on-disk casing "
                        f"(host is case-sensitive; exists as {os.path.relpath(ci_hit, REPO_ROOT)})")
        code = "\n".join(code_lines)
        has_allocate = bool(DECLSPEC_ALLOCATE_RX.search(code))
        if has_allocate:
            findings.append(f"{path}: __declspec(allocate(...)) — honored by clang-cl, silently "
                            f"dropped by MSVC; init_seg + writable data only (see xrMemory.cpp history)")
        if has_allocate and any(PRAGMA_SECTION_RX.search(l) and re.search(r"\bread\b", l)
                                for l in code_lines):
            # A read-only section only kills when something is allocated into it
            # (an orphan #pragma section(..., read) with no allocate is benign —
            # see xrMemory.cpp).
            findings.append(f"{path}: #pragma section(..., read) + __declspec(allocate) — "
                            f"read-only section receiving written globals")

    if fnmatch.fnmatch(path.lower(), "*.cmake") or path.endswith("CMakeLists.txt"):
        for i, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue  # cmake comments may legitimately discuss /MD
            if MD_PIN_RX.search(line):
                findings.append(f"{path}:{i}: hand-pinned /MD[d] — CMAKE_MSVC_RUNTIME_LIBRARY owns "
                                f"CRT selectors (two CRT heaps = corruption)")


def cmd_run_build(preset):
    if not shutil_which("clang-cl"):
        print("FAIL: clang-cl not on PATH — run inside the winCross devshell "
              "(nix develop .#winCross)", file=sys.stderr)
        return False
    for label, cmd in (
        (f"ixray-build-win {preset}", ["ixray-build-win", preset]),
        ("ixray-clangd-db", ["ixray-clangd-db"]),
    ):
        print(f"==> running {label}")
        r = subprocess.run(cmd, cwd=REPO_ROOT)
        if r.returncode != 0:
            print(f"FAIL: {label} exited {r.returncode}", file=sys.stderr)
            return False
    return True


def shutil_which(name):
    from shutil import which
    return which(name)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", default="upstream/default",
                   help="diff base (default: upstream/default)")
    p.add_argument("--head", default="HEAD")
    p.add_argument("--preset", default="release", help="ixray-build-win preset for the build check")
    p.add_argument("--skip-build", action="store_true", help="hazard scan only")
    args = p.parse_args()

    if args.base == "upstream/default":
        probe = git("rev-parse", "--verify", "--quiet", "upstream/default", check=False)
        if probe.returncode != 0:
            print("note: no upstream/default ref — defaulting base to HEAD~1")
            args.base = "HEAD~1"

    files = changed_files(args.base, args.head)
    print(f"==> scanning {len(files)} changed file(s) ({args.base}..{args.head})")
    findings = []
    for path in files:
        scan_file(path, findings)

    rc = 0
    if findings:
        rc = 1
        print("\nHAZARDS FOUND:")
        for f in findings:
            print(f"  - {f}")
    else:
        print("==> hazard scan: clean")

    if not args.skip_build:
        if not cmd_run_build(args.preset):
            rc = 1

    print(f"==> parity gate: {'PASS' if rc == 0 else 'FAIL'}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
