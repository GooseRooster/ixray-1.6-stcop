# Agent Skills — IX-Ray 1.6 STCOP (Old World fork)

Four agent-agnostic skills for keeping this fork healthy while it absorbs
upstream improvements and accumulates Old World features. Discovered natively
by opencode from `.agents/skills/` (also usable from any other harness or a
plain terminal).

## The model in one paragraph

Upstream (ixray-team) is **merged wholesale**; the ledger records the
*exceptions* — commits we deliberately skip, each carrying our revert hash,
re-applied after every merge. The fork's deliberate divergence (cross-compile
work + OW ports) is the **hot-zone set**, derived at runtime from
`git diff upstream/default...HEAD` plus a hand-curated registry — syncs and
reviews flag hot-zone hits as the conflict surface. Every sync and every port
exits through the **parity gate** (cross build + clangd DB + hazard scan),
because the thing that makes this fork valuable — building the playable game
from Linux — is exactly what upstream changes can silently break.

## Skills

- **`upstream-sync`** — fetches, classifies the incoming batch, merges
  `upstream/default`, re-applies recorded skips, runs the parity gate, updates
  the ledger. The only git-mutating skill (beyond `port-ow-feature`'s in-repo
  porting work). Plan-mode approval before every merge; never pushes.
- **`upstream-review`** — read-only deep dive of the incoming batch, grouped
  by subsystem theme, writing dated reports with structured flags
  (cross-compile hazards, expected hot-zone conflicts, playtest reminders).
  Advisory; sits before sync, doesn't gate it.
- **`port-ow-feature`** — ports an Old World feature from xray-monolith into
  this engine: research → architecture mapping → plan-approved implementation
  → parity gate → hot-zone registration → gamedata dependency report. Never
  writes into the private repos.
- **`verify-parity`** — the shared gate. Standalone-runnable; the exit
  criterion for the other two.

## Shared state (`.agents/upstream-merge/`)

| Path | What it is |
|---|---|
| `ledger/ledger.jsonl` | Skip/conflict/review notes, hash-keyed. Schema: `upstream-sync/references/ledger-schema.md`. |
| `ledger/meta.json` | Upstream remote/branch + last fully-synced upstream hash. |
| `hotzones.jsonl` | Hand-curated hot-zone registry (globs); unioned with the runtime fork-vs-upstream diff. |
| `reviews/<theme>-<date>.md` | Written by `upstream-review`. |
| `paths.local.json` | **Gitignored, machine-local**: absolute paths to the private repos (oldworld, `_GAME/`, xray-monolith). Schema: `paths.local.json.example`. |
| `.cache/` | Runtime caches (gitignored). |

**Privacy rule**: `paths.local.json` is the only place private absolute paths
may appear. Tracked files use repo-relative paths only;
`sync_helpers.py record` mechanically rejects entries leaking a private root.

## Typical flow

```
upstream-review (batch looks big) → upstream-sync → verify-parity (inside sync)
port-ow-feature (as OW features are scheduled) → verify-parity (inside port)
```

## Running the scripts yourself

All scripts are stdlib-only Python; none of them mutate git (that happens
inside the skills, after plan approval):

```
python3 .agents/skills/upstream-sync/scripts/sync_helpers.py pending
python3 .agents/skills/upstream-sync/scripts/sync_helpers.py hotzone
python3 .agents/skills/upstream-sync/scripts/sync_helpers.py render --verdict skip
python3 .agents/skills/upstream-review/scripts/review_helpers.py group
python3 .agents/skills/port-ow-feature/scripts/port_helpers.py resolve
python3 .agents/skills/verify-parity/scripts/parity_gate.py --skip-build
```

Read each skill's `SKILL.md` before using it — that file, not this README, is
the source of truth for the step-by-step flow. `references/` under each skill
holds the deeper protocol/schema detail.
