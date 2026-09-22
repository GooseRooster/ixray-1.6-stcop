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
   stays. No new cvar. Albedo storage policy (**resolved**): FP16 stores
   gamma-encoded values exactly as producers write them today (identity
   Push/PopGamma under legacy lighting) — same encoding as OW, more precision;
   no producer changes. (`rt_Normal` keeps R16G16B16A16_UNORM and R2/DX9-side
   RTs are untouched — not hot zones.)
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
3. Env-boost clamp: **dropped entirely** (audit found OW's `boost()` does not
   exist in this engine — no clamps to remove, and nothing to add: env colors
   above 1.0 are compressed by the spline in HDR anyway).

**Exit:** parity gate; banding/highlight test scenes; inventory table complete.

### Phase 2 — Material seasoning + hemisphere

**Status: implemented (2026-09-21).** Scope: shader-only + small C++ binders.
All new code in new files (`owa_material.hlsli`, `owa_hemisphere.hlsli`,
`owa_oklab.hlsli`, `owa_wetness.hlsli`).

Delivered:
- `DirectLightResponse()` (LUT response tuple: rgb=diffuse, a=specular) with
  Schlick metalness fresnel add and directional-only terminator contrast
  (`metalic_roughness_light.hlsli`; `DirectLight()` kept as an albedo-applied
  wrapper for the dormant forward/length-buffer paths).
- **Direct specular activated** (user decision): accumulator protocol now OW's
  — rgb = response × light color × shadow, alpha = specular response × shadow;
  albedo+gloss applied once in `combine_1` (`C = albedo.gloss × light`). IX-Ray's
  legacy direct lighting was structurally diffuse-only (`Ldynamic_color.w=0`);
  the OW composition makes direct specular live (required for the fresnel to
  land).
- OW sqrt point-light attenuation + NdotL seam blend in
  `ComputeLightAttention` (now takes NdotL; `accum_base.ps.hlsl` call site).
- OW's flora fix in `accum_base.ps.hlsl` (normal-lean toward light, gloss×0.5).
- `owa_hemisphere` in `combine_1`: no-normal hscale, luminance/chrominance
  decoupling, `hemi_parameters.x` vibrance, material-based cube mips,
  SunChrominanceSplit (**SH direction stubbed to zero — wired at P8/DIL**),
  wet gloss boost + water-film sheen.
- `tex_contrast` Oklab blend (`owa_oklab.hlsli`) in `combine_1`.
- Wetness: porosity albedo darkening in `combine_1` (`owa_wetness.hlsli`).
- `def_gloss` 2/255 → 24/255 (SoC glossy — playtest call).
- **Gloss semantics aligned to OW (post-P2 playtest finding)**: the legacy
  squaring of texture gloss (`Bump.x²`) and the multiplicative detail gloss
  (`×2·Detail.w`) are replaced by OW's **linear texture gloss + additive detail
  gloss** (`s_bump.x`, then `+ s_detailBump.x` / `+ s_detail.w`) in
  `sload.hlsli` (deffer_base/forward/lod paths) and `deffer_impl.ps.hlsl`
  (BmmD level geometry — base bump gloss now read additively; was ignored).
  Rationale: squaring crushed matte surfaces while the ×2 detail multiplier
  could push gloss >1 and over-amplify the razor-thin LUT specular response —
  prime suspect for the lamp-flare artifact. Visual expectation: matte
  surfaces slightly *more* sheeny than before (linear mid-range), hot detail
  spikes *smoothed*.
- Engine: `hemi_parameters` binder (vibrance/contrast/wet-surface from
  CurrentEnv) + `tex_contrast` binder registered globally in `r4.cpp`;
  `hemi_vibrance`/`hemi_contrast`/`wet_surface_factor` weather keys read +
  mixer-lerped (`Environment.h`/`Environment_misc.cpp`); `r__tf_contrast`
  cvar (`xrRender_console`).
- **Binder rename**: OW's `hmodel_stuff` (legacy `meatchunks_stuff` slot) is
  now `hemi_parameters` — same contents, semantic name.

Deferred from original P2 scope (re-cut):
- Multibounce colored AO (`compute_colored_ao`) → DIL phase (P8) — interacts
  with probe zone factors.
- `HDR10_Expand*` light expansion in accum shaders → P3 (tonemapper phase).
- OW's `plight_local_static` (R1-style static local lights) → static-lighting
  phase (P7).

