# Old World → IX-Ray: Retro Tonemapping & Material Pipeline — Research Document

> Status: **research output**. Superseded as build order by
> `docs/ow-tonemapping-materials-plan.md` (the §6/§7 drafts below were revised
> during planning — the plan doc is authoritative for scope and sequencing).
> Privacy: private repo content is referenced by **repo-relative path only**
> (`oldworld:...`, `xray-monolith:...` prefixes). No absolute private paths here.

---

## 1. Headline findings (the delta on one page)

1. **The material model is already aligned.** Both engines run the *same* stock
   X-Ray procedurally-baked 3D material LUT (128×256×4 `R8G8_UNORM`, identical
   `computeBRDF` curves: OrenNayar-like / Blinn-like / Phong-like / Metal). IX-Ray's
   live default is `USE_LEGACY_LIGHT = 1` (`gamedata/configs/engine_external.ltx`),
   i.e. the retro LUT Blinn-Phong path is **already what runs here**. Phase 1 is
   *seasoning, not a swap*: OW's deltas are terminator contrast, sqrt point-light
   attenuation, Schlick metalness fresnel, Oklab "texture contrast", and a heavily
   rewritten hemisphere model. IX-Ray's optional GGX/IBL/SSLR path is compiled out by
   default → **strip candidate**, consistent with OW's own graphics-simplification
   (which hard-deleted its PBR switch).

2. **The tonemapping is the real divergence.**
   - IX-Ray: *active* auto-exposure (3-pass luminance → 1×1 R32F adaptation texture)
     → **Reinhard-style rational curve** applied *mid-chain* in `combine_2.ps.hlsl`
     → `gamma_apply.ps.hlsl` writes the swapchain (its `saturate()` is the final LDR
     gate).
   - OW: auto-exposure **deliberately neutralized** (scale resolves to 1.0) → image
     stays HDR to the very end → **hermite spline rolloff** (ITU-R BT.2408-derived,
     hybrid luma/maxRGB with Oklab blending) applied in the final postprocess quad,
     with **always-on parametric color grading in ARRI LogC space** before it.

3. **IX-Ray is more HDR-ready than monolith was.** The accumulator, generic0/2, and
   the entire backbuffer chain (`rt_Back_Buffer`, `rt_Back_Buffer_AA`, `rt_Generic`)
   are already `R16G16B16A16_FLOAT`. Gaps for Phase 2: bloom RTs are 8-bit UNORM,
   `rt_BackbufferLUT` is `R10G10B10A2`, `gamma_apply` clamps, and the swapchain is
   `B8G8R8A8_UNORM` with **no** HDR colorspace hooks anywhere. IX-Ray also has
   render-scale + DLSS/FSR/XeSS upscalers (monolith lacks all of these) — an ally,
   not a victim, of the high-res-RT phase.

