#ifndef OWA_TONEMAPPING_H_INCLUDED
#define OWA_TONEMAPPING_H_INCLUDED

// ============================================================================
// OWA: The tonemapping pipeline.
//
// Unified tonemapping for SDR and HDR output. HDR is one output path of this
// pipeline, not its identity.
//
// Pipeline: Gamma-encoded Input -> Linear (pure 2.2) -> Color Grading (LogC)
//           -> Hermite Spline Tonemap -> Output (sRGB or PQ)
//
// Tonemapping (Pure Hermite Spline based on ITU-R BT.2408):
//   - Linear passthrough below knee (preserves retro STALKER aesthetic)
//   - Smooth C1-continuous rolloff above knee toward target white
//   - Hybrid luminance/maxRGB blend preserves saturated colors (fires, neon)
//   - SDR: target_white = 1.0, encode to sRGB
//   - HDR: target_white = peak_nits/80, chroma correction, Rec.2020, PQ encode
//     (dormant while the engine binds hdr10_on = 0)
//
// Note: uniform slot names (hdr10_parameters*, cg_parameters*) match the OW
// shader tree so the two stay diff-able.
// ============================================================================

#include "owa_oklab.hlsli"

/* --- Debug Mode --- */
// Set to 1, 2, or 3 to enable debug visualization, 0 for normal output
#define TONEMAP_DEBUG_MODE 0

/* --- Parameters --- */

// HDR10-only parameters (whitepoint, colorspace, sun/moon, etc.)
uniform float4 hdr10_parameters1;
uniform float4 hdr10_parameters2;
uniform float4 hdr10_parameters11;

// Color grading parameters (SDR + HDR)
uniform float4 cg_parameters1;  // exposure, contrast, saturation, contrast_middle_gray
uniform float4 cg_parameters2;  // brightness, gamma_rcp, unused, unused

/* --- Macros (HDR output path — dormant while hdr10_on = 0) --- */
#define TONEMAP_WHITEPOINT_NITS  (hdr10_parameters1.x)
#define TONEMAP_UI_NITS_SCALAR   (hdr10_parameters1.y)
#define TONEMAP_IS_HDR           (hdr10_parameters1.z != 0.0)
#define TONEMAP_IS_RENDERING_PDA (hdr10_parameters1.w != 0.0)

#define TONEMAP_COLORSPACE        (hdr10_parameters2.x)
#define TONEMAP_PDA_INTENSITY     (hdr10_parameters2.y)
#define TONEMAP_CHROMA_CORRECTION (hdr10_parameters2.z)

/* --- Color Grading Macros (SDR + HDR) --- */
#define CG_EXPOSURE             (cg_parameters1.x)
#define CG_CONTRAST             (cg_parameters1.y)
#define CG_SATURATION           (cg_parameters1.z)
#define CG_CONTRAST_MIDDLE_GRAY (cg_parameters1.w)
#define CG_BRIGHTNESS           (cg_parameters2.x)
#define CG_GAMMA_RCP            (cg_parameters2.y)

#define TONEMAP_LIGHT_EXPANSION    (hdr10_parameters11.y)
#define TONEMAP_PARTICLE_EXPANSION (hdr10_parameters11.z)

/* --- Colorspace Options --- */
#define TONEMAP_USE_COLORSPACE_REC709  (TONEMAP_COLORSPACE == 0.0)
#define TONEMAP_USE_COLORSPACE_P3D65   (TONEMAP_COLORSPACE == 1.0)
#define TONEMAP_USE_COLORSPACE_REC2020 (TONEMAP_COLORSPACE == 2.0)

/* --- Colorspace Transforms --- */

// see https://www.colour-science.org:8010/apps/rgb_colourspace_transformation_matrix?input-colourspace=ITU-R+BT.709&output-colourspace=P3-D65&chromatic-adaptation-transform=Bradford&formatter=str&decimals=8
static const float3x3 CSTransform_Rec709_To_P3D65 = {
	{ 0.82246197,  0.17753803, -0.00000000},
 	{ 0.03319420,  0.96680580,  0.00000000},
 	{ 0.01708263,  0.07239744,  0.91051993},
};

