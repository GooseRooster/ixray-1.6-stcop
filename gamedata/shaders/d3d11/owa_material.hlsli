#ifndef OWA_MATERIAL_H_INCLUDED
#define OWA_MATERIAL_H_INCLUDED

//////////////////////////////////////////////////////////////////////////////////////////
// OWA: Unified metalness detection (ported from OW owa_metalness.h, verbatim).
//
// Engine transforms THM material IDs via: (mtl + 0.5) / 4.0
// After GBuffer round-trip, actual shader values are:
//   Material 0 (OrenNayar_Blin)  → ~0.125 (diffuse - concrete, fabric, wood, skin)
//   Material 1 (Blin_Phong)      → ~0.375 (glossy plastic, polished wood)
//   Material 2 (Phong_Metal)     → ~0.625 (metallic - gun barrels, pipes)
//   Material 3 (Metal_OrenNayar) → ~0.875 (rough metallic - worn metal)
//
// Detection: Pure material-based - if THM says metal, it's metal
//////////////////////////////////////////////////////////////////////////////////////////

// Material ID threshold - below this is definitely not metal
// Material 2 (Phong_Metal) is ~0.625, so 0.5 catches it correctly
#define OWA_METAL_MAT_THRESHOLD 0.5f

// Flora and terrain material IDs for exclusion
// Flora uses Material 0 but with special flag, ends up around 0.15
// (matches OW common_brdf.h MAT_FLORA / MAT_TERRAIN)
#define OWA_MAT_FLORA 0.15f
#define OWA_MAT_FLORA_EPSILON 0.04f
#define OWA_MAT_TERRAIN 0.95f
#define OWA_MAT_TERRAIN_EPSILON 0.04f

// Fresnel intensity controls (conservative values)
#define OWA_FRESNEL_DIELECTRIC 0.01f   // Base fresnel for non-metals
#define OWA_FRESNEL_METAL_ADD 0.04f    // Additional fresnel for metals

//////////////////////////////////////////////////////////////////////////////////////////
// Calculate metalness from material ID only
//////////////////////////////////////////////////////////////////////////////////////////
float owa_calc_metalness(float material_id)
{
	// Flora and terrain have special shader handling - exclude them
	if (abs(material_id - OWA_MAT_FLORA) < OWA_MAT_FLORA_EPSILON)
		return 0.0f;
	if (abs(material_id - OWA_MAT_TERRAIN) < OWA_MAT_TERRAIN_EPSILON)
		return 0.0f;

	// Soft ramp from threshold (0.5) to Phong_Metal baseline (0.625)
	float mat_lower = OWA_METAL_MAT_THRESHOLD;
	float mat_upper = 0.625f;
	return saturate((material_id - mat_lower) / (mat_upper - mat_lower));
}

//////////////////////////////////////////////////////////////////////////////////////////
// Schlick Fresnel approximation with conservative intensity
// Returns fresnel factor scaled by material type and incoming light
//
// light_intensity: luminance of incoming light (0-1+ range)
//   - Scales fresnel effect to prevent over-bright reflections at night
//   - Uses sqrt for perceptual scaling
//////////////////////////////////////////////////////////////////////////////////////////
float owa_compute_fresnel(float NdotV, float metalness, float light_intensity)
{
	float fresnel = pow(1.0f - saturate(NdotV), 5.0f);

	// Conservative intensity: small base + metalness boost
	float base_intensity = OWA_FRESNEL_DIELECTRIC + metalness * OWA_FRESNEL_METAL_ADD;

	// Scale by light intensity with perceptual curve
	float light_scale = sqrt(saturate(light_intensity));

	return fresnel * base_intensity * light_scale;
}

// Legacy overload for compatibility - assumes full light intensity
float owa_compute_fresnel(float NdotV, float metalness)
{
	return owa_compute_fresnel(NdotV, metalness, 1.0f);
}

//////////////////////////////////////////////////////////////////////////////////////////
// OWA: Shadow terminator contrast shaping (ported from OW lmodel.h).
// Crisper lit/shadow boundary on directional (sun/sky) light only.
// 0.80× at the terminator (NdotL=0) → 1.0× for forward-facing surfaces.
//////////////////////////////////////////////////////////////////////////////////////////
float owa_terminator_contrast(float NdotL)
{
	return lerp(0.80, 1.0, smoothstep(0.0, 0.25, saturate(NdotL)));
}

//////////////////////////////////////////////////////////////////////////////////////////
// OWA: Specular Anti-Aliasing for Environment Reflections (simplified)
// (ported from OW pbr_brdf.h specAA_rough_env — the only pbr_brdf helper the
// classic path uses; pbr_brdf.h itself is not ported, matching OW's usage).
//////////////////////////////////////////////////////////////////////////////////////////
float specAA_rough_env(float3 N, float rough)
{
	float3 dnx = ddx(N);
	float3 dny = ddy(N);
	float variance = dot(dnx, dnx) + dot(dny, dny);

	// Roughness-adaptive scaling: slightly stronger for environment reflections
	float variance_scale = lerp(2.5, 0.4, rough);
	float add_r = saturate(variance * variance_scale);
	float r2 = rough * rough + add_r;

	return saturate(sqrt(r2));
}

//////////////////////////////////////////////////////////////////////////////////////////
// Check if material is flora (for SSS treatment)
//////////////////////////////////////////////////////////////////////////////////////////
bool owa_is_flora(float material_id)
{
	return abs(material_id - OWA_MAT_FLORA) < OWA_MAT_FLORA_EPSILON;
}

//////////////////////////////////////////////////////////////////////////////////////////
// Check if material should skip fresnel (flora, terrain, or other special materials)
//////////////////////////////////////////////////////////////////////////////////////////
bool owa_skip_fresnel(float material_id)
{
	if (abs(material_id - OWA_MAT_FLORA) < OWA_MAT_FLORA_EPSILON)
		return true;
	if (abs(material_id - OWA_MAT_TERRAIN) < OWA_MAT_TERRAIN_EPSILON)
		return true;
	return false;
}

#endif // OWA_MATERIAL_H_INCLUDED
