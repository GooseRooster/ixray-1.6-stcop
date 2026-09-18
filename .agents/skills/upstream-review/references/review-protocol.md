# Review protocol (report format and flags)

Reports live at `.agents/upstream-merge/reviews/<theme-slug>-<date>.md`,
created via `review_helpers.py write-report` and filled in by the agent.

## Structure

1. **Commits under review** — auto-listed hashes/subjects.
2. **Analysis** — per commit or per coherent group: what changes in engine
   terms, why upstream made it, and how it interacts with our divergence in
   the same files. Assume the reader will re-read this months later without
   the diff in front of them.
3. **Gotchas / flags** — the structured checklist (below), then a plain list
   of every flagged commit with its flag(s) and a one-line explanation.

## Flags

| Flag | Meaning | Consumer |
|---|---|---|
| `cross-compile hazard` | Diff contains a pattern from `verify-parity/references/hazards.md`, or depends on MSVC-only behavior. | `upstream-sync` must pre-empt or fix during merge |
| `hot-zone conflict expected` | Rewrites an area of our divergence; name file + both sides' intent. | `upstream-sync` plan's conflict list |
| `playtest reminder` | Behavior change worth an in-game look after landing. | Post-sync checklist |
| `behavior change` | User-visible or config-visible difference. | Post-sync checklist; sometimes OW gamedata implications |

Flags are checklist items (`- [ ] ...`), never just prose — `upstream-sync`
reads this section mechanically when drafting its plan.

## Scope discipline

Review explains the *incoming* batch. It does not propose porting monolith
features (that's `port-ow-feature`) and it does not decide syncs (that's
`upstream-sync` + the user). When a review session reveals a new persistent
hot-zone candidate (upstream change colliding with something we customized
that the derivation missed), propose `hotzone-add` to the user — never append
silently.