**Exit:** parity gate PASS; visual A/B vs OW screenshots pending on the CoP
test bench (shaders compile at engine runtime — D3DCompile; validate in
Proton). Hot zones registered.

### Phase 3 — Tonemapping pipeline

**Status: implemented (2026-09-21).** Scope: new file + chain restructure +
engine binders.

- New `tonemapping.hlsli` (ported from OW `hdr10.h`, **all functions renamed
  HDR-neutral**: `ApplyTonemap_World`, `ApplyTonemap_UI`, `HermiteSplineRolloff`,
  `HermiteSplineUnified`, `HermiteSplineHDR`, `ApplyColorGrading`,
  `ExpandLight`/`ExpandSunLight`/`ExpandLightPointSpot`, `Luminance_*`,
  colorspace transforms). Uniform *slot* names (`hdr10_parameters*`,
  `cg_parameters*`) kept identical to OW for cross-repo diff-ability —
  documented in the file header. Colorspace matrices verbatim-verified.
  HDR/PQ branch present but dormant (engine binds `hdr10_on = 0`) until Phase 5.
- **End-of-chain tonemap**: `gamma_apply.ps.hlsl`'s body replaced by
  `ApplyTonemap_World` + deband (the final-stage merge; the legacy
  `rs_c_gamma/brightness/contrast` pass is superseded — engine `PhaseGammaApply`
  untouched, now-unused bindings harmless). `combine_2.ps.hlsl` lost its
  mid-chain `tonemap()` + `s_tonemap` sample; bloom compose stays until P4.
  `postprocess(.cm)` sample saturates removed (pp runs pre-tonemap on HDR).
- **Feature-compat audit results**:
  - TAA reversible pair — **kept unchanged**: it is self-contained
    (Lottes forward → resolve → inverse, self-cancelling, independent of the
    display operator). H4 resolved without churn.
  - CAS — **already self-inverse** (forward `×rcp(1+c)` per tap at
    lines 9-20, restore `x/(1-x)` at :64, same reversible-Reinhard pattern as
    TAA) — HDR-safe unmodified; runs pre-tonemap now (sharpening behavior in
    compressed space, playtest note).
  - `saturation/vignette/chromatic_aberration` — range-agnostic (no color
    clamps; masks only) — no edits.
  - postprocess-CM — kept (gameplay effects, pre-tonemap in OW too); its
    1D-LUT coordinate uses clamp-addressed sampling — HDR-safe.
- **Exposure neutralized**: `amount = 0` in
  `r4_rendertarget_phase_luminance.cpp` (MiddleGray → neutral; scale = 1.0);
  chain keeps running (`models_reflex_lens` HUD still reads it). H8 dead clamp
  fixed (assigned).
- Grading consolidation: our compile path skips `lut.dds` sampling and CGIM
  (dormant, no deletion); CM postprocess kept.
- Engine: `hdr10_parameters1/2/11` + `cg_parameters1/2` binders registered
  globally in `r4.cpp` (hdr10_on/pda bind 0 = SDR active / HDR dormant);
  console: `r4_cg_*` (exposure/contrast/middle_gray/saturation/brightness/gamma),
  `r4_hdr10_light_expansion`, `r4_hdr10_particle_expansion`, and the dormant
  HDR set (`r4_hdr10_whitepoint_nits`, `_ui_nits`, `_colorspace`,
  `_chroma_correction`, `_pda*`, `_ui_saturation`) — OW cvar names for config
  compatibility. **Pure-2.2 linearization lives in `ApplyTonemap_World`**
  (H2 policy — no upstream declamp).
- Accum-side: `ExpandSunLight` in `accum_sun` (SDR 25% sun lift),
  `ExpandLightPointSpot` in `accum_base`, `ExpandLight` on the sun-highlight
  blend in `combine_1`; particle HDR expansion ported into `particle.ps.hlsl`
  (dormant until P5).

**Exit:** parity gate PASS; A/B against OW SDR screenshots on the bench.
- **Playtest note (P2 finding)**: omni/spot lights (lamps) show harsh
  "blown-out flare" halos — the new direct specular feeds values >1.0 into the
  old mid-chain Reinhard + `gamma_apply` clamp, which clips instead of
  compressing. Expected pre-P3 state; the hermite spline's linear-knee
  passthrough + rolloff is the fix. Verify lamps specifically after P3; if
  still hot vs OW, retune via `def_gloss` (note: `r2_gloss_factor`/`L_spec` is
  now inert for direct specular — the response protocol ignores
  `Ldynamic_color.w`).


  ### Phase 3.5 — Lamp/omni light artifact investigation (BLOCKS Phase 4)