// see: https://www.colour-science.org:8010/apps/rgb_colourspace_transformation_matrix?input-colourspace=ITU-R+BT.709&output-colourspace=ITU-R+BT.2020&chromatic-adaptation-transform=Bradford&formatter=str&decimals=8
static const float3x3 CSTransform_Rec709_To_Rec2020 = {
	{0.62740390,  0.32928304,  0.04331307},
	{0.06909729,  0.91954040,  0.01136232},
	{0.01639144,  0.08801331,  0.89559525},
};

// see: https://www.colour-science.org:8010/apps/rgb_colourspace_transformation_matrix?input-colourspace=P3-D65&output-colourspace=ITU-R+BT.709&chromatic-adaptation-transform=Bradford&formatter=str&decimals=8
static const float3x3 CSTransform_P3D65_To_Rec709 = {
	{ 1.22494018, -0.22494018, -0.00000000},
	{-0.04205695,  1.04205695, -0.00000000},
	{-0.01963755, -0.07863605,  1.09827360},
};

// see: https://www.colour-science.org:8010/apps/rgb_colourspace_transformation_matrix?input-colourspace=P3-D65&output-colourspace=ITU-R+BT.2020&chromatic-adaptation-transform=Bradford&formatter=str&decimals=8
static const float3x3 CSTransform_P3D65_To_Rec2020 = {
	{ 0.75383303,  0.19859737,  0.04756960},
 	{ 0.04574385,  0.94177722,  0.01247893},
 	{-0.00121034,  0.01760172,  0.98360862},
};

// see: https://www.colour-science.org:8010/apps/rgb_colourspace_transformation_matrix?input-colourspace=ITU-R+BT.2020&output-colourspace=ITU-R+BT.709&chromatic-adaptation-transform=Bradford&chromatic-adaptation-transform=Bradford&formatter=str&decimals=8
static const float3x3 CSTransform_Rec2020_To_Rec709 = {
	{ 1.66049100, -0.58764114, -0.07284986},
	{-0.12455047,  1.13289990, -0.00834942},
	{-0.01815076, -0.10057890,  1.11872966},
};

// see: https://www.colour-science.org:8010/apps/rgb_colourspace_transformation_matrix?input-colourspace=ITU-R+BT.2020&output-colourspace=DCI-P3&chromatic-adaptation-transform=Bradford&formatter=str&decimals=8
static const float3x3 CSTransform_Rec2020_To_P3D65 = {
	{ 1.34357825, -0.28217967, -0.06139858},
 	{-0.06529745,  1.07578792, -0.01049046},
 	{ 0.00282179, -0.01959849,  1.01677671},
};

/* --- Utility Functions --- */

float3 ApplyColorspaceTransform(float3 color, float3x3 xform)
{
	return mul(xform, color);
}

// Linearize the gamma-encoded pipeline with pure 2.2 (sRGB input convention)
float3 sRGBToLinear(float3 color)
{
	color = pow(color, 2.2);
	return color;
}

float3 LinearToSRGB(float3 color)
{
	color = pow(color, 1.0 / 2.2);
	return color;
}

// NOTE: see https://en.wikipedia.org/wiki/Perceptual_quantizer
float3 ApplyST2084_PQ(float3 color_norm)
{
    // Apply ST.2084 (PQ curve) for HDR10 standard
    static const float m1 = 2610.0 / 4096.0 / 4;
    static const float m2 = 2523.0 / 4096.0 * 128;
    static const float c1 = 3424.0 / 4096.0;
    static const float c2 = 2413.0 / 4096.0 * 32;
    static const float c3 = 2392.0 / 4096.0 * 32;
    float3             cp = pow(color_norm, m1);

    return pow((c1 + c2 * cp) / (1 + c3 * cp), m2);
}

