---
name: upstream-sync
description: Syncs the ixray-team/ixray-1.6-stcop upstream into this fork via merge + skip-ledger — fetches, classifies the incoming batch, flags hot-zone conflicts, merges with divergence-aware conflict resolution, re-applies recorded skips, and runs the verify-parity gate
---

# Upstream sync (merge + skip-ledger)

This fork syncs upstream (ixray-team, see `ledger/meta.json` for the remote/branch)
by **merging wholesale** — upstream is focused and low-noise, so selectivity is
the exception, not the rule. The exception is recorded: every upstream commit we
deliberately reject lives in the shared ledger as a `skip` entry carrying the
hash of our revert, and each sync re-applies those reverts after merging.

The fork's divergence (cross-compile fixes, OW ports) is protected by the
**hot-zone set**: derived at runtime from `git diff upstream/default...HEAD`
(our actual changes since merge-base) plus the hand-curated
`hotzones.jsonl` registry. Hot-zone hits in the incoming batch are where merge
conflicts and semantic clashes will happen.

This skill is the only thing that merges upstream. It always runs the parity
gate before declaring a sync done, and it never pushes.

## Steps

1. **Fetch and enumerate** (read-only):
   ```
   git fetch <upstream> <branch>          # remote/branch from ledger/meta.json
   python3 .agents/skills/upstream-sync/scripts/sync_helpers.py pending
   ```
   The JSON groups incoming commits by interest category (informational —
   everything merges by default), lists hot-zone hits with the overlapping
   files, and shows counts. If `total_new` is 0, report and stop.

2. **Examine hot-zone hits**: for each commit with `hot_zone: true`, read the
   diff (`git show <hash>`) against the specific divergence in that file
   (our side: `git diff upstream/default...HEAD -- <file>`). These are the
   predicted conflict points — note for the plan which ones will need manual
   resolution and what our side intends.

3. **Optional deep dive**: for large or risky batches, run the
   `upstream-review` skill first (advisory; it writes a report under
   `.agents/upstream-merge/reviews/`).

4. **Draft the plan** and get it through plan-mode approval. The plan lists:
   the incoming range, predicted hot-zone conflicts and resolution intent,
   ledger skip entries whose reverts will be re-applied (step 6), and the
   parity gate as the exit criterion.

5. **Merge** on `default`:
   ```
   git merge upstream/default
   ```
   Resolve conflicts manually — never blanket `ours`/`theirs`. For hot-zone
   files, our divergence usually wins unless upstream fixed a bug we also
   want; when both sides must survive (e.g. upstream refactor + our
   cross-compile guard), re-apply our guard onto upstream's new shape.
   Record every nontrivial resolution as a ledger `conflict_note`.

6. **Re-apply recorded skips**:
   ```
   python3 .agents/skills/upstream-sync/scripts/sync_helpers.py skip-reverts
   ```
   For each `skip` entry, `git revert --no-commit <revert_hash>`:
   - clean apply → the merge reintroduced the rejected change; keep the revert
     and commit it as part of the sync.
   - revert fails/empty → the change isn't present; `git revert --abort` (or
     clean the index) and move on.
   If upstream *fixed* the reason a commit was skipped, propose dropping the
   ledger entry instead of re-reverting — user confirms.

7. **Parity gate** — the sync is not done until this passes:
   ```
   python3 .agents/skills/verify-parity/scripts/parity_gate.py --base <pre-merge-HEAD> --head HEAD
   ```
   (run inside the winCross devshell; see the `verify-parity` skill). Fix
   whatever it finds — a hazard here means upstream reintroduced a
   cross-compile killer (bad include casing, MSVC-only construct, ...).

8. **Update state**:
   ```
   python3 .agents/skills/upstream-sync/scripts/sync_helpers.py mark-synced <upstream-tip-hash>
   python3 .agents/skills/upstream-sync/scripts/sync_helpers.py record '<json>'   # conflict notes
   ```
   Then make the small trailing "ledger sync" commit (ledger/meta/hotzones
   files only, message format in references/sync-protocol.md).

9. **Final report**: commits merged, hot-zone conflicts and how they resolved,
   reverts re-applied, parity gate result, remaining follow-ups (e.g. upstream
   changes needing an in-game look). Remind: nothing was pushed.

## Additional resources

- `references/sync-protocol.md` — conflict-resolution rules, skip re-revert
  mechanics, ledger-sync commit format.
- `references/ledger-schema.md` — ledger entry fields and worked examples.
- Shared state: `.agents/upstream-merge/` (ledger, hotzones, reviews) — see
  `.agents/skills/README.md`.