4. **Bloom differs structurally.** IX-Ray: separable Gaussian, 8-bit RTs,
   `def_hdr = 9.0`. OW: Kawase multi-scale pyramid (D2→D32, always FP16, "energy
   conservation"), soft-knee threshold, `def_hdr = 7.5`. OW carries a known space
   mismatch in its additive bloom compose (hazard H1) — decide whether to port the
   look or fix the bug.

5. **Color grading: 4 systems here, 1 there.** IX-Ray simultaneously has (a)
   texture-driven 3D LUT (`lut.dds` presence-gated), (b) `gamma_apply`
   brightness/contrast/gamma/balance, (c) classic postprocess color-map (CM), (d)
   CGIM compile-time tweaks. OW consolidated everything into one parametric LogC
   grading block + the spline, and deleted the operator menu outright. Phase 3 is a
   consolidation, not an addition.

---

## 2. Old World side (source of truth)

Shaders: `oldworld:_GAME/gamedata/shaders/r3/` (the `r3` folder **is** the R4/DX11
set; gamedata overrides the engine's shipped shaders). Engine machinery:
`xray-monolith:src/Layers/...`. OW git history is squashed; intent must be read from
`// OWA:` markers and the monolith repo's `PROJECT.md` +
`docs/graphics-simplification-{spec,plan}.md`.

### 2.1 Tonemapping — `hdr10.h` (the whole unified pipeline, 684 lines)

Pipeline (header comment): *sRGB Input → Linear → Color Grading → Hermite Spline
Tonemap → Output*. One curve for SDR **and** HDR.

Core rolloff (BT.2408-derived, knee at 50% of target output; linear passthrough
below the knee — this is what preserves the "flat, raw retro STALKER look"):

```hlsl
float HDR10_HermiteSplineRolloff(float input, float target_white, float max_white)
{
    if (input <= 0.0) return 0.0;
    float e1 = input / max_white;
    float max_lum = target_white / max_white;
    float knee_normalized = 0.5 * max_lum;
    float knee_input = knee_normalized * max_white;
    if (input <= knee_input) return input;          // linear passthrough
    float t  = saturate((e1 - knee_normalized) / (1.0 - knee_normalized));
    float t2 = t*t;  float t3 = t2*t;
    float h00 =  2.0*t3 - 3.0*t2 + 1.0;
    float h10 =      t3 - 2.0*t2 + t;
    float h01 = -2.0*t3 + 3.0*t2;
    float m0  = 1.0 - knee_normalized;               // tangent matches linear slope
    float e2  = h00*knee_normalized + h10*m0 + h01*max_lum;
    return min(e2 * max_white, target_white);
}
```

- **`HDR10_HermiteSpline_Unified`**: evaluates the spline twice — on Rec.709
  luminance (`{0.2126390, 0.7151687, 0.0721923}`; P3/2020 variants per
  `hdr10_parameters2.x`) and on max-channel — then blends by pixel saturation with
  **Oklab interpolation** (`smoothstep(0.1, 0.5, sat)`): preserves hue of saturated
  highlights without the channel-flattening of pure maxRGB.
- **`HDR10_HermiteSpline_HDR`** (HDR-only): adds BT.2390 Annex-1 chroma correction
  above the knee (`hdr10_parameters2.z`, ratio cap 4.0).
- **`HDR10_ToDisplay_World()`** — the only world tonemap call site (invoked from
  `postprocess.ps` / `postprocess_cm.ps`, the final quad):
  `max(0)` → sRGB→Linear (pow 2.2) → **color grading** →
  - SDR: `saturate(HermiteSpline_Unified(color, 1.0, max_input=20.0))` →
    Linear→sRGB. That `saturate` is the *only* deliberate final clamp.
  - HDR: colorspace → P3/2020 → `HermiteSpline_HDR(color, whitepoint_nits/80, 20.0)`
    → Rec.2020 → **PQ (ST.2084) encode**.
- **UI path** (`HDR10_ToDisplay_UI`): no tonemap; PQ-encoded at
  `HDR10_UI_NITS_SCALAR`, saturation-blended vs alpha. Call sites:
  `hud_default.ps`, `font.ps`, `hud_font.ps`, `simple_color.ps`, `yuv2rgb.ps`; 3D
  PDA gets a separate non-tonemap path (`HDR10_IS_RENDERING_PDA`, `ps_r4_hdr10_pda`).
- **Legacy `tonemapping.h`** (Uncharted2 operator, `tnmp_*` uniforms) is dead code —
  nothing includes it; OW's postprocess consolidation comment says so explicitly.
- **Light expansion** (pre-tonemap headroom injection, HDR-only except sun):
  `HDR10_ExpandLight` (smoothstep 0.6–0.9 lum, +0.5×expansion),
  `HDR10_ExpandLight_PointSpot` (+0.75), `HDR10_ExpandSunLight_WithSDR` — HDR: full
  expansion; **SDR: 25% stylized lift** (`smoothstep(0.4,0.85)*0.25`) so the sun
  "pops" without HDR. Applied in the accum shaders.

### 2.2 Exposure — present but neutralized

- Engine: `xray-monolith:src/Layers/xrRenderPC_R4/r4_rendertarget_phase_luminance.cpp`
  — 3-pass chain (64² FP16 → 8² FP16 → 1×1 `R32F` pool), adaptation
  `f = .9*prev + .1*dt*ps_r2_tonemap_adaptation` — but `MiddleGray` is lerped to
  neutral `(1, 0, 1)` and `amount = 0` ("OWA: r2_tonemap legacy auto-exposure is now
  disabled"), so the scale resolves to 1.0.
- Shader: `common_functions.h: extract_bloom_graded()` ignores `s_tonemap` entirely —
  "Skip eye adaptation entirely — Hermite spline handles all compression. This
  prevents the double-compression issue where r2_tonemap clips highlights before
  bloom is added."
- Console vars (`r2_tonemap_*`) still exist but are inert.
- **Neutral-by-design**: an earlier 9-operator menu (ACES, AgX, Uchimura,
  Uncharted2, Extended Reinhard…) was **deleted, not defaulted** (per monolith
  `PROJECT.md`).

### 2.3 Color grading — always on, SDR + HDR (`hdr10.h`)

`HDR10_ApplyColorGrading_Rec709`: brightness add → `pow(c, 1/CG_GAMMA)` →
`* CG_EXPOSURE` → **contrast in ARRI LogC space** (full LogC constants:
`cut=0.011361, a=5.555556, b=0.047996, c=0.244161, d=0.386036, e=5.301883,
f=0.092814`) around `CG_CONTRAST_MIDDLE_GRAY` → saturation via Rec.709-luma lerp.
Contrast runs in LogC "specifically so contrast doesn't clip/crush before
tonemapping".

### 2.4 Materials ("retro charm")

- **BRDF = vanilla GSC material LUT.** `lmodel.h: compute_lighting()`:
  `s_material.Sample(smp_material, float3(dot(L,N), dot(H,N), mat_id)).xxxy` (rgb =
  diffuse response, a = specular). LUT baked at startup in
  `r4_rendertarget.cpp:1060-1230`; **`R8G8_UNORM` in SDR, `R16G16_FLOAT` in HDR10**
  (preserves specular > 1.0).
- **OW seasoning on top:**
  - Schlick metalness fresnel (`owa_metalness.h`:
    `fresnel*(0.01 + metalness*0.04)*sqrt(lum)`) added to `light.a`.
  - "Terminator contrast" on directional light only:
    `lerp(0.80, 1.0, smoothstep(0.0, 0.25, saturate(dot(N,L))))` — sharpens the
    light/shadow boundary, a SoC look.
  - Soft sqrt attenuation for point lights
    (`att = saturate(1-sqrt(rsq*range_rsq)); att *= att;` + NdotL seam blend).
  - `plight_local_static` — pure R1 lambertian for static-lit geometry (no LUT, no
    specular).
  - `def_gloss = 24.0/255.0` — "OWA: SoC style - glossy surfaces".
- **Hemisphere (`hmodel.h`, 432 lines, heavily rewritten):**
  - `hscale = h` — classic deferred style, **no normal influence** (SoC/CS behavior;
    the `.5+.5*n.y` form is commented out).
  - Luminance/chrominance decoupling: cubemap normalized to unit luminance for
    chroma; brightness from weather `L_hemi_color * L_lumscale.y * 2.0`;
    `hemi_vibrance` weather key → `hmodel_stuff.x`.
  - `OWA_SunChrominanceSplit`: blends hemi chroma toward sun or sky chroma by
    surface facing + probe direction.
  - Diffuse cubemap mip by material (`m<0.5 → mip7`, else lerp 4→0); specular mip
    `(1-saturate(m*1.5))*6`; classic `vreflect.y*2-1` remap.
  - Wetness (`owa_wetness.h`): gloss boost toward 0.85, water-film Fresnel sheen,
    porosity-based albedo darkening (metals −80%).
  - Probe GI adds `gi_color`/`chrominance_tint` (`probe_lighting.h`, engine
    `LightProbeGrid`). SSPE was removed by the simplification plan.
- **PBR is dead code in OW**: `pbr_brdf.h`/`pbr_brdf_ggx.h` compiled in but
  unreferenced (only `specAA_rough_env` used); `r4_material_style` console switch
  already deleted; `st_opt_classic` hardcoded.
- **Retro "texture contrast"** (`combine_1.ps`, Build 3120 style): `tex_contrast.x`
  uniform (console `r__tf_contrast`, default 0.5):
  `contrast = hdiffuse * (D.rgb*0.60 + 0.40)` blended in **Oklab** (`owa_oklab.h`,
  master kill-switch `OWA_OKLAB_MASTER_ENABLE`).
- **Static-lighting (R1 retro) path** in `combine_1.ps`: lightmap composition
  `static_lighting_compose()` + Blinn-Phong `pow(saturate(dot(R,V)), 32)` specular +
  Oklab contrast.

### 2.5 Bloom + output chain (OW render flow)

1. G-buffer (position/normal/color) + deferred accum into `rt_Accumulator` (FP16,
   light × LUT BRDF; accum shaders apply `HDR10_Expand*`).
2. `phase_combine` → `combine_1.ps` (MRT → `rt_Generic_0` + `rt_Generic_1`): fog,
   probe GI, hemisphere, multibounce AO, wetness, contrast →
   `extract_bloom_graded()` → **low = full-range rgb (alpha = skyblend)**,
   **high = rgb/def_hdr** with `def_hdr = 7.5` ("reduced to LA levels").
3. `phase_bloom`: `bloom_build.ps` extracts from `rt_Generic_1` (soft-knee quadratic
   threshold, Rec.709 lum) → Kawase 5-tap downsample D2→D32 (always FP16) → 9-tap
   tent + 4-tap cross additive upsample → final bloom = `rt_Bloom_D2` (in `/def_hdr`
   space). Old `hdr10_bloom`/lens-flare phases are dead code.
4. `combine_2_naa/aa.ps`: motion blur, deband (sky only),
   `combine_bloom(img, bloom, intensity)` = `scene + max(0,bloom)*intensity`.
   **No tonemapping here** (removed). ⚠ Known space mismatch: bloom is in `/def_hdr`
   space, `s_image` is full-range; the additive path adds them directly (the distort
   branch scales by `def_hdr`, the additive one doesn't).
5. Optional DOF/blur/nightvision/heatvision/SMAA/TAA.
6. `phase_pp()` → `postprocess.ps`/`postprocess_cm.ps` → backbuffer: game
   post-process (duality/noise/brightness) → **`HDR10_ToDisplay_World`** (grading +
   hermite spline + sRGB or PQ encode).

Clamp inventory (OW): `combine_1` only `max(0, …)` (negatives only); env colors
clamped to 1.0 (SDR) / 10.0 (HDR) engine-side; LUT specular 8-bit in SDR; final
`saturate` in the SDR branch; `min(e2*max_white, target_white)` inside the spline.
Sky has **no tonemap** (HDR-only 1.4× perceptual "pop").

### 2.6 Engine machinery (monolith C++)

- **RT formats** (`r4_rendertarget.cpp:520-955`): two master switches —
  `o.dx11_hdr10` (`r4_hdr10_on`) and `o.hires_rts` (`r4_hires_rts`, **16-bit RTs
  even in SDR**). `use_hires = hdr10 || hires_rts`:
  - `rt_Color` (albedo): FP16 if hires/hdr10 else `A8R8G8B8`
  - `rt_Accumulator`, `rt_Position`: FP16 always
  - `rt_Generic_0/1`, temp, MSAA variants, `rt_dof`, blur chain, `rt_Bloom_1/2`,
    SSFX prev-frame/IL: FP16 if hires else 8888
  - Bloom pyramid D2…D32: **FP16 always** ("energy conservation")
  - `rt_secondVP`/`rt_ui_pda`: **`A2R10G10B10` if hdr10**, else 8888
  - Luminance chain + GTAO/SSFX TAA/motion/accum/volumetric: FP16 always
  - `rt_Lmap` (static lighting): FP16 (RGB = indirect bounce, A = sun occ)
- **Uniform binders**
  (`xray-monolith:src/Layers/xrRender/Blender_Recorder_StandartBinding.cpp:1136-1277`):
  `hdr10_parameters1` = (whitepoint_nits, ui_nits/whitepoint, hdr10_on, pda);
  `hdr10_parameters2` = (colorspace, pda_intensity, chroma_correction, ~unused~);
  `cg_parameters1` = (exposure, contrast+1, saturation+1, contrast_middle_gray);
  `cg_parameters2` = (brightness, 1/gamma, ~flare~, ~flare~);
  `hdr10_parameters11` = (~knee~, light_expansion, particle_expansion, ~unused~);
  `tex_contrast` = `ps_r__tf_contrast`; `bloom_params` = (threshold, intensity,
  radius, 0); `L_lumscale` = sun/hemi/amb.
- **Console vars** (`xrRender_console.cpp`), engine defaults:
  `r4_hdr10_on=0`, `r4_hires_rts=0`, `r4_hdr10_whitepoint_nits=400` (10–10000),
  `r4_hdr10_ui_nits=400`, `r4_hdr10_pda_intensity=1.0`, `ps_r4_hdr10_pda=0`,
  `r4_hdr10_colorspace=2` (Rec.2020; 0–2), `r4_hdr10_chroma_correction=0.6` (0–1),
  `r4_cg_exposure=1.0` (0.1–30), `r4_cg_contrast=0.0` (−1..1),
  `r4_cg_contrast_middle_gray=0.5`, `r4_cg_saturation=0.0` (−1..1),
  `r4_cg_brightness=0.0` (−1..1), `r4_cg_gamma=1.0` (0.1–5),
  `r4_hdr10_ui_saturation=0.0`, sun/moon: `r4_hdr10_sun_on=0`, `sun_intensity=80`,
  `moon_intensity=5`, dawn/dusk windows, `r4_hdr10_light_expansion=1.0`,
  `particle_expansion=1.0`; bloom: `r2_bloom_threshold=1.5` (0.5–4.0),
  `r2_bloom_intensity=1.0`, `r2_bloom_radius=1.0`; `r__tf_contrast=0.5`;
  `r4_lighting_style=st_opt_dynamic`, `r4_static_lighting_quality`.
  (Note: `_GAME` `defaults_video.ltx` values differ and win on fresh installs — e.g.
  `whitepoint_nits=800`, `chroma_correction=0.1`, `light_expansion=1.25`,
  `hires_rts=true`.)
- **Env boost clamping** (`xray-monolith:src/xrEngine/Environment_misc.cpp:611-673`):
  `CEnvDescriptorMixer::boost()` clamps env colors (sky/clouds/ambient/hemi/sun/
  rain/fog) to **{1,1,1} in SDR vs {10,10,10} in HDR**. Also reads weather keys
  `hemi_vibrance`/`hemi_contrast` and `fog_auto_blend` → `hmodel_stuff`.
- **HDR output** (`dx10HW.cpp:474`): swapchain `R10G10B10A2_UNORM` when hdr10 else
  `R8G8B8A8`; colorspace `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020` (falls back
  to G22_NONE_P709 with log). Shader does the PQ encode. **MSAA force-disabled
  under HDR10** (`o.dx10_msaa = ps_r3_msaa && !o.dx11_hdr10`). **Screenshots
  disabled under HDR10** (`r__screenshot.cpp`). Particles have an HDR vertex path
  (`ParticleEffect.cpp`, `dwDecl_LIT_HDR`).
- Shader compile defines from C++ (`r4.cpp:1400-1960`): `USE_R2_STATIC_SUN`,
  `USE_STATIC_LIGHTING` + `STATIC_LIGHTING_QUALITY` (0/1/2), `USE_GTAO`,
  `SSAO_QUALITY`, `USE_PROBE_LIGHTING`.

### 2.7 OW gamedata config surface

- `_GAME/gamedata/configs/plugins/defaults/defaults_video.ltx`:
  `[video_basic]` (`hdr_enable`, `lighting_style`, `static_lighting_quality`, `fov`,
  `hud_fov`, `screen_mode`), `[video_advanced_main]` (`hires_rts = true`,
  `ssao_mode`, `sunshafts_mode`, `smaa`, DOF/mblur keys, …), `[video_basic_lighting]`
  (all `r4_cg_*`, `r2_bloom_*`, `r__tf_contrast`, `r4_hdr10_*` values above).
- Option scripts: `options_lighting_settings.script` (MCM "Lighting" page, tag
  `hdr10`), `options_video_advanced_main.script` (`hires_rts` checkbox, restart
  required, R4-only), `owa_graphics_init.script` (hardcoded SSFX defaults).
- Weather: OW-custom `w_oldworld_*.ltx` add per-hour **`hemi_vibrance`** (0 night →
  1 day) and **`fog_auto_blend`**; plus standard `ambient/hemisphere/sun/sky/
  fog_color`, `sun_shafts_intensity`, `water_intensity`, etc.
- Launcher sync obligation: launcher C# `OptionDefinitions` must match
  `defaults_*.ltx` + `options_*.script`.

### 2.8 OW's own specs (what exists on disk)

- `xray-monolith:PROJECT.md` ("Color grading, HDR and retro rendering options",
  lines 98–235) — the canonical design narrative: retro axis (lighting styles,
  static-lighting tiers, classic LUT materials) × modern axis (probe GI), HDR10
  pipeline, "axes are independent by design", debug modes.
- `xray-monolith:docs/graphics-simplification-{spec,plan}.md` — the *executed*
  debloat: removes probe bounce, SSPE, Perceptual Lighting, **PBR materials
  (hardcode `st_opt_classic`)**, screen-space sunshafts, SSFX fog, grass shadows,
  blood decals, gas-mask drops, `r2_auto_fog`; 12 SSFX MCM pages removed. "What
  stays": HDR10, Classic Materials, DX11 Static Lighting, XeGTAO, procedural
  sun/moon.
- `oldworld:.Codex/` and `oldworld:xray_monolith_engine_notes/` are referenced by
  the mod's `AGENTS.md`/deleted `PROJECT.md` but **do not exist on disk or in git
  history** — no Phase 1–4 port spec was ever committed. This document fills that
  gap.

---

## 3. IX-Ray side (current state)

R4-only. HLSL loaded from **`gamedata/shaders/d3d11/`** (`r4.h: getShaderPath() =
"d3d11\\"`, runtime `D3DCompile` in `r4.cpp`, cache under
`$app_data_root$\shaders_cache`). `gamedata/shaders/r2/` is DX9-only, unused here.
Global shader macros come from `gamedata/configs/engine_external.ltx`
`[shaders_options]` via `src/xrCore/EngineExternal.cpp`.

### 3.1 Tonemapping + exposure

- Operator — **Reinhard-style rational curve with white point**
  (`gamedata/shaders/d3d11/common_functions.hlsli`):

```hlsl
#define RCP_WHITE_SQR 0.34602f          // 0.416233f with USE_CGIM_WHITE_TWEAK
#define INV_TONEMAP_COEF_ONE 0.61592f
#define INV_TONEMAP_COEF_TWO 1.44565f

float3 tonemap(float3 rgb, float scale)
{
    rgb = rgb * scale;
    rgb = rgb * (1.0f + rgb * RCP_WHITE_SQR) * rcp(rgb + 1.0f);
    return PopGamma(rgb);               // pow(x, 1/2.2) unless USE_LEGACY_LIGHT
}
```

  `detonemap()` = inverse operator (used by sky/UI paths). `PushGamma/PopGamma` =
  pow 2.2 / 1/2.2 ⇒ the pipeline is **gamma-2.2-encoded HDR** in PBR mode, identity
  in legacy mode (hazard H2).
- Where: `combine_2.ps.hlsl` — `dof/mblur` → `tonemap(Color, s_tonemap)` →
  `combine_bloom` → optional `s_lut` sample → out. Bound by
  `src/Layers/xrRenderPC_R4/blender_combine.cpp` (`s_image = r2_RT_generic`,
  `s_bloom = r2_RT_bloom1`, `s_tonemap = r2_RT_luminance_cur`).
- Exposure: 3-pass log-average luminance (engine
  `r4_rendertarget_phase_luminance.cpp`; shaders `bloom_luminance_{1,2,3}.ps.hlsl`)
  → 1×1 `R32F` ping-pong pool → adaptation `lerp(prev, scale, adapt_speed)`.
  **Active auto-exposure**, controlled by `r2_tonemap_*` cvars.
  ⚠ **Dead clamp**: `bloom_luminance_3.ps.hlsl` computes
  `clamp(rvalue, 1/128, 20.0)` but never assigns the result — exposure range is
  unenforced.
- Optional operators (all off): `cgim.h` Uncharted2/ACES-style (CGIM2-compat,
  compile-time only), `USE_LEGACY_SKY_TONEMAP`.

### 3.2 Output chain (every stage, files)

1. G-buffer MRT (`rt_Color, rt_Normal, rt_Surface, rt_Velocity` + depth):
   `deffer_base.vs/ps.hlsl`, `deffer_impl.ps.hlsl`, `sload.hlsli`,
   `metalic_roughness_base.hlsli`.
2. Deferred accum → `rt_Accumulator` (FP16): `accum_sun.ps.hlsl`,
   `accum_sun_mask.ps.hlsl`, `accum_volumetric_sun.ps.hlsl`, `accum_base.ps.hlsl`,
   `accum_indirect.ps.hlsl`, `accum_emissive*.ps.hlsl`, `accum_volumetric.ps.hlsl`
   (blenders `blender_light_*`).
3. `combine_1.ps.hlsl` → `rt_Generic_0` (fog, ambient, hemi, reflections, SSAO; sky
   `sky_s0/sky_1`, env cubes; clouds before it via `clouds.ps.hlsl`).
4. Forward/volumetric → `rt_Generic_0` (`forward_base.ps.hlsl`,
   `combine_volumetric.ps.hlsl`).
5. Optional distortion: `combine_distort.ps.hlsl` → `rt_Generic_1` → copy back.
6. AA (if `ps_r_scale_mode<2`): FXAA/SMAA/TAA (`taa_render.ps.hlsl` uses a
   **reversible tonemapper** for resolve — operates on pre-combine_2 HDR).
7. Render-scale / upscaling: `r4_rendertarget_phase_scale.cpp` /
   `phase_{dlss,fsr,xess}.cpp` → `rt_Generic` (FP16, UAV). Scale presets 1.0–3.0
   supersample or raw 0.3–2.0; `vid_scale*` console.
8. Bloom from `rt_Generic`: `bloom_build.ps.hlsl` (threshold `b_params.x`,
   `PopGamma(s0..s3)/(2*def_hdr)`, `def_hdr = 9.h`) → `rt_Bloom_1` (8-bit!) →
   separable Gaussian `bloom_filter.ps.hlsl` X/Y. Luminance chain runs inside
   `phase_bloom`, feeding next-frame exposure.
9. `combine_2.ps.hlsl` (**tonemap + bloom**) → `rt_Back_Buffer` (FP16).
10. Lens flares: `effects_sun.vs.hlsl` (`effects_flare.lua`).
11. CAS sharpening (optional): `contrast_adaptive_sharpening.ps.hlsl`.
12. Optional screen post: `saturation.ps.hlsl`, `vignette.ps.hlsl`,
    `chromatic_aberration.ps.hlsl` (flags `R2FLAG_SPP_*`).
13. Game post-process `phase_pp()` → **`rt_BackbufferLUT` (`R10G10B10A2_UNORM`)**:
    `postprocess.ps.hlsl` / `postprocess_cm.ps.hlsl` (noise/duality/gray/color-map).
14. Final `PhaseGammaApply()` (`RenderTargetPhaseGamma.cpp` +
    `gamma_apply.ps.hlsl`) → swapchain:
    `contrast*pow(c,1/gamma)+brightness` → `saturate(c * color_grading.rgb)` (RGB
    balance) → deband dither. **This `saturate` is the final LDR gate.**

### 3.3 Color grading — four coexisting systems

1. **3D LUT (upstream feature)**: presence-gated on `shaders\lut.dds`
   (`$game_textures$` or `$level$`) in `blender_combine.cpp:56-75` → compile option
   `USE_LUT_TEXTURE` → sampled `s_lut.Sample(smp_rtlinear, saturate(Color))` after
   tonemap in combine_2. No config surface; no LUT ships in-repo (inactive).
2. **`gamma_apply`** brightness/contrast/gamma + RGB balance (`m_Gamma`, console
   `rs_c_gamma/brightness/contrast`), applied last, to the swapchain.
3. **Classic postprocess color-map** (`postprocess_cm.ps.hlsl` +
   `ColorMapManager.cpp`, driven by per-effect `pp_*` data, e.g.
   `gamedata/configs/postprocess/*`).
4. **CGIM2 compile tweaks** (`engine_external.ltx`:
   `USE_CGIM_{COLOR,BLOOM,WHITE,SKY}_TWEAK`).

### 3.4 Render target formats (`r4_rendertarget.cpp:495-544`)

| RT | Format | HDR? |
|---|---|---|
| `rt_Color` (albedo) | `R8G8B8A8_UNORM` | LDR |
| `rt_Normal` | `R16G16B16A16_UNORM` | LDR (unorm16) |
| `rt_Surface` | `R8G8B8A8_UNORM` | LDR |
| `rt_Velocity` | `R16G16_FLOAT` | — |
| `rt_Accumulator` | **`R16G16B16A16_FLOAT`** | HDR |
| `rt_Generic_0` (+`_prev` TAA) | **FP16** | HDR |
| `rt_Generic_1` | `R8G8B8A8_UNORM` | LDR |
| `rt_Generic_2` (volumetric) | **FP16** | HDR |
| `rt_Generic` (post-scale, UAV) | **FP16** | HDR |
| `rt_Back_Buffer` / `_AA` | **FP16** | HDR (post-tonemap) |
| `rt_BackbufferLUT` | `R10G10B10A2_UNORM` | LDR-ish |
| `rt_Bloom_1/2` (256²) | `R8G8B8A8_UNORM` | **LDR** |
| `rt_LUM_64/8`, `rt_LUM_pool[2]` | FP16 / `R32_FLOAT` 1×1 | chain |
| `rt_ssao_temp` R8, `rt_half_depth` R16, SMAA R8G8/R8G8B8A8, `rt_gtao_0` R32_UINT | — | — |
| SSLR set + `rt_Reflection` (256³ mipped) | FP16 | PBR-mode only |
| `t_material` | 3D `R8G8_UNORM` 128×256×4, baked in ctor | — |

- **No R11G11B10 anywhere**; everything HDR is RGBA16F.
- Swapchain: `B8G8R8A8_UNORM`, `DXGI_SWAP_EFFECT_DISCARD`, BufferCount 1
  (`Device_create_render_dx11.cpp`). **No `SetColorSpace1`, no HDR10/scRGB hooks.**
- Render-scale: `Device.RenderScale` presets {1.0, 1.5, 1.724, 2.0, 3.0} or raw
  0.3–2.0; core RTs at scaled res, backbuffer chain at native. DLSS/FSR/XeSS
  wrappers under `src/Layers/xrRenderPC_R4/OverlayAPI/`.

### 3.5 Material model

- Compile-time switch `USE_LEGACY_LIGHT` — **default 1** (retro LUT path live).
- **Legacy direct BRDF** (`metalic_roughness_light.hlsli:60-63`):
  `s_material.SampleLevel(smp_material, float3(NdotL, NdotH, Metalness), 0).xy` →
  `Radiance * (Material.x*Color + Material.y*Roughness*Radiance.w)` — the same
  tabulated stock X-Ray BRDF as OW (identical baked curves,
  `r4_rendertarget.cpp:762-834`).
- **Legacy ambient** (`metalic_roughness_ambient.hlsli:160-168`): LUT at
  `(Hemi, 0.5-0.5·dot(V,R), Metalness)` + env cubes; `Irradance *= Irradance` under
  legacy.
- **Modern path (optional)**: Cook-Torrance GGX + Smith + Schlick, split-sum IBL
  via mipped sky cube + `EpicGamesEnvBRDFApprox`, SSLR + offscreen reflections
  (only enabled when `USE_LEGACY_LIGHT` absent, `r4.cpp:204-210`). **Strip
  candidate** — OW deleted its equivalent outright.
- G-buffer: albedo+SSS / octahedral normal+roughness+snow / surface (metalness,
  hemi, AO, PBR flag) / velocity. Material ID from texture `.thm`
  (`ETextureParams.h`, `TextureDescrManager.cpp`) → `L_material` constant
  (`R_hemi::set_material`); per-texture PBR toggle `USE_PBR` from `.thm`.
  `def_gloss = 2/255` (vs OW's SoC-style `24/255`).
- No OW seasoning here: no terminator contrast, no sqrt attenuation variant, no
  metalness fresnel add, no Oklab contrast, no wetness, no hmodel luminance/chroma
  decoupling, no `hemi_vibrance` weather key.

### 3.6 Console/config surface (tonemap-relevant)

`src/Layers/xrRender/xrRender_console.cpp`: `r2_tonemap` (mask) + `_middlegray=1.0`
/ `_adaptation=3.0` / `_lowlum=0.01` / `_amount=0.7`; `r2_ls_bloom_*` (kernel
g/b/scale, threshold 0.1, speed, fast mask); `r2_gloss_factor=3.14`;
`r2_sun_lumscale/_hemi/_amb/_sky` = 1.1/0.95/0.6/1.2; `r2_dof*`; `r2_vignette`,
`r2_aberration`, `r2_saturation` (SPP masks); `r4_cas_sharpening`; SSLR/VSLR masks;
`r_aa` (off/fxaa/smaa/taa); `r2_ssao_mode`, `r2_sun_shafts`, `r2_smap_size`;
`r__tf_mipbias`, `r__tf_aniso`; debug `r2em`.
`src/xrEngine/xr_ioc_cmd.cpp`: `rs_c_gamma/brightness/contrast`,
`vid_scale_preset/vid_scale/vid_scale_mode`, `rs_v_sync`.
Config: `engine_external.ltx [shaders_options]` (USE_LEGACY_LIGHT etc.),
per-texture `.thm`, per-level `lut.dds`, env descriptors (ambient/hemi/sky/fog/sun).

---

## 4. Compare & contrast (per subsystem)

| Subsystem | Old World (monolith + _GAME) | IX-Ray 1.6 (this repo) | Port direction |
|---|---|---|---|
| Direct BRDF | LUT Blinn-Phong + seasoning (terminator, sqrt atten, Schlick metal, Oklab contrast) | LUT Blinn-Phong, plain (`USE_LEGACY_LIGHT=1`) | **Port seasoning onto d3d11 shaders** (P1) |
| Optional PBR | Deleted (dead includes only) | GGX/IBL/SSLR compiled out, present | **Strip** (P1; matches OW's own simplification) |
| Hemisphere | `hmodel.h` rewrite: no-normal hscale, lum/chroma decoupling, sun chroma split, `hemi_vibrance`, wetness | `metalic_roughness_ambient.hlsli` legacy LUT + env cubes | **Port hmodel behavior** (P1) |
| Gloss default | `def_gloss = 24/255` (SoC glossy) | `def_gloss = 2/255` | Tune (P1, playtest call) |
| Exposure | Neutralized (scale = 1.0) | Active auto-exposure; dead range clamp | Neutralize in P3 (spline needs it); fix dead clamp (P2) |
| Tonemap operator | Hermite spline (BT.2408), hybrid luma/maxRGB + Oklab, end-of-chain | Reinhard-style rational, mid-chain (combine_2) | Port operator + chain restructure (P3) |
| Color grading | One parametric LogC block, always on, pre-tonemap | 4 systems: lut.dds, gamma_apply, CM, CGIM | Consolidate to OW model (P3) |
| Bloom | Kawase pyramid D2–D32, FP16 always, threshold 1.5 (defaults ltx 0.5), `def_hdr` 7.5 | Separable Gaussian, 8-bit, threshold 0.1, `def_hdr` 9.0 | Formats in P2; pyramid optional (D4) |
| Scene/albedo RT | FP16 when hires/hdr10 | `R8G8B8A8` albedo; generic/accum already FP16 | Add hires-style switch (P2) |
| Bloom RTs | FP16 | **8-bit UNORM** | FP16 (P2) |
| Pre-final RT | — (postprocess writes backbuffer directly) | `rt_BackbufferLUT` `R10G10B10A2` + gamma_apply | Retarget for HDR (P4) |
| Swapchain | `R10G10B10A2` + PQ + colorspace G2084_P2020 when hdr10 | `B8G8R8A8`, no colorspace API | Port dx10HW approach (P4) |
| Env color clamps | SDR {1,1,1} / HDR {10,10,10} in `Environment_misc.cpp boost()` | unconditional 1.0 clamps in env mixer | HDR-conditionalize (P2/P4) |
| Light expansion | `HDR10_Expand*` (sun SDR lift 25%) | none | Port with spline (P3/P4) |
| Upscaling / scale | none | render-scale + DLSS/FSR/XeSS | **Keep** (IX-Ray advantage) |
| TAA | rt_ssfx_taa (Anomaly) | `taa_render.ps.hlsl` with reversible tonemapper | Must survive chain restructure (H4) |
| Static lighting | R1-retro compose path in combine_1 + `rt_Lmap` | `USE_R2_STATIC_SUN` define exists in r4.cpp | Verify parity during P1 |
| UI/HUD in HDR | Separate `ToDisplay_UI` PQ path, PDA path | single LDR path | Port (P4) |
| MSAA under HDR | force-disabled | present; `r_aa` tokens | Same interplay expected (P4) |

---

## 5. Cross-cutting hazards

- **H1 — `def_hdr` bloom space mismatch (OW bug?)**: OW's `combine_2` adds
  full-range `s_image` to `/def_hdr`-space bloom directly (the distort branch scales
  by `def_hdr`, the additive one doesn't). IX-Ray's `bloom_build` also divides by
  `def_hdr = 9.0` but its compose path differs. Decide: replicate OW's exact look or
  fix the space consistency. Also unify `def_hdr` 7.5 vs 9.0.
- **H2 — gamma-2.2-encoded HDR**: IX-Ray's `PushGamma/PopGamma` wrap albedo, sky,
  lights (`DirectLight` wraps `PushGamma(Radiance)`), fog, bloom (`PopGamma` in
  build). Under `USE_LEGACY_LIGHT` they're identity; OW's pipeline linearizes with
  pure 2.2 at postprocess. If the PBR path is stripped (D1), decide whether
  Push/PopGamma become dead and get removed in the declamp sweep (P2) — must be
  consistent across *every* producer/consumer.
- **H3 — chain topology**: IX-Ray tonemaps mid-chain (combine_2); CAS, screen post,
  pp, and gamma_apply all run *post-tonemap*. OW tonemaps in the final quad. Moving
  the tonemap later (needed for HDR PQ-last in P4) means CAS/screen-post/pp would
  operate on HDR — check each one's assumptions. TAA already runs pre-tonemap with a
  reversible tonemapper (fine).
- **H4 — TAA reversible tonemap**: `taa_render.ps.hlsl` uses a reversible variant
  of the *current* operator; swapping operators must update or drop this.
- **H5 — shader tree topology difference**: OW `r3/*.ps` + `postprocess.lua` etc.
  vs IX-Ray `d3d11/*.ps.hlsl` + `.lua`/XML defs; includes are `*.hlsli` here
  (`shared/common.hlsli` via fallback path). Direct file copies won't work — port
  function-by-function.
- **H6 — engine file casing + unity build**: any new engine `.cpp` must match GLOB
  casing exactly; shaders land in this repo's tracked `gamedata/shaders/d3d11/` (the
  active OW tree is `_GAME` — the engine port ships shaders in-repo; `_GAME` will
  override when present, so both trees must stay in sync mod-side).
- **H7 — HDR10 collateral** (from monolith): MSAA force-off, screenshots disabled
  under HDR, particle HDR vertex path, `rt_secondVP`/PDA 10-bit formats, UI PQ
  paths — a bigger blast radius than "just a swapchain format".
- **H8 — exposure clamp dead code** (`bloom_luminance_3.ps.hlsl`): fix or remove
  during P2 sweep (upstream-PR candidate).
- **H9 — `rt_BackbufferLUT` is a misnomer** (it's the pre-gamma 10-bit backbuffer,
  not a LUT) — don't confuse it with the `lut.dds` grading system when
  consolidating.
- **H10 — parity gate hazards**: shader files are gamedata (no cross-compile risk),
  but any engine `.cpp` edits (RT formats, binders, console vars, swapchain) must
  keep include-casing/CRT/MSVC-only rules per root AGENTS.md. Every touched file
  becomes a hot-zone.

---

## 6. Phase mapping (draft — to be trimmed into the action plan)

### Phase 1 — Material lighting: middle ground between IX-Ray enhancements and retro charm

Scope: **shader-only, `gamedata/shaders/d3d11/`** (+ small C++ binder touches).

- Port OW seasoning into the `metalic_roughness_light.hlsli` equivalent of
  `lmodel.h`: terminator contrast (directional only), sqrt point-light attenuation +
  seam blend, Schlick metalness fresnel add (`owa_metalness.h`).
- Port hemisphere rewrite behavior into `metalic_roughness_ambient.hlsli` /
  `combine_1.ps.hlsl`: no-normal `hscale`, luminance/chrominance decoupling, sun
  chroma split, `hemi_vibrance` (+ engine binder reading the weather key — small
  C++ touch in `r4.cpp`/`Environment`).
- Oklab helpers (`owa_oklab.h`) + `tex_contrast` uniform (binder + console
  `r__tf_contrast` in `xrRender_console.cpp`).
- Wetness (`owa_wetness.h`) — decide if OW-weather-specific (D6).
- Gloss default tune (`def_gloss` 2/255 → 24/255) — playtest call.
- **Strip decision (D1)**: remove/disable the optional GGX/IBL/SSLR path
  (`USE_LEGACY_LIGHT` becomes the only path) or leave dormant. OW's own
  simplification deleted it; stripping shrinks P2's declamp surface.
- Exit: parity gate (engine C++ only for binders), visual side-by-side vs OW
  screenshots, hot-zone registration of every touched file.

### Phase 2 — High-res RTs + declamping sweep

Scope: engine `r4_rendertarget.cpp` + shader-wide sweep.

- Add `r4_hires_rts`-style switch (or unconditional?) → `rt_Color`, `rt_Generic_1`,
  bloom chain to FP16 (mirror the OW RT table; IX-Ray already has most of it).
- Decide the albedo question: OW stores gamma-encoded albedo in 8-bit unless hires;
  IX-Ray same. With Push/PopGamma resolved (H2), pick linear-in-FP16 vs keep gamma.
- Declamp sweep: audit every `saturate`/`clamp` in `gamedata/shaders/d3d11/**` —
  remove output-path clamps that clip HDR (keep ones guarding LDR targets like
  normal encode, AO, gbuffer). Map from §3.2 chain + OW's clamp inventory.
- Fix H1 (`def_hdr` consistency), H8 (dead exposure clamp), H2 (Push/PopGamma
  policy).
- HDR-conditionalize env color clamps (`Environment*` here) — SDR 1.0 / HDR 10.0.
- Exit: parity gate + no-banding/highlight test scenes.

### Phase 3 — Unified color grading + SDR hermite spline

Scope: shaders + binders + console.

- Port `hdr10.h` (spline + unified wrapper + LogC grading) into
  `gamedata/shaders/d3d11/` (as `hdr10.hlsli` or similar).
- Restructure output chain (H3): tonemap moves from `combine_2` to the final quad
  (IX-Ray's `postprocess.ps.hlsl`/`gamma_apply.ps.hlsl` merge into one
  `ToDisplay_World`-style stage), or — alternative D2 — keep combine_2 placement
  and swap operator only. HDR-readiness favors end-of-chain.
- Neutralize auto-exposure (OW-style: MiddleGray lerped to neutral) — keep the
  luminance chain running (P4 might reuse it) or delete.
- Consolidate grading: decide fate of the lut.dds system (D3), gamma_apply params
  (fold into `cg_parameters`?), CM postprocess (gameplay effects — keep; it's
  pre-tonemap in OW too), CGIM options (delete).
- Add console vars/binders: `r4_cg_*`, `hdr10_parameters1/2`, `tex_contrast`,
  `bloom_params` (`Blender_Recorder_StandartBinding.cpp` — hot zone).
- Light expansion SDR sun lift (`HDR10_ExpandSunLight_WithSDR`).
- Exit: parity gate, A/B against OW SDR screenshots.

### Phase 4 — HDR10

Scope: swapchain + UI + collateral (H7).

- Swapchain: `R10G10B10A2_UNORM` +
  `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020` with fallback (port `dx10HW.cpp`
  logic into `Device_create_render_dx11.cpp` + backend present path).
- PQ encode in the final shader (already in `hdr10.hlsli` from P3), UI/PDA paths
  (`ToDisplay_UI`, PDA flag), `rt_secondVP`/UI RT 10-bit formats.
- MSAA interplay, screenshot path under HDR, particle HDR vertex path.
- `r4_hdr10_*` console surface + `_GAME` defaults sync (see §8).
- Exit: parity gate + Windows/Proton HDR display validation (Wine caveat per root
  AGENTS.md — validate user-visible behavior in Proton/Windows, don't trust Wine
  builtin behaviors).

---

## 7. Open decisions (for the action plan)

- **D1 — PBR/IBL/SSLR strip?** User intent says simplify; OW deleted its own.
  Stripping shrinks later phases but permanently diverges from upstream (hot zones
  everywhere). Alternative: leave compiled-out behind `USE_LEGACY_LIGHT` (upstream
  keeps evolving it).
- **D2 — chain topology**: end-of-chain tonemap (OW topology, HDR-clean) vs
  mid-chain operator swap (smaller diff, CAS/pp stay LDR). Implicates H3/H4.
- **D3 — `lut.dds` 3D LUT grading**: keep as optional per-level creative tool on
  top of LogC grading, or remove in the consolidation?
- **D4 — bloom**: port the Kawase pyramid (look-matching, more RTs, fp16-only) vs
  upgrade IX-Ray's Gaussian to FP16 (less churn)?
- **D5 — `def_hdr` unification** (7.5 LA-style vs 9.0) and H1 fix-or-preserve.
- **D6 — wetness system**: port (weather-coupled) or defer (OW-weather-specific)?
- **D7 — probe GI / XeGTAO**: out of scope here (separate OW subsystem) but P1's
  hemisphere work interacts with it — sequence carefully.
- **D8 — `hemi_vibrance`/`fog_auto_blend` weather keys**: engine reads them; OW
  weathers already carry them — additive keys, so `_GAME` weathers keep working on
  this engine unchanged.

---

## 8. Gamedata-side dependency list (user ports into `_GAME/` — this repo never writes there)

- **P1**: `_GAME` weathers keep `hemi_vibrance` (already present);
  `r__tf_contrast` default surface (`defaults_video.ltx [video_basic_lighting]`,
  options script entry); launcher option sync if new user-visible options appear.
- **P3**: `options_lighting_settings.script` entries for `r4_cg_*` (exposure,
  contrast, contrast_middle_gray, saturation, brightness, gamma) and bloom
  (`r2_bloom_threshold/intensity/radius`), `r__tf_contrast`;
  `defaults_video.ltx [video_basic_lighting]` values (OW's file is the reference:
  `r4_cg_exposure=1.0`, `r2_bloom_threshold=0.5`, `r__tf_contrast=0.5`).
- **P4**: `[video_basic] hdr_enable` + `r4_hdr10_*` option entries
  (whitepoint_nits=800, colorspace=2, chroma_correction=0.1, light_expansion=1.25,
  particle_expansion=2.0, ui_nits=203, ui_saturation=0.5, pda_intensity=1.0 per OW
  defaults); `[video_advanced_main] hires_rts`; launcher sync.
- **All phases**: shader-tree sync — the port's shaders land in this repo's tracked
  `gamedata/shaders/d3d11/`; when `_GAME` is mounted it overrides, so `_GAME` must
  receive the same files to stay authoritative mod-side.

---

## 9. Key file index

**IX-Ray (this repo):**
- Engine: `src/Layers/xrRenderPC_R4/{r4.cpp,r4.h,r4_rendertarget.cpp,r4_rendertarget_phase_{scene,accumulator,combine,bloom,luminance,scale,fxaa,smaa,taa,cas,pp,screen_postprocess}.cpp,RenderTargetPhaseGamma.cpp,blender_combine.cpp,blender_luminance.cpp,blender_bloom_build.cpp,blender_light_*.cpp,OverlayAPI/*}`
- Shared: `src/Layers/xrRender/{xrRender_console.cpp,r__types.h,Blender_Recorder_StandartBinding.cpp,uber_deffer.cpp,TextureDescrManager.cpp,ColorMapManager.cpp,dxRenderDeviceRender.cpp}`
- Backend/device: `src/Layers/xrRenderDX10/*`, `src/xrEngine/{Device_create_render_dx11.cpp,device.h,xr_ioc_cmd.cpp,Environment*,xr_effgamma.cpp}`
- Shaders: `gamedata/shaders/d3d11/**` (chain files: `combine_1/2.ps.hlsl`,
  `bloom_*.ps.hlsl`, `gamma_apply.ps.hlsl`, `postprocess*.ps.hlsl`,
  `metalic_roughness_{base,light,ambient}.hlsli`, `sload.hlsli`, `deffer_impl.ps.hlsl`,
  `common_functions.hlsli`, `common_defines.hlsli`, `taa_render.ps.hlsl`,
  `contrast_adaptive_sharpening.ps.hlsl`)
- Config: `gamedata/configs/engine_external.ltx`

**Old World (private, repo-relative):**
- `_GAME/gamedata/shaders/r3/`: `hdr10.h` (spline+grading), `lmodel.h`, `hmodel.h`,
  `common_functions.h`, `common_defines.h`, `owa_oklab.h`, `owa_metalness.h`,
  `owa_wetness.h`, `pbr_brdf*.h` (dead), `probe_lighting.h`, `combine_1.ps`,
  `combine_2_{naa,aa}.ps`, `bloom_{build,downsample,upsample}.ps`,
  `bloom_luminance_{1,2,3}.ps`, `postprocess.ps`, `postprocess_cm.ps`,
  `accum_sun*.ps`, `accum_base.ps`, `accum_indirect.ps`, `sky2.ps`,
  `hud_default.ps`, `font.ps`, `hud_font.ps`, `simple_color.ps`, `yuv2rgb.ps`
- `_GAME/gamedata/configs/`: `plugins/defaults/defaults_video.ltx`,
  `environment/weathers/w_oldworld_*.ltx`; scripts:
  `options_lighting_settings.script`, `options_video_advanced_main.script`,
  `owa_graphics_init.script`
- `xray-monolith:` engine: `src/Layers/xrRenderPC_R4/{r4_rendertarget.cpp,r4_rendertarget_phase_luminance.cpp,r4.cpp}`, `src/Layers/xrRender/{Blender_Recorder_StandartBinding.cpp,xrRender_console.cpp}`, `src/Layers/xrRenderDX10/dx10HW.cpp`, `src/xrEngine/Environment_misc.cpp`; docs: `PROJECT.md`, `docs/graphics-simplification-{spec,plan}.md`

---

## 10. OWA material detection re-evaluation (2026-09-23)

Re-verification of the P2 material-detection code (`owa_material.hlsli`) directly
against IX-Ray sources + an empirical census of all 10,312 `.thm` files in
`oldworld:` `_GAME/gamedata/textures/` (binary chunk parse of
`THM_CHUNK_MATERIAL` = material enum + material_weight, gbuffer value =
`(mtl+0.5)/4`).

### 10.1 What was verified correct

- **The transform exists and reaches the gbuffer.** `r4.h:199`
  (`set_material(..., (mtl+.5f)/4.f)`) binds uniform `L_material`
  (`shared/common.hlsli:21`); `mtl = T->m_material` =
  `tp.material + tp.material_weight` (`TextureDescrManager.cpp:135`, material
  enum 0–4 in `ETextureParams.h:48-56`). Under `USE_LEGACY_LIGHT`,
  `deffer_base.ps.hlsl:47`, `deffer_impl.ps.hlsl:121`, `forward_base.ps.hlsl:56`
  and `lod.ps.hlsl:48` copy `L_material.w` into the gbuffer `Material.x`, which
  reads back as `O.Metalness` (`metalic_roughness_base.hlsli:182/221`).
- **Baselines hold for weight-0 THMs**: 0.125 / 0.375 / 0.625 / 0.875. The
  `s_material` LUT is 4-slice (`r__types.h:87`, built in
  `r4_rendertarget.cpp:766-837` with slices OrenNayar/Blinn/Phong/Metal) and the
  `(mtl+0.5)/4` encoding lands each baseline mid-slice — the LUT coordinate is
  designed for exactly this value.
- **Metal threshold 0.5 catches Phong_Metal** (baseline 0.625). Full census:
  ~210 mat=2 THMs at 0.625–0.875 → full metal. `owa_metalness.h` in OW carries
  the identical constants, so OW parity holds for the metal ramp.
- **Values above 1.0 are real and survive**: mat=3 w≥0.5 → gbuffer 1.0–1.125
  (355 THMs; 207 at 1.075). `rt_Surface` is FP16
  (`r4_rendertarget.cpp:503`), so the round-trip preserves them.

### 10.2 What did NOT hold (empirical)

- **Dominant values are not the four baselines.** Real distribution: 0.375
  (Blin_Phong default — 7,752 THMs, most of the world), 0.25 (OrenNayar w=0.5 —
  1,341), 0.5 (Blin_Phong w=0.5 — 412), 0.875 (~210).
- **`OWA_MAT_TERRAIN = 0.95` matches zero textures** (window 0.91–0.99 empty).
  The value is OW's *writer* constant: its own `deffer_terrain_*.ps` shaders
  hardcode `ms = 0.95f` (`deffer_terrain_mid_flat.ps:67`). IX-Ray has no terrain
  shaders — terrain flows through `deffer_base` with THM values. Porting the
  reader without the writer = dead code.
- **`OWA_MAT_FLORA = 0.15` is a false-positive magnet, and misses real flora.**
  Window 0.11–0.19 catches 64 THMs, of which 40+ are actor faces (`act_face_*`)
  plus props/terrain statics/fire FX; actual flora textures
  (`det_*_grass`, `grnd_grass`, most `trees_*`) are Blin_Phong default → 0.375,
  i.e. outside the window. In OW, 0.15 is written by its dedicated
  `deffer_tree_*`/`deffer_grass` shaders (`ms = 0.15f` hardcoded) — again a
  writer value with no IX-Ray producer.
- **Consequence**: `owa_is_flora(O.Metalness)` at `accum_base.ps.hlsl:21`
  normal-leaned character faces under every point/spot lamp and never fired on
  grass/trees.
- **Metal-ramp collateral (kept, OW-identical)**: 36 THMs land at partial
  metalness — dominated by `trees_bark*` (Blin_Phong w=0.8 → 0.575 → 60%
  metal), plus `veh_sv_t90_*` (w=0.75 → 50%) and `wpn_pkm*` (w=0.85 → 70%).
  Same THMs + same `owa_metalness.h` in OW → same behavior there; flagged for
  the OW A/B rather than "fixed".

### 10.3 The IX-Ray-native flora signal

IX-Ray already flags flora in the gbuffer: `deffer_base.ps.hlsl:62-65` writes
`M.SSS = 1.0f` when **both** `USE_AREF` and `USE_TREEWAVE` are defined. The
blenders set those for tree branches (`Blender_tree.cpp:146+` with
`oBlend.value` aref, explicit `USE_AREF` at :162/:202) and HQ grass details
(`Blender_detail_still.cpp:99/126` `USE_TREEWAVE` + `uber_deffer(..., aref=true)`
→ `USE_AREF` via `uber_deffer.cpp:66`). The channel reads back as `O.SSS`
(`Color.w`), and IX-Ray's own flora SSS already consumes it
(`accum_sun.ps.hlsl:21`). Caveats: LQ grass (`SE_R2_NORMAL_LQ`) and LOD grass
(`details_lod.lua` → `lod`) carry no flag; distance fade is inherent. Under
`USE_R2_STATIC_SUN` the channel carries the static-sun factor instead
(`GbufferPack` override), so the flora test must be mode-gated.

### 10.4 Resolution (applied)

- `owa_is_flora` / `owa_skip_fresnel` now key off `O.SSS` with an internal
  `USE_R2_STATIC_SUN` guard (returns false in that mode — channel is the sun
  factor). `OWA_MAT_FLORA`/`OWA_MAT_TERRAIN` and the material-ID flora test
  removed.
- `DirectLightResponse` takes a trailing `FloraSignal` param (default 0.0f for
  the dormant wrapper); `accum_base`, `accum_sun`, `combine_1` (static-sun call)
  pass `O.SSS`.
- `owa_hemisphere` takes `sss`; fresnel skip + wet-sheen porosity (flora forced
  fully porous) use it. Material-ID mip heuristics kept — they behave sanely
  against the real distribution including >1.0 values.
- Metal ramp unchanged (0.5→0.625) for OW parity; bark quirk noted above.