// Convert SDR-relative linear (where 1.0 = 80 nits) to PQ
float3 LinearToPQ(float3 sdr_relative_linear)
{
    static const float st2084_max_nits = 10000.0;
    static const float sdr_reference_white = 80.0;

    // SDR-relative to nits: multiply by 80
    // Nits to PQ input (normalize to 10000): divide by 10000
    float3 L = sdr_relative_linear * sdr_reference_white / st2084_max_nits;
    return ApplyST2084_PQ(max(L, 0.0));
}

// Rec.709 luminance weights (CIE XYZ y row, Bradford-adapted primaries)
float Luminance_Rec709(float3 color)
{
	static const float3 lw = {0.2126390, 0.7151687, 0.0721923};
	return dot(color, lw);
}

// DCI-P3 luminance weights
float Luminance_P3D65(float3 color)
{
	static const float3 lw = {0.2289746, 0.6917385, 0.0792869};
	return dot(color, lw);
}

// Rec.2020 luminance weights
float Luminance_Rec2020(float3 color)
{
	static const float3 lw = {0.2627002, 0.6779981, 0.0593017};
	return dot(color, lw);
}

// Expects input color to be in the target colorspace
float LuminanceTarget(float3 color)
{
	if (TONEMAP_USE_COLORSPACE_REC709) {
		return Luminance_Rec709(color);

	} else if (TONEMAP_USE_COLORSPACE_P3D65) {
		return Luminance_P3D65(color);

	} else if (TONEMAP_USE_COLORSPACE_REC2020) {
		return Luminance_Rec2020(color);
	}

	return 0.0;
}

// NOTE: see https://64.github.io/tonemapping/#luminance-and-color-theory
float3 ChangeLuminance(float3 color, float lum_in, float lum_out)
{
	// TODO: how to solve singularity properly?
	lum_in += 0.00001;
	return color * (lum_out / lum_in);
}

// Chroma correction - boosts saturation to compensate for perceptual desaturation during compression
// Reference: ITU-R BT.2390 Annex 1
float ChromaCorrection(float L_in, float L_out, float chroma_scaling)
{
	float ratio = L_in / max(L_out, 1e-6);
	ratio = min(ratio, 4.0);
	return (ratio > 1.0) ? pow(ratio, chroma_scaling) : 1.0;
}

// Apply chroma correction to color
float3 ApplyChromaCorrection(float3 color, float L_in, float L_out, float chroma_scaling)
{
	if (chroma_scaling <= 0.0) return color;

	float correction = ChromaCorrection(L_in, L_out, chroma_scaling);
	float lum = LuminanceTarget(color);
	float3 result = lum + (color - lum) * correction;
	return max(result, 0.0);
}

// NOTE: see https://catlikecoding.com/unity/tutorials/custom-srp/color-grading/
// NOTE: see https://www.arri.com/resource/blob/31918/66f56e6abb6e5b6553929edf9aa7483e/2017-03-alexa-logc-curve-in-vfx-data.pdf
static const float LogC_cut = 0.011361;
static const float LogC_a   = 5.555556;
static const float LogC_b   = 0.047996;
static const float LogC_c   = 0.244161;
static const float LogC_d   = 0.386036;
static const float LogC_e   = 5.301883;
static const float LogC_f   = 0.092814;

float3 LinearToLogC(float3 x)
{
	return (x > LogC_cut) ? (LogC_c * log10(LogC_a * x + LogC_b) + LogC_d) : (LogC_e * x + LogC_f);
}

float3 LogCToLinear(float3 x)
{
	return (x > LogC_e * LogC_cut + LogC_f) ? ((pow(10.0, (x - LogC_d) / LogC_c) - LogC_b) / LogC_a) : ((x - LogC_f) / LogC_e);
}

/* --- Tonemapping --- */

