---
name: upstream-review
description: Read-only deep dive into the pending upstream batch before syncing — groups incoming ixray-team commits by subsystem theme, explains what the batch changes, and flags cross-compile hazards, hot-zone conflicts, playtest reminders, and behavior changes into a dated report under .agents/upstream-merge/reviews/
---

# Upstream review

Advisory, read-only (beyond `git fetch`/`git show`). Sits before
`upstream-sync`'s merge step for batches that deserve understanding, not just
landing. Writes one dated report per theme per session; nothing here gates the
sync, but `upstream-sync`'s plan should incorporate its flags.

## Steps

1. **Enumerate and group**:
   ```
   git fetch upstream default
   python3 .agents/skills/upstream-review/scripts/review_helpers.py group
   ```
   Themes are derived from the touched files' paths (rendering, game-logic,
   build-system, ...), ordered riskiest-first (by file count, then commits).

2. **Review one theme per session** (or as the user directs). For each commit
   in the theme: `git show <hash>` and actually read the diff. Explain in the
   report:
   - what changes, in engine terms, and why upstream made it (commit message
     + surrounding commits for context)
   - whether it touches our divergence in those files (compare
     `git diff upstream/default...HEAD -- <file>`)
   - the flags below, whenever they apply — as structured checklist items,
     not prose buried in a paragraph

3. **Flags** (the checklist section of the report):
   - `[ ] cross-compile hazard` — anything from
     `verify-parity/references/hazards.md`: MSVC-only constructs, new files
     with include-casing that won't survive the case-sensitive host, RC
     encoding risks, CRT selector changes.
   - `[ ] hot-zone conflict expected` — the change rewrites an area we've
     diverged in; name the file and both sides' intent.
   - `[ ] playtest reminder` — behavior changes the user should look at
     in-game after the sync lands.
   - `[ ] behavior change` — user-visible or config-visible differences.

4. **Write the report**:
   ```
   python3 .agents/skills/upstream-review/scripts/review_helpers.py write-report <theme-slug> <commits.json>
   ```
   (`commits.json` = a subset of `group`'s output.) Fill in the Analysis and
   Gotchas sections. Report path is printed — surface it to the user.

5. **Final report**: themes covered, report paths, flagged commits by flag
   type, and anything that should change `upstream-sync`'s plan (e.g. "expect
   a manual resolution in cmake/msvc.cmake").

## Additional resources

- `references/review-protocol.md` — report format details and flag semantics.
- `.agents/skills/README.md` — shared state overview.
