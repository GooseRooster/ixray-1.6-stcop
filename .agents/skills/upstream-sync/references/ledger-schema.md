# Ledger schema (`.agents/upstream-merge/ledger/ledger.jsonl`)

One JSON object per line, append-oriented (revisions allowed: edit in place
and add `revised_date`). Entries are created by `upstream-sync` (skips,
conflict notes) and by ledger revisions after user-confirmed changes.

## Fields

| Field | Type | Meaning |
|---|---|---|
| `hash` | string | Upstream commit hash (full or 12-char prefix). Required. |
| `subject` | string | One-line commit subject (for `render` readability). |
| `date` | string | Upstream commit date (YYYY-MM-DD). |
| `verdict` | string | `skip` \| `conflict_note` \| `review_note`. Required. |
| `reason` | string | Why — required. Names the divergence area on conflict. |
| `revert_hash` | string | `skip` only: our commit that removed the change. Required unless `revert_pending: true`. |
| `revert_pending` | bool | `skip` only: revert not yet created. |
| `files` | [string] | Repo-relative paths the entry concerns. |
| `interest_category` | string \| null | `perf`/`modding`/`graphics`/`infra`/null at triage time. |
| `hot_zone` | bool | Whether the commit touched the hot-zone set at decision time. |
| `reviewed` / `review_date` / `review_flags` | — | Set by `upstream-review` when it looked at the commit. |
| `recorded_date` | string | When this entry was written. |

## Privacy

Entries must contain **repo-relative paths only** — never absolute paths from
`paths.local.json`. `sync_helpers.py record` mechanically rejects any entry
whose serialized form contains a configured private root.

## Worked examples

Skip (decided, revert exists):

```json
{"hash": "abc123def456", "subject": "Rewrite memory allocator",
 "date": "2026-08-02", "verdict": "skip",
 "reason": "Conflicts with our xrMemory init_seg layout; OW allocator port supersedes it",
 "revert_hash": "feedface1234", "files": ["src/xrCore/memory/xrMemory.cpp"],
 "interest_category": "infra", "hot_zone": true, "recorded_date": "2026-08-03"}
```

Conflict note (recorded during a sync):

```json
{"hash": "abc123def456", "verdict": "conflict_note",
 "reason": "Merge conflict in cmake/msvc.cmake: upstream added /Ot for Release, kept our clang-cl /fp:fast repair block intact",
 "files": ["cmake/msvc.cmake"], "recorded_date": "2026-08-03"}
```
