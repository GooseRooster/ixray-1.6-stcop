# Port protocol (monolith → IX-Ray mapping, privacy, gamedata checklist)

## Structural mapping

| Old World / xray-monolith | IX-Ray 1.6 STCOP (this repo) | Notes |
|---|---|---|
| `src/xrGame` (Anomaly tree) | `src/xrGame` (unity build) | Same name, very different content: check what exists here before porting — many Anomaly-era fixes are already solved upstream |
| Engine-side spawn/class code inside xrGame | `src/xrServerEntities` | IX-Ray splits server entities out; verify where the class lives (`grep -r` first) |
| Renderers (R3/DX11 monolith mods) | `src/Layers/xrRender*` (R4 = xrRenderDX10 backend) | OW targets R4 only; custom DX11 work lands under `Layers/` |
| Lua exports / LuaJIT bindings | `src/xrScripts/exports/` | Bindings must match `luabind` usage here; OW scripts expect specific engine calls |
| Console commands | `src/xrEngine/xr_ioc_cmd.cpp` | Register OW commands with upstream's command table style |
| Config system (DLTX/DXML in monolith) | **not present here** | DLTX/DXML are OW hard requirements (see root AGENTS.md) — a port that needs them must either pull that engine feature too or land after it does |
| `gamedata/` distribution tree | `gamedata/` (in-repo subset; active tree is private `_GAME/`) | Engine never writes gamedata; report dependencies for the user to port mod-side |

Differences that bite: IX-Ray builds xrGame via UnityBuild (new .cpp files
must be picked up by `file(GLOB)` — casing matters!); PCH is disabled under
clang-cl (each source includes its own `stdafx.h`); `MASTER_GOLD` semantics
per config (root AGENTS.md).

## Privacy rules

- `paths.local.json` (gitignored) is the only place private absolute paths
  may live. Tracked files (reports, ledger, plans, code) use repo-relative
  paths only.
- This skill **never writes into the private repos** (`oldworld`,
  `xray-monolith`) and never runs git inside them. Gamedata-side porting is
  reported as a dependency list; the user executes it mod-side.
- Quoting private *content* (config values, script logic) in reports is fine;
  quoting private *locations* is not.

## Gamedata dependency checklist (report section of every port)

For each engine feature the port exposes, list mod-side expectations:

- [ ] config keys read (`system.ltx` sections, DLTX includes) — with types/defaults
- [ ] script API surface (new/changed exported functions; `lua_help.script` impact)
- [ ] console commands / launch flags
- [ ] shader/resources needed under `_GAME/gamedata/`
- [ ] launcher option sync (see oldworld AGENTS.md — `defaults_*.ltx` / `options_*.script`)

## Port quality bar

- Parity gate green (cross build + clangd DB + hazard scan).
- Files registered as hot-zones (`hotzone-add` per file).
- No upstream-regression risk: the port must not undo an upstream fix to make
  room for itself — if the OW feature conflicts with an upstream fix, surface
  it in the plan instead of silently diverging.
