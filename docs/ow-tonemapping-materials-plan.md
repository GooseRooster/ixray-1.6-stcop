# Old World → IX-Ray: Tonemapping & Materials Port — Action Plan

> Status: **active plan**. Raw findings and evidence live in
> `docs/ow-tonemapping-materials-research.md` (read side references there;
> repo-relative `oldworld:` / `xray-monolith:` prefixes = private repos).
> This document is the build order. Decisions are locked here; change them
> only via a new entry in the research doc + plan revision.

---

## 1. Locked decisions

| Topic | Decision |
|---|---|
| Naming | The ported output pipeline is **the tonemapping pipeline** — file `tonemapping.hlsli`, functions renamed semantically (`ApplyTonemap_World`, `ApplyTonemap_UI`, `HermiteSplineRolloff`, `ApplyColorGrading`, `ExpandSunLight`, …). HDR/PQ is one output branch, not the identity of the file. No `HDR10_*` naming carries over. |
| Engine naming | Only **new** engine code uses the new terminology; existing engine symbols stay untouched to limit hot-zone surface. |
| Stripping | **None.** Upstream PBR/IBL/SSLR stays dormant behind `USE_LEGACY_LIGHT`. `lut.dds`/CGIM systems are skipped in our compile path (dormant, not deleted). `gamma_apply` is bypassed by the new final stage, not removed. Rationale: upstream may ship things we want; minimize merge headaches. |
| Isolation | All OW-authored shader code lives in **new files** (`owa_*.hlsli`, `tonemapping.hlsli`). Existing shaders receive include + call-site lines only — each touched line justified. |
| H2 (gamma policy) | **No declamp sweep of upstream gamma logic.** Pipeline stays gamma-encoded (Push/PopGamma identity under `USE_LEGACY_LIGHT`, untouched). The tonemapper linearizes its input with **pure 2.2** at the final stage, like OW. Lighting math downstream of that point is accurate linear. **Verified against OW source**: monolith deleted Push/PopGamma outright (zero occurrences in its r3 tree) and its chain is gamma-encoded end-to-end with a single `pow(2.2)` at `HDR10_ToDisplay_World` input — our policy yields **identical numerics** because the IX-Ray functions are identity under legacy lighting; keeping them as no-ops is the zero-churn equivalent of OW's deletion. Deliberately gamma-space in both engines: deferred lighting (albedo×light, hemisphere, fog) and bloom space. Deliberately linear-space in both: grading, spline tonemap, exposure (post-pow-2.2). |
| Clamp sweep | **Audit-everywhere, edit-where-clipping.** Full inventory of `saturate`/`clamp` across `gamedata/shaders/d3d11/**` + engine-side clamps; removals only where a clamp clips HDR on an HDR-carrying path (see §4). |
| Auto-exposure | Neutralized OW-style (scale resolves to 1.0); luminance chain kept running. Spline handles all compression; prevents double-compression. |
| GTAO | Adapt IX-Ray's built-in GTAO (`gtao_render/gtao_filter`) to Dynamic Indirect Light. XeGTAO dropped. |
| def_hdr | Unified at **7.5** (OW value). |
| Wetness | Ported in the material phase, isolated in `owa_wetness.hlsli` for cheap removal if weather coupling disappoints. |
| Hires RTs | **Always on** — no `r4_hires_rts` cvar; RTs become FP16 unconditionally. |
| Launcher | Dropped everywhere; OW launcher is redone much later. |
| Feature parity | DOF/blur/nightvision/heatvision/TAA stay **IX-Ray's**; compatibility with the new pipeline is an explicit audit item. |
| Probe lighting | Ported **last**, named **Dynamic Indirect Light (DIL)** at shader/phase level; internal engine names keep upstream-style naming. |

---

## 2. Cross-cutting policies

- **Parity gate**: every phase exits through `verify-parity` (hazard scan +
  `ixray-build-win` + `ixray-clangd-db`). Shader files are gamedata (no
  cross-compile risk); every engine `.cpp` edit obeys include-casing/CRT/MSVC
  rules per root `AGENTS.md`.
- **Hot zones**: every touched file registers with the upstream-sync framework
  at phase end.
- **Standing parity-gate check**: *no new or unclassified SDR clamps on
  touched files* (consults the §4 inventory).
- **Shader-tree policy**: during the port phases, **all shader changes live in
  this repo's tracked `gamedata/shaders/d3d11/` only** — no `_GAME` mirror
  while the port work runs. This keeps every change materially testable on the
  CoP-based test bench (this repo + its gamedata). Merging the shader tree
  into the OW `_GAME` codebase is a **separate, later integration phase**,
  after the engine feature ports land and the OW codebase is IX-Ray ready.
