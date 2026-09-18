# Sync protocol (upstream-sync execution details)

## Conflict resolution rules

- Never blanket `ours`/`theirs`. Every conflict is resolved by reading both sides.
- **Hot-zone files** (the incoming batch's `hot_zone_files`): our divergence
  usually wins on the *guard* (cross-compile compat, OW feature), upstream
  wins on everything around it. When upstream refactors an area we've guarded,
  re-express our guard in upstream's new shape rather than keeping our old
  block verbatim.
- **Non-hot-zone conflicts**: usually upstream renamed something on both
  sides or our merge base is old — take upstream's shape and re-apply any of
  our recent commits that touched the same lines (check
  `git log --oneline upstream/default...HEAD -- <file>` for our side).
- Record every resolution where both sides meaningfully survived as a ledger
  `conflict_note` (fields in ledger-schema.md).

## Skip re-revert mechanics

Ledger `skip` entries carry `revert_hash` (our commit that removed the
upstream change) or `revert_pending: true` (skip decided, revert not yet
created — the sync must create it: apply the skip by hand, commit, then update
the entry). After a merge:

```
python3 .agents/skills/upstream-sync/scripts/sync_helpers.py skip-reverts
git revert --no-commit <revert_hash>     # per entry
```

- Clean apply → the merge brought the rejected change back. Keep it staged;
  all re-applied reverts commit together as one "reapply upstream skips"
  commit: `Reapply upstream skips after sync <upstream-tip-short>` with a body
  line per entry (`<upstream-short>: <reason>`).
- Empty/conflicting revert → the area changed further. If upstream *fixed* the
  skip's reason, propose dropping the entry (user confirms; rewrite ledger by
  editing the file — it is append-oriented but revisions are allowed with a
  `revised_date` field). If it changed but the reason stands, resolve the
  revert by hand and note it.

## Ledger sync commit

The last commit of every sync session touches only
`.agents/upstream-merge/**` and is formatted:

```
ledger sync: upstream <upstream-tip-short> (<n> commits, <k> skips reapplied)
```

## When not to merge

- Parity gate unfixable within the session → `git merge --abort` (if still
  mid-merge) or reset `default` to the pre-merge commit; the ledger records
  nothing and the session ends with a report of the blocker.
- Never push `default` as part of this skill — the user decides when the
  synced state ships.
