---
name: port-ow-feature
description: Ports an Old World custom feature from the xray-monolith engine (or a spec) into this IX-Ray engine — researches the monolith implementation via the machine-local private repo paths, maps it onto IX-Ray's architecture, implements after plan approval, runs the verify-parity gate, and registers the touched files as hot-zones so future upstream syncs flag them
---

# Port an Old World feature (monolith → IX-Ray)

The migration direction: Old World runs on Anomaly's X-Ray Monolith today;
this engine (IX-Ray 1.6 STCOP fork) is the target. Features get ported
*targeted* — one feature or subsystem at a time — never wholesale. Every
successful port permanently extends the fork's divergence, so its files must
end up in the hot-zone registry.

**Privacy rule first**: the private repos' on-disk locations live in the
gitignored `.agents/upstream-merge/paths.local.json` (schema:
`paths.local.json.example`). Nothing you write into any *tracked* file may
contain those absolute paths. Reports and ledger entries reference private
content by repo-relative path only.

## Steps

1. **Resolve paths** (one-time `set-path` per machine if unset):
   ```
   python3 .agents/skills/port-ow-feature/scripts/port_helpers.py resolve
   ```

2. **Read the mod-side rules**: `<oldworld_repo>/AGENTS.md` — encoding rules
   (Windows-1251 for `configs/text/`), `_GAME/` is the active gamedata tree,
   R4-only rendering, DLTX/DXML/LuaJIT expectations. Engine work in this repo
   must not break those expectations.

3. **Research the feature** in the monolith repo: the implementation files,
   the commit history around them (what Anomaly/OW changed vs stock CoP), and
   the gamedata side in `_GAME/` (configs/scripts the feature reads — an
   engine port without its config surface is half a port).

4. **Map to IX-Ray architecture** — see `references/port-protocol.md` for the
   structural mapping (monolith's tree vs this repo's: xrGame unity build,
   xrServerEntities split, Layers/ renderers, xrScripts exports, console
   commands in `src/xrEngine/xr_ioc_cmd.cpp`, DLTX/DXML absence = may need
   porting too). Identify: target files here, engine-side dependencies,
   gamedata-side dependencies, and what IX-Ray already has that monolith
   lacked (don't port problems that are already solved here).

5. **Draft the port plan** and get it through plan-mode approval: files to
   create/modify, how the feature wires in, the gamedata dependencies list
   (for the user to handle mod-side), and the parity gate as the exit
   criterion.

6. **Implement** following this repo's rules (AGENTS.md): Windows x64
   cross-compile must stay green — no MSVC-only constructs
   (`__declspec(allocate(...))`, `/GL`-only assumptions), include paths must
   match on-disk casing exactly, `.rc` files stay UTF-8, CRT selectors stay
   CMake-owned.

7. **Parity gate**:
   ```
   python3 .agents/skills/verify-parity/scripts/parity_gate.py --base HEAD~<n> --head HEAD
   ```
   (winCross shell; fix everything it finds.)

8. **Register the divergence** — every engine file the port touched/created:
   ```
   python3 .agents/skills/upstream-sync/scripts/sync_helpers.py hotzone-add "<repo-relative-path>" \
       --reason "OW port: <feature>" --added-via port-ow-feature
   ```

9. **Final report**: what landed where, parity gate result, the gamedata-side
   dependency list (explicitly for the user to port into `_GAME/` — this skill
   never writes into the private repos), and a note that the files are now
   hot-zones for future syncs.

## Additional resources

- `references/port-protocol.md` — structural mapping monolith→IX-Ray, privacy
  rules, gamedata-dependency checklist.
- `.agents/skills/README.md` — shared state overview.