- **Hazard ledger from the research doc** still applies: H1 (bloom space, P4),
  H2 (policy above), H3 (chain topology, P3), H4 (TAA reversible tonemapper,
  P3), H6 (casing/unity build), H7 (HDR collateral, P5), H8 (dead exposure
  clamp, P3), H9 (`rt_BackbufferLUT` misnomer — name kept, note only).

---

## 3. Phases

### Phase 1 — RT foundation + clamp audit

**Scope:** engine `r4_rendertarget.cpp` + full-repo clamp inventory.

1. **Unconditional FP16 RTs**: `rt_Color` (albedo), `rt_Surface`,
   `rt_Generic_1`, `rt_Bloom_1/2`, `rt_BackbufferLUT`. Everything already FP16
   stays. No new cvar. Albedo storage policy: linear-in-FP16 (gamma encode is
   applied by producers per the H2 policy; final policy detail resolved here).
2. **Clamp audit** (§4): classify all `saturate`/`clamp` in
   `gamedata/shaders/d3d11/**` (124 matches / 55 files at audit time) plus
   engine-side clamps (env boost, `gamma_apply`, RT writers).
   - Remove/adjust **in this phase** the output-clipping clamps whose paths
     already feed FP16 targets (seed example: `forward_base.ps.hlsl:96`
     Reinhard-style output clamp).
   - Guard clamps (gbuffer encode/decode, AO, blend weights, texcoord/sampler
     domain) — keep.
   - Sequenced final gates — left to the phase restructuring that stage
     (each listed in that phase's scope below).
3. Env-boost clamp conditionalization (SDR {1,1,1} vs HDR {10,10,10}) is
   **deferred to Phase 5** — the SDR pipeline keeps the 1.0 clamp.

**Exit:** parity gate; banding/highlight test scenes; inventory table complete.

### Phase 2 — Material seasoning + hemisphere

**Scope:** shader-only + small C++ binders. All new code in new files.

New files (in `gamedata/shaders/d3d11/`):
- `owa_material.hlsli` — terminator contrast (directional only),
  sqrt point-light attenuation + NdotL seam blend, Schlick metalness fresnel
  (`owa_metalness.h` behavior).
- `owa_hemisphere.hlsli` — hmodel rewrite: no-normal `hscale`,
  luminance/chrominance decoupling, `OWA_SunChrominanceSplit`
  (**stubbed against DIL until Phase 8**), `hemi_vibrance` → `hmodel_stuff.x`,
  cubemap mip policy by material.
- `owa_oklab.hlsli` — Oklab helpers + "texture contrast" blend
  (`tex_contrast`, `r__tf_contrast`).
- `owa_wetness.hlsli` — gloss boost, water-film Fresnel sheen,
  porosity albedo darkening.

Minimal call-site edits: `metalic_roughness_light.hlsli`,
`metalic_roughness_ambient.hlsli`, `combine_1.ps.hlsl`,
`common_defines.hlsli` (`def_gloss` 2/255 → 24/255 — playtest call),
`sload.hlsli`/`lod.ps.hlsl` gloss.

Engine touches: binders in `Blender_Recorder_StandartBinding.cpp`
(`hmodel_stuff`, `tex_contrast`), console var `r__tf_contrast`
(`xrRender_console.cpp`), weather-key reading (`hemi_vibrance`) in
`Environment*`. **PBR/IBL/SSLR untouched** (dormant).

**Exit:** parity gate; visual side-by-side vs OW screenshots; hot zones.

### Phase 3 — Tonemapping pipeline

**Scope:** new file + chain restructure + engine stage merge.

- New `tonemapping.hlsli` (ported from OW `hdr10.h`, renamed):
  `HermiteSplineRolloff` (BT.2408 knee), unified wrapper (Rec.709 luma +
  maxRGB hybrid, Oklab saturation blend), `ApplyColorGrading` (LogC block),
  `ExpandLight`/`ExpandSunLight` (incl. SDR 25% sun lift), light/particle
  expansion. HDR/PQ branch present but dormant until Phase 5.
- **End-of-chain tonemap**: `postprocess(.cm)` + `gamma_apply` merge into one
  tonemapper stage (engine: `r4_rendertarget_phase_pp.cpp` /
  `RenderTargetPhaseGamma.cpp`). `combine_2.ps.hlsl` loses `tonemap()`; bloom
  compose stays until Phase 4 replaces it.
- **Feature-compat audit (mandatory exit items)**:
  - TAA reversible tonemapper pair (`taa_render.ps.hlsl:38/43`) — update to
    match the new operator or restructure (H4).
  - CAS, `saturation/vignette/chromatic_aberration`, postprocess-CM now run
    pre-tonemap on HDR — audit assumptions per H3; minimal targeted edits.
- **Exposure neutralized**: `r4_rendertarget_phase_luminance.cpp` scale → 1.0
  (keep chain running); fix H8 dead clamp in `bloom_luminance_3.ps.hlsl`.
- Grading consolidation: our compile path skips `lut.dds` sampling and CGIM
  (dormant, no deletion); CM postprocess kept (gameplay effects, pre-tonemap
  in OW too).
- Engine: `cg_parameters`/`tonemap_parameters` binders + `r4_cg_*` console
  vars; **pure-2.2 linearization lives here** (H2 policy — no upstream
  declamp).
- Accum-side: `HDR10_Expand*` equivalents applied in accum shaders.

**Exit:** parity gate; A/B against OW SDR screenshots; compat audit signed off.

### Phase 4 — Kawase bloom

**Scope:** own phase; port + refactor + fix H1.

- New clean shaders: `bloom_extract.ps.hlsl` (soft-knee quadratic threshold,
  Rec.709 luma), `bloom_downsample.ps.hlsl` (Kawase dual-filter, parameterized
  D2→D32), `bloom_upsample.ps.hlsl` (9-tap tent + 4-tap cross, additive).
  Pyramid RTs FP16 (guaranteed by Phase 1).
- **Fix H1**: compose space made consistent — additive compose against
  full-range `s_image` is `scene + bloom * def_hdr * intensity` (distort and
  additive branches identical). `def_hdr` unified at **7.5**
  (`common_defines.hlsli`, `bloom_build.ps.hlsl`, luminance chain).
- Engine: `r4_rendertarget_phase_bloom.cpp` rewiring (pyramid loop), RT set
  for pyramid, `bloom_params` binder + `r2_bloom_*` cvars.
- Old IX-Ray separable-Gaussian path bypassed at the phase level, files left
  in place (no strip).

**Exit:** parity gate; bloom look A/B vs OW.

### Phase 5 — HDR output path

**Scope:** swapchain + UI + collateral (H7). HDR = the second output branch of
`tonemapping.hlsli`.

- Swapchain `R10G10B10A2_UNORM` + `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020`
  with G22_NONE_P709 fallback (port `dx10HW.cpp` logic into
  `Device_create_render_dx11.cpp` + backend present path). PQ encode already
  in `tonemapping.hlsli`.
- `ApplyTonemap_UI` on `hud_font/font2/hud3d/simple_color/yuv2rgb`; PDA path.
- `rt_secondVP`/UI RT 10-bit formats.
- Env-boost clamp conditionalization (SDR {1,1,1} / HDR {10,10,10}) — deferred
  from Phase 1, done here.
- MSAA force-off under HDR; screenshot path; particle HDR vertex path
  (`deffer_particle`/engine).
- `r4_hdr10_*` console surface; `defaults_video.ltx` values as reference.

**Exit:** parity gate + **Windows/Proton HDR display validation** (never trust
Wine builtin behaviors per root `AGENTS.md`).

### Phase 6 — Procedural sun/moon

**Scope:** own phase.

- Sun/moon disc rendering (port OW's procedural implementation as new files),
  intensity + dawn/dusk window cvars (`r4_hdr10_sun_*` equivalents — renamed
  HDR-neutral), binder touch.

**Exit:** parity gate; visual A/B.

### Phase 7 — DX11 static lighting

**Scope:** engine-heavy; becomes the OW lighting-style selector.

- `USE_STATIC_LIGHTING` + `STATIC_LIGHTING_QUALITY` (0/1/2) compile defines
  (`r4.cpp`), `rt_Lmap` (FP16: RGB indirect bounce, A sun occlusion),
  `static_lighting_compose()` + Blinn-Phong static specular in
  `combine_1.ps.hlsl` (via isolated `owa_static*.hlsli`).
- Selection UX = dynamic vs static lighting under R4/DX11 always (replaces
  OW's renderer selection). Console: `r4_lighting_style`,
  `r4_static_lighting_quality`.

**Exit:** parity gate; both lighting modes playtested.

### Phase 8 — Dynamic Indirect Light (DIL)

**Scope:** last; probe lighting renamed DIL.

- Engine port: `LightProbeGrid` (internal names keep upstream-style naming),
  `probe_lighting.hlsli` (new file), binder + console surface.
- Wire the Phase 2 hemi `SunChrominanceSplit` stub to real probe direction.
- Adapt IX-Ray GTAO (`gtao_render/gtao_filter.ps.hlsl`) to DIL output —
  XeGTAO dropped.
- Weather-side: `_GAME` weathers already carry the keys; additive keys work
  unchanged on this engine (D8).

**Exit:** parity gate; A/B + brightness/sky-exposure playtest.

---

## 4. Clamp inventory

**Method.** Audit every `saturate(`/`clamp(` in `gamedata/shaders/d3d11/**`
(124 matches / 55 files at audit time) + engine-side clamps (env boost,
`gamma_apply`, RT writers). Classify:

- **G — Guard**: gbuffer encode/decode, AO, blend weights, texcoord/sampler
  domain, fog factors. Keep.
- **O — Output-clipping on HDR-carrying path**: remove/adjust in Phase 1.
- **S — Sequenced final gate**: left alone until the phase restructuring that
  stage (listed below). Never forget these — they are the ones that clip to
  SDR if a phase is forgotten.

Seed entries (P1 audit continues from here):

| File:line | What | Class | Action phase |
|---|---|---|---|
| `forward_base.ps.hlsl:96` | Reinhard-style `saturate(c * rcp(1+c))` on forward-path output → `rt_Generic_0` (FP16) | O | **P1** |
| `forward_base.ps.hlsl:45` | `M.Sun = saturate(M.Sun * 2.0f)` — material property | G | — |
| `forward_base.ps.hlsl:46` | `PushGamma(saturate(M.Color))` — albedo encode | G | — |
| `forward_base.ps.hlsl:88` | fog factor | G | — |
| `gamma_apply.ps.hlsl:17` | final LDR gate `saturate(c * grading)` | S | P3 (stage replaced by tonemapper) |
| `postprocess.ps.hlsl:12-13` | `saturate(s_baseN.Sample)` sample clamps | S | P3 (stage restructure) |
| `taa_render.ps.hlsl:38/43` | reversible tonemapper pair (`saturate(c * rcp(1+c))` + inverse) | S | P3 (H4 operator swap) |
| `taa_render.ps.hlsl:145/183` | screen-position clamps | G | — |
| `common_functions.hlsli:186` | `saturate(image)` on luminance/bloom helper | O/S | audit P1 (feeds exposure/bloom) |
| `common_functions.hlsli:176` | bloom threshold clamp | S | P4 (bloom rework) |
| `combine_2.ps.hlsl:26` | `saturate(Color)` for `lut.dds` sample domain | G (dormant system) | — |
| `combine_1.ps.hlsl:48`, `metalic_roughness_ambient.hlsli:130` | fog factors | G | — |
| `accum_sun.ps.hlsl:48` | farshadow/hemi blend | G | — |
| engine `Environment*` boost() | SDR {1,1,1} env clamp | S | P5 |

Rules: every later phase re-consults this table; new clamps introduced by OW
ports get classified here; the parity gate fails touched files with
unclassified SDR clamps.

---

## 5. Gamedata-side dependencies (user ports into `_GAME/`; this repo never writes there)

- **P2**: `_GAME` weathers keep `hemi_vibrance` (already present);
  `r__tf_contrast` default in `defaults_video.ltx [video_basic_lighting]` +
  options script entry.
- **P3**: `options_lighting_settings.script` entries for `r4_cg_*`
  (exposure, contrast, contrast_middle_gray, saturation, brightness, gamma)
  and bloom (`r2_bloom_threshold/intensity/radius`); OW's
  `defaults_video.ltx [video_basic_lighting]` is the reference
  (`r4_cg_exposure=1.0`, `r2_bloom_threshold=0.5`, `r__tf_contrast=0.5`).
- **P4**: bloom cvar defaults (`r2_bloom_threshold=0.5` OW reference).
- **P5**: `[video_basic] hdr_enable`; `r4_hdr10_*` defaults
  (whitepoint_nits=800, colorspace=2, chroma_correction=0.1,
  light_expansion=1.25, particle_expansion=2.0, ui_nits=203, ui_saturation=0.5,
  pda_intensity=1.0 per OW defaults).
- **P7**: `lighting_style` + `static_lighting_quality` entries.
- **All phases**: shader-tree sync is **deferred** — port-phase shader work
  stays in this repo (`gamedata/shaders/d3d11/`); mirroring into `_GAME`
  happens in the separate later integration phase (see §2 shader-tree
  policy). The `_GAME`-side config/script dependencies above are captured now
  so the integration phase has its checklist ready.

---

## 6. Sequencing notes

- **Two-stage strategy**: port the custom engine features first (Phases 1–8,
  all testable on the CoP-based test bench with this repo's own gamedata),
  then port the OW game codebase as it stands as a separate body of work.
- Order is deliberate: RT ceiling (P1) → surfaces (P2) → the tonemapper (P3)
  → bloom against the final topology (P4) → HDR as second output (P5) →
  independent features (P6) → static lighting (P7) → DIL last (P8).
- Hemisphere's chroma split and wetness are the only P2 items with
  forward-dependencies (P8 probes, weather keys) — stubs documented at stub
  sites.
- If upstream evolves anything we're dormant-skipping, `upstream-review`
  re-evaluates before each sync — that's the payoff of the no-strip policy.