**Priority: fix properly before starting Phase 4 (Kawase bloom) — the bloom
phase must not be built on top of an unresolved compose-path defect.**

**Symptom (user report, CoP test bench, Skadovsk lamps):**
- Omni/spot lights produce harsh "deep fried" flares: saturated chroma halos
  hugging the light volume, plus small "separator" artifacts where the grille
  mesh surrounding a bulb meets the light volume.
- Persists with bloom disabled (bloom only reacts to the data, not the cause).
- Strongly chroma-dependent: saturated orange lamps affected most, white
  point lights less — consistent with a saturation-amplifying path.
- Transient component: white lights briefly emit *flickers of garbage in
  crazy saturated colors* (user suspects near-infinite values) — frame-varying,
  visible in debug modes 6 (albedo × light) and 7 (compose luminance heatmap),
  near-constant in normal render.

**Ruled out (verified, not guesswork):**
- NaN/Inf in G-buffer albedo/gloss/hemi/material — detector mode 8 clean.
- NaN/Inf in compose result, accumulator (rgb+a), hemisphere terms — mode 9 clean.
- Direct LUT specular magnitude — engine LUT bake reproduced in Python; spec
  response ≤ 0.035 at hotspots; contribution ~0.2% of lamp color.
- Stale G-buffer at shell pixels — omni passes are stencil-gated to
  geometry-rendered pixels.
- Stale `Ldynamic_color` at combine — engine rebinds the adapted sun
  (`sunclr`/`sundir`) before `combine_1` renders.
- Volumetric/mask-path alpha pollution — `SE_MASK_ACCUM_VOL` is R2-only; R4
  volumetrics merge RGB-only into `rt_Generic_2`.
- Bloom as the source (persists with bloom off).

**Fixed during the investigation (kept):**
- Gloss semantics aligned to OW: linear texture gloss + additive detail gloss
  (`sload.hlsli`, `deffer_impl.ps.hlsl`); BmmD base-bump gloss now read.
- Hemisphere ambient binder compensation: was 0.6× OW (lumscale_amb baked);
  now exact via `L_lumscale` uniform.
- `r2_sun_lumscale*` defaults → 1.0 (OW parity).
- Debug harness `r__debug_combine` modes 1–9 (remove after investigation,
  see Phase 9).

**Key insight from the last debug round:**
All magnitude-viewing modes (1–5) wrap their output in `saturate()` — a
huge-but-finite value displays as flat white and reads "clean". Mode 7
(heatmap, red = luminance > 2.5) *did* fire — so the transient garbage is
**huge-but-finite, not NaN**. The harness cannot currently display magnitude.

**Next steps (ordered):**
1. **Magnitude-preserving debug modes**: add modes showing `log2(1+value)` or
   ×0.01 views of `Light.rgb`, `Light.a`, `C.rgb`, `spec` — establishes which
   channel carries the transient magnitude spike.
2. **Chain bisection**: disable optional stages one at a time
   (`ps_r4_cas_sharpening 0`, AA off / TAA off, `r2_mblur 0`, DOF off,
   `r2_ls_bloom_* 0`) to bracket where the spike enters *after* `combine_1`
   (candidates: TAA history feedback on HDR values, CAS's inverse-map guard
   `rcp(max(1e-5, 1−x))` firing on near-saturated HDR pixels, mblur reading
   previous-frame garbage, postprocess `×2.0` brightness on HDR).
3. **Suspicious-magnitude audit**: the TAA Lottes pair and CAS both use
   `x/(1−x)`-style inverses guarded by epsilon — on values that approach the
   clamp, these produce ~1e4-1e5 amplifications (finite, but the exact
   "near-infinite flicker" profile). Verify against HDR-scale inputs.
