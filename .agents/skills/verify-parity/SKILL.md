---
name: verify-parity
description: Runs the fork's cross-compile parity gate — hazard scan (include casing, MSVC-only constructs, CRT pins, RC encoding) plus ixray-build-win and ixray-clangd-db — over a change range; required after every upstream sync and OW feature port, and runnable standalone anytime
---

# Verify parity

The shared exit criterion for `upstream-sync` and `port-ow-feature`, and a
standalone check anytime the cross build feels at risk. Two halves:

1. **Hazard scan** (no build needed) — static checks over the changed files.
2. **Build half** (needs the winCross devshell) — `ixray-build-win <preset>`
   and `ixray-clangd-db` must both succeed.

## Usage

```
nix develop .#winCross
python3 .agents/skills/verify-parity/scripts/parity_gate.py --base <ref> --head <ref> [--preset release|debug|...] [--skip-build]
```

Defaults: `--base upstream/default --head HEAD --preset release`. Sensible
bases: the pre-merge HEAD for a sync, `HEAD~<n>` for a port, or a branch.

## Interpretation

- `include ... does not match on-disk casing` — will break the cross build
  later even if MSVC builds fine (the host filesystem is case-sensitive).
  Fix the include or the file name.
- `__declspec(allocate(...))` / `#pragma section(..., read)` — these two
  killed the engine at xrCore init once already (see
  `docs/cross-compile.md`). MSVC silently drops the first and is lenient
  about the second; clang-cl honors both literally.
- `hand-pinned /MD[d]` — CRT selector mixing, heap corruption territory.
- `.rc not valid UTF-8` — llvm-rc cannot parse CP1251; convert with BOM and
  ASCII-safe strings.
- Build/clangd failures — fix before anything else; the exact preset's error
  output is the starting point.

A clean gate means: the change range cross-compiles, per-file clangd still
resolves, and none of the known fork-killing patterns are present. It does
NOT mean MSVC builds — for changes suspected of MSVC-only breakage, CI on the
fork's GitHub (RelWithDebInfo) is the backstop.

## Additional resources

- `references/hazards.md` — the full hazard checklist with reasoning and
  fix recipes, cross-referenced from `docs/cross-compile.md`.
- `.agents/skills/README.md` — shared state overview.