// Pure Hermite Spline Rolloff (based on ITU-R BT.2408)
//
// Linear passthrough below knee, smooth C1-continuous rolloff above.
// This is a "gentle" tonemapper that preserves the original look of content
// while gracefully compressing highlights - faithful to retro STALKER aesthetic.
//
// Parameters:
//   input:        Linear luminance/value (scene-referred, where 1.0 = SDR white)
//   target_white: Output ceiling (1.0 for SDR, peak_nits/80 for HDR)
//   max_white:    Maximum expected scene input (headroom, e.g. 20.0)
float HermiteSplineRolloff(float input, float target_white, float max_white)
{
    if (input <= 0.0) return 0.0;

    // Rescale input to 0-1 range where max_white maps to 1.0
    float e1 = input / max_white;
    float max_lum = target_white / max_white;

    // Knee at 50% of target output (scene-referred adjustment of BT.2408)
    float knee_normalized = 0.5 * max_lum;
    float knee_input = knee_normalized * max_white;

    // Below knee: linear passthrough
    if (input <= knee_input) {
        return input;
    }

    // Above knee: hermite spline rolloff
    // t goes from 0 (at knee) to 1 (at max_white)
    float t = saturate((e1 - knee_normalized) / (1.0 - knee_normalized));
    float t2 = t * t;
    float t3 = t2 * t;

    // Hermite basis functions for cubic interpolation
    float h00 = 2.0*t3 - 3.0*t2 + 1.0;   // Start position weight
    float h10 = t3 - 2.0*t2 + t;          // Start tangent weight
    float h01 = -2.0*t3 + 3.0*t2;         // End position weight

    // Tangent at knee matches linear slope (1.0 in normalized space)
    float m0 = 1.0 - knee_normalized;

    // Interpolate in normalized space
    float e2 = h00 * knee_normalized + h10 * m0 + h01 * max_lum;

    // Convert back to scene values and clamp to target
    return min(e2 * max_white, target_white);
}

// Unified Hermite Spline Tonemapper with Hybrid Luminance/MaxRGB
//
// Blends between luminance-based (preserves hue for neutral colors) and
// maxRGB-based (preserves saturation for vivid colors like fires).
// Uses Oklab color space for perceptually uniform blending.
//
//   SDR: target_white = 1.0
//   HDR: target_white = peak_nits / 80.0
float3 HermiteSplineUnified(float3 color, float target_white, float max_input, bool use_rec709)
{
    float maxC = max(color.r, max(color.g, color.b));
    if (maxC < 1e-6) {
        return color;
    }

    // Use appropriate luminance based on colorspace
    float lum = use_rec709 ? Luminance_Rec709(color) : LuminanceTarget(color);

    // Luminance-based rolloff (best for neutral/desaturated colors)
    float lum_rolled = HermiteSplineRolloff(lum, target_white, max_input);
    float3 lum_result = ChangeLuminance(color, lum, lum_rolled);

    // MaxRGB-based rolloff (best for saturated colors like fire, neon, etc.)
    float maxC_rolled = HermiteSplineRolloff(maxC, target_white, max_input);
    float3 max_result = color * (maxC_rolled / maxC);

    // Blend based on saturation using Oklab for perceptually uniform interpolation
    // Low saturation (gray): use luminance method (preserves neutral tones)
    // High saturation (vivid): use maxRGB method (preserves color intensity)
    float sat = (maxC - lum) / maxC;
    float blend = smoothstep(0.1, 0.5, sat);

    // Oklab blending preserves hue better during the luminance/maxRGB transition
    return oklab_lerp(lum_result, max_result, blend);
}

// HDR version with chroma correction (BT.2390 Annex 1) — dormant while hdr10_on = 0
float3 HermiteSplineHDR(float3 color, float target_white, float max_input)
{
    static const float sdr_nits = 80.0;

    float maxC = max(color.r, max(color.g, color.b));
    if (maxC < 1e-6) {
        return color * sdr_nits;
    }

    // Use colorspace-aware luminance (matches target colorspace)
    float lum = LuminanceTarget(color);

    // Apply tonemapping (use colorspace-aware luminance since we're in target colorspace)
    float3 result = HermiteSplineUnified(color, target_white, max_input, false);

    // Convert to nits
    float3 result_nits = result * sdr_nits;

    // Chroma correction for compressed highlights
    // Only apply above the knee region where compression occurs
    float knee_input = 0.5 * target_white;
    if (lum > knee_input && TONEMAP_CHROMA_CORRECTION > 0.0) {
        float chroma_blend = smoothstep(0.0, 1.0, saturate((lum - knee_input) / (target_white - knee_input)));
        float linear_nits = lum * sdr_nits;
        float output_nits = LuminanceTarget(result_nits);
        result_nits = ApplyChromaCorrection(result_nits, linear_nits, output_nits, TONEMAP_CHROMA_CORRECTION * chroma_blend);
    }

    return result_nits;
}