4. When the writer is identified: fix at the source, remove the harness,
   re-run the visual A/B, then unlock Phase 4.


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
- ~~Env-boost clamp conditionalization~~ — **dropped** (see Phase 1 item 3:
  `boost()` doesn't exist here; HDR relies on the spline's compression of
  >1.0 env colors).
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
- From lmodel.h (sequenced in P2): `plight_local_static` (GRM R1-style local
  lights, no LUT/specular) and the `xmaterial` static-sun material selection
  in `accum_base` (`m = xmaterial` vs gbuffer `_P.w` under
  `USE_R2_STATIC_SUN`).
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


### Phase 9 — Cleanup & parity tweaks (standing register)

Small parity/cleanup items that surface during playtesting; executed as a
batch once the ported phases stabilize:

- **Lumscale defaults → 1.0** (OW parity; monolith defaults all three
  `r2_sun_lumscale*` cvars to 1.0 — done 2026-09-21). Note: with all
  lumscales at 1.0, the hemisphere's `L_lumscale`-based ambient compensation
  resolves to a clean ×1.0, and the old IX-Ray triple (1.1/0.95/0.6) is gone.
- **Remove the `r__debug_combine` harness** (console cvar + binder +
  `combine_1` debug block) after the lamp-artifact investigation closes.
- Sweep stale comments left by superseded values (e.g., `// 1.0f` markers
  that no longer match).
- Collected during playtests: any remaining small divergences found while
  A/B-ing against OW get queued here instead of ad-hoc fixes.

