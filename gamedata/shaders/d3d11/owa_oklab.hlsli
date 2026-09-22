#ifndef OWA_OKLAB_H_INCLUDED
#define OWA_OKLAB_H_INCLUDED

// ============================================================================
// OWA: Oklab color space utilities (ported from OW owa_oklab.h, verbatim).
// Based on Björn Ottosson's Oklab: https://bottosson.github.io/posts/oklab/
//
// Oklab is a perceptually uniform color space where:
// - Equal distances correspond to equal perceived color differences
// - Hue is preserved better during blending (no muddy intermediate colors)
// - Saturation remains consistent through interpolation
// ============================================================================

// MASTER TOGGLE: Set to 0 to disable all Oklab blending across the entire shader base
// When disabled, oklab_lerp() falls back to standard RGB lerp
// Useful for A/B testing and performance profiling
#define OWA_OKLAB_MASTER_ENABLE 1

#if !OWA_OKLAB_MASTER_ENABLE
	// Master toggle OFF: oklab_lerp becomes a simple RGB lerp passthrough
	#define oklab_lerp(a, b, t) lerp(a, b, t)
	#define oklab_fog_blend(scene, fog_oklab, t) lerp(scene, fog_oklab, t)
	#define rgb_to_oklab(rgb) (rgb)
	#define oklab_to_rgb(lab) (lab)
#else
	// Master toggle ON: Full Oklab implementation follows

// Convert linear sRGB to Oklab
// Input: Linear RGB (NOT gamma-encoded sRGB)
// Output: L = lightness, a = green-red, b = blue-yellow
float3 rgb_to_oklab(float3 rgb)
{
	// Linear RGB to LMS (cone response)
	float l = 0.4122214708f * rgb.r + 0.5363325363f * rgb.g + 0.0514459929f * rgb.b;
	float m = 0.2119034982f * rgb.r + 0.6806995451f * rgb.g + 0.1073969566f * rgb.b;
	float s = 0.0883024619f * rgb.r + 0.2817188376f * rgb.g + 0.6299787005f * rgb.b;

	// Cube root for perceptual uniformity
	l = pow(max(l, 0.0), 1.0 / 3.0);
	m = pow(max(m, 0.0), 1.0 / 3.0);
	s = pow(max(s, 0.0), 1.0 / 3.0);

	// LMS to Oklab
	return float3(
		0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
		1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
		0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s
	);
}

// Convert Oklab to linear sRGB
// Input: L = lightness, a = green-red, b = blue-yellow
// Output: Linear RGB (NOT gamma-encoded sRGB)
float3 oklab_to_rgb(float3 lab)
{
	// Oklab to LMS
	float l = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
	float m = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
	float s = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;

	// Cube (undo the cube root)
	l = l * l * l;
	m = m * m * m;
	s = s * s * s;

	// LMS to linear RGB
	return float3(
		+4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
		-1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
		-0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
	);
}

// Blend two colors in Oklab space
// This produces perceptually linear blending with better hue preservation
float3 oklab_lerp(float3 rgb_a, float3 rgb_b, float t)
{
	float3 lab_a = rgb_to_oklab(rgb_a);
	float3 lab_b = rgb_to_oklab(rgb_b);
	float3 lab_blend = lerp(lab_a, lab_b, t);
	return oklab_to_rgb(lab_blend);
}

// Optimized fog blend that caches fog color conversion
// fog_oklab should be pre-computed: rgb_to_oklab(fog_color)
float3 oklab_fog_blend(float3 scene_rgb, float3 fog_oklab, float fog_factor)
{
	float3 scene_oklab = rgb_to_oklab(scene_rgb);
	float3 blended_oklab = lerp(scene_oklab, fog_oklab, fog_factor);
	return oklab_to_rgb(blended_oklab);
}

#endif // OWA_OKLAB_MASTER_ENABLE

#endif // OWA_OKLAB_H_INCLUDED