/* --- Colorspace Conversion --- */

float3 TransformColorspace_ToTarget(float3 color)
{
	if (TONEMAP_USE_COLORSPACE_P3D65)
		return ApplyColorspaceTransform(color, CSTransform_Rec709_To_P3D65);
	if (TONEMAP_USE_COLORSPACE_REC2020)
		return ApplyColorspaceTransform(color, CSTransform_Rec709_To_Rec2020);
	return color;
}

float3 TransformColorspace_ToDisplay(float3 color)
{
	if (TONEMAP_USE_COLORSPACE_P3D65)
		return ApplyColorspaceTransform(color, CSTransform_P3D65_To_Rec2020);
	if (TONEMAP_USE_COLORSPACE_REC709)
		return ApplyColorspaceTransform(color, CSTransform_Rec709_To_Rec2020);
	return color;
}

/* --- Light Expansion --- */

// Expand bright lights into HDR range (dim lights unchanged) — HDR only
float3 ExpandLight(float3 light_color)
{
    if (!TONEMAP_IS_HDR) return light_color;

    float lum = Luminance_Rec709(light_color);
    float expansion_t = smoothstep(0.6, 0.9, lum);
    float expansion_factor = 1.0 + expansion_t * 0.5 * TONEMAP_LIGHT_EXPANSION;
    return light_color * expansion_factor;
}

// Sun-specific expansion that also applies a gentle stylized lift in SDR mode.
// HDR: same as ExpandLight (full HDR range expansion).
// SDR: 25% max lift for bright sun, zero at night — makes sun-lit surfaces punch
//      through hemisphere ambient without requiring HDR output.
float3 ExpandSunLight(float3 light_color)
{
    float lum = Luminance_Rec709(light_color);

    if (TONEMAP_IS_HDR)
    {
        float expansion_t = smoothstep(0.6, 0.9, lum);
        float expansion_factor = 1.0 + expansion_t * 0.5 * TONEMAP_LIGHT_EXPANSION;
        return light_color * expansion_factor;
    }
    else
    {
        // SDR stylized expansion: smooth lift starting at moderate sun brightness.
        // Range: 0 (dim/night) → 25% max (bright noon sun).
        float expansion_t = smoothstep(0.4, 0.85, lum);
        float expansion_factor = 1.0 + expansion_t * 0.25;
        return light_color * expansion_factor;
    }
}

// Point/spot lights get slightly more expansion — HDR only
float3 ExpandLightPointSpot(float3 light_color)
{
    if (!TONEMAP_IS_HDR) return light_color;

    float lum = Luminance_Rec709(light_color);
    float expansion_t = smoothstep(0.5, 0.85, lum);
    float expansion_factor = 1.0 + expansion_t * 0.75 * TONEMAP_LIGHT_EXPANSION;
    return light_color * expansion_factor;
}

/* --- Debug --- */

// False color heatmap: black(0) -> blue(0.5) -> green(1.0) -> yellow(1.5) -> red(2.0+)
#define TONEMAP_DEBUG_MODE 0
float3 DebugHeatmap(float value)
{
    value = saturate(value / 2.5);
    float3 colors[5] = {
        float3(0, 0, 0), float3(0, 0, 1), float3(0, 1, 0),
        float3(1, 1, 0), float3(1, 0, 0)
    };
    float t = value * 4.0;
    int idx = min(int(t), 3);
    return lerp(colors[idx], colors[idx + 1], frac(t));
}

/* --- Color Grading --- */