- **Two-stage strategy**: port the custom engine features first (Phases 1–8,
  all testable on the CoP-based test bench with this repo's own gamedata),
  then port the OW game codebase as it stands as a separate body of work.
- Order is deliberate: RT ceiling (P1) → surfaces (P2) → the tonemapper (P3)
  → **artifact investigation (P3.5, blocking)** → bloom against the final
  topology (P4) → HDR as second output (P5) → independent features (P6) →
  static lighting (P7) → DIL last (P8).
- Hemisphere's chroma split and wetness are the only P2 items with
  forward-dependencies (P8 probes, weather keys) — stubs documented at stub
  sites.
- If upstream evolves anything we're dormant-skipping, `upstream-review`
  re-evaluates before each sync — that's the payoff of the no-strip policy.

## 4. Clamp inventory

**Status: complete (P1 audit).** Every `saturate(`/`clamp(` in
`gamedata/shaders/d3d11/**` (124 matches / 55 files at audit time) + engine
clamps was classified. Headline: **no active-path output clamps feed FP16
targets** — the single O-candidate (`forward_base.ps.hlsl:96`) turned out to
be the deliberate Reinhard compression of the *offscreen reflection buffer*
(`USE_LENGTH_BUFFER` = SE_R2_REFLECTIONS only), which is fully dormant under
`USE_LEGACY_LIGHT`. Nothing to unclamp in P1; the value of the audit is the
locked classification below.

**Method.** Each match classified as:

- **G — Guard**: gbuffer encode/decode, AO, blend weights, texcoord/sampler
  domain, fog factors, material property scaling, UI/HUD LDR domain. Keep.
- **O — Output-clipping on HDR-carrying path**: remove/adjust. **None on
  active paths.**
- **S — Sequenced final gate**: left alone until the phase restructuring that
  stage. Never forget these — they are the ones that clip to SDR if a phase
  is forgotten.
- **D — Dormant (PBR-mode-only path)**: `USE_LEGACY_LIGHT` disables the whole
  subsystem (SSLR/offscreen reflections); no action while dormant.

### S-class register (each tagged with its action phase)

| Location | What | Action phase |
|---|---|---|
| `gamma_apply.ps.hlsl:17` | final LDR gate `saturate(c * grading)` | **P3 done** — body replaced by `ApplyTonemap_World`; the only deliberate final clamp now lives inside the spline's SDR branch (`saturate(tonemapped)` before sRGB encode, as OW) |
| `gamma_apply.ps.hlsl:19` → `common_functions.hlsli:186` | `deband_color()` — `saturate(image)` pre-dither | **P3 resolved** — now runs *post*-tonemap (final LDR stage), saturate harmless by construction |
| `postprocess.ps.hlsl:12-13`, `postprocess_cm.ps.hlsl:16-17` | `saturate(s_baseN.Sample)` sample clamps | **P3 done** — removed (pp runs pre-tonemap on HDR) |
| `taa_render.ps.hlsl:38/43` | Lottes reversible tonemapper pair | **P3 resolved** — kept unchanged (self-contained reversible pair, independent of the display operator) |
| `contrast_adaptive_sharpening.ps.hlsl:42/60` | CAS amplitude calc + output clamp | **P3 reclassified G** — CAS is self-inverse (forward per-tap `×rcp(1+c)`, restore `x/(1-x)`); HDR-safe unmodified |
| `bloom_luminance_3.ps.hlsl:55` | dead exposure clamp (result discarded — H8) | **P3 done** — clamp now assigned |
| engine swapchain path | presentation clamps HDR→B8G8R8A8 | P5 (HDR swapchain) |

### G-class (verified guards — abbreviated register, all verified in audit)

| Cluster | Files | Nature |
|---|---|---|
| Normal reconstruct/encode | `deffer_impl.ps.hlsl:53,72`, `sload.hlsli:109`, `metalic_roughness_base.hlsli:81,92` | octahedral/normal z |
| G-buffer material encode | `deffer_impl.ps.hlsl:132-133`, `forward_base.ps.hlsl:45-46`, `lod.ps.hlsl:28` | albedo/sun domain (albedo stays gamma-encoded per H2) |
| Fog factors | `combine_1.ps.hlsl:48`, `deffer_impl.ps.hlsl:152`, `forward_base.ps.hlsl:88`, `water*.ps.hlsl`, `accum_volumetric_sun.ps.hlsl:85`, `reflections.hlsli:265`, `sslr_temporal.ps.hlsl:115`, `common_functions.hlsli:221` | lerp factor 0–1 |
| AA machinery | `taa_render.ps.hlsl:145,183,187,197,207`, `smaa.hlsli:875,893,1102`, `fxaa.hlsli:378,387` (macros), `common_functions.hlsli:176` (R1-sequence alpha threshold for jitter) | position/UV/weight domain |
| AO | `ssao.ps.hlsl:78,81`, `ssao_blur.ps.hlsl:27`, `gtao_render.ps.hlsl:96,116,130,140,151`, `gtao_filter.ps.hlsl:84` | occlusion domain |
| Shadows | `shadow.hlsli:176,343`, `accum_sun.ps.hlsl:48`, `rain_patch_normal*.ps.hlsl` | shadow/falloff domain |
| Light shape | `metalic_roughness_light.hlsli:20,72,74,75`, `accum_volumetric.ps.hlsl:43`, `common_functions.hlsli:117` (spot edge) | attenuation factors |
| Screen-space spatial masks | `dof.hlsli:23-24`, `vignette.ps.hlsl:6`, `chromatic_aberration.ps.hlsl:7`, `ssao` spatial | 0–1 spatial factors |
| SSLR internals | `sslr_*.ps.hlsl` (AABB, fog, depth-delta, `sslr_filter.ps.hlsl:112` output) | D (dormant subsystem) |
| Reflection buffer | `forward_base.ps.hlsl:96`, `deffer_impl.ps.hlsl:159` | D (dormant; deliberate Reinhard into env cube) |
| Particles/fluid | `particle*.ps.hlsl`, `fluid_*.ps.hlsl` (2 commented matches in `fluid_common_render.hlsli:185,301` — dead comments) | fluid/soft-particle domain |
| HUD/UI shaders | `model_scope_*.ps.hlsl`, `model_exohealth.ps.hlsl`, `models_reflex_lens.ps.hlsl` (reads `s_tonemap` luminance — works after P3 since the chain keeps running) | UI LDR domain |
| `combine_2.ps.hlsl:26` | `saturate(Color)` for `lut.dds` sample domain | G (dormant system) |

### Engine-side register

| Location | Nature | Class |
|---|---|---|
| `Environment_misc.cpp` mixer `lerp()` (338-633) | only scalar domain clamps (rain density, angles, weights); **no color clamps** — env colors pass through unclamped | G (verified: research doc's "unconditional 1.0 env clamps" describes monolith's `boost()`, which does not exist here) |
| `Blender_Recorder_StandartBinding.cpp` env binders (308-425) | lumscale multipliers only, no clamps | G |
| `r4_rendertarget.cpp` LUM pool clear (127/255) | clear color domain | G |

Rules: every later phase re-consults this table; new clamps introduced by OW
ports get classified here; the parity gate fails touched files with
unclassified SDR clamps. OW's `boost()` env-clamp system is **skipped
entirely** — it does not exist in this engine and the HDR path compresses
>1.0 env colors via the spline.

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