float3 ApplyColorGrading(float3 color)
{
	color = max(0, color + CG_BRIGHTNESS);
	color = pow(color, CG_GAMMA_RCP);
	color *= CG_EXPOSURE;

	// Contrast in LogC space - specifically so contrast doesn't clip/crush
	// before tonemapping
	color = max(0.0001, color);
	color = LinearToLogC(color);
	color = (color - CG_CONTRAST_MIDDLE_GRAY) * CG_CONTRAST + CG_CONTRAST_MIDDLE_GRAY;
	color = max(0, LogCToLinear(color));

	// Saturation
	float luminance = Luminance_Rec709(color);
	return lerp(luminance, color, CG_SATURATION);
}

/* --- Main Output Functions --- */

// World rendering: gamma-encoded scene -> tonemapped output
//
// Unified pipeline for both SDR and HDR:
//   1. Linearize input (gamma removal, pure 2.2)
//   2. Apply color grading (exposure, contrast, saturation)
//   3. Hermite spline tonemap (target differs: 1.0 for SDR, peak/80 for HDR)
//   4. SDR: encode to sRGB and return
//   5. HDR: colorspace transform, PQ encode, return
//
// The hermite spline provides linear passthrough below knee, gentle rolloff above.
// This preserves the "raw" retro STALKER aesthetic while preventing clipping.
float3 ApplyTonemap_World(float3 color)
{
    color = max(0, color);

#if TONEMAP_DEBUG_MODE == 1
    return DebugHeatmap(Luminance_Rec709(color));
#endif
#if TONEMAP_DEBUG_MODE == 2
    return (Luminance_Rec709(color) > 1.0) ? float3(1,1,1) : float3(0,0,0);
#endif

    color = sRGBToLinear(color);

#if TONEMAP_DEBUG_MODE == 3
    return DebugHeatmap(Luminance_Rec709(color));
#endif

    color = ApplyColorGrading(color);

    // Scene headroom - maximum expected input luminance
    // 20x SDR white allows for very bright highlights (fires, sun, etc.)
    static const float max_input = 20.0;

    // --- SDR Path ---
    if (!TONEMAP_IS_HDR) {
        // Tonemap to SDR ceiling (1.0 = 80 nits reference white)
        // Use Rec.709 luminance (SDR stays in Rec.709, no colorspace transform)
        float3 tonemapped = HermiteSplineUnified(color, 1.0, max_input, true);

        // Clamp and encode to sRGB for display
        return LinearToSRGB(saturate(tonemapped));
    }

    // --- HDR Path (dormant while hdr10_on = 0) ---
    // Transform to target colorspace before tonemapping (if P3 or Rec.2020 selected)
    color = TransformColorspace_ToTarget(color);

    // Target white in scene-referred units (peak_nits / 80)
    static const float sdr_nits = 80.0;
    float peak_linear = TONEMAP_WHITEPOINT_NITS / sdr_nits;

    // Tonemap with chroma correction
    float3 nits = HermiteSplineHDR(color, peak_linear, max_input);

    // Transform from target colorspace to display (Rec.2020 for HDR10 output)
    nits = TransformColorspace_ToDisplay(nits);

    // Encode with ST.2084 PQ curve
    static const float st2084_max_nits = 10000.0;
    return ApplyST2084_PQ(nits / st2084_max_nits);
}

// UI rendering: sRGB -> HDR10 without tonemapping (dormant while hdr10_on = 0)
float3 ApplyTonemap_UI(float3 color, float nits_scalar, float alpha)
{
    if (!TONEMAP_IS_HDR) return color;
    color = max(0, color);

	color = sRGBToLinear(color);

	// Saturation adjustment for PQ blending
	float saturation = lerp(0.0, 1.0, alpha);
	float luma = Luminance_Rec709(color);
	color = lerp(luma, color, saturation);

	color = TransformColorspace_ToTarget(color);
	color = saturate(color);
	color = TransformColorspace_ToDisplay(color);

	static const float st2084_max_nits = 10000.0;
	return ApplyST2084_PQ(TONEMAP_WHITEPOINT_NITS * nits_scalar * color / st2084_max_nits);
}

#endif // OWA_TONEMAPPING_H_INCLUDED
