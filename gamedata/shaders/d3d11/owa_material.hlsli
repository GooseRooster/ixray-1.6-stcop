#ifndef OWA_MATERIAL_H_INCLUDED
#define OWA_MATERIAL_H_INCLUDED

//////////////////////////////////////////////////////////////////////////////////////////
// OWA: Material classification for the IX-Ray GBuffer.
//
// Under USE_LEGACY_LIGHT the gbuffer "Metalness" channel (s_surface.x) carries the
// texture THM material value, written by deffer_base/deffer_impl/lod/forward as
// L_material.w. The engine computes that as (mtl + 0.5) / 4, where
// mtl = THM material enum (0=OrenNayar_Blin, 1=Blin_Phong, 2=Phong_Metal,
// 3=Metal_OrenNayar) + THM material_weight (0-1):
//   Material 0 (OrenNayar_Blin)  → 0.125 baseline (diffuse - concrete, fabric, wood, skin)
//   Material 1 (Blin_Phong)      → 0.375 baseline (glossy plastic, polished wood)
//   Material 2 (Phong_Metal)     → 0.625 baseline (metallic - gun barrels, pipes)
//   Material 3 (Metal_OrenNayar) → 0.875 baseline (rough metallic - worn metal)
// material_weight shifts values upward, so the live range is [0.125, 1.125]
// (values above 1.0 survive because rt_Surface is FP16). The dominant clusters
// in real game data are 0.375 (Blin_Phong default) and 0.25 (OrenNayar w=0.5).
//
// Flora does NOT have a material value here: the engine flags flora (tree
// branches and HQ grass details, via USE_AREF + USE_TREEWAVE) by writing
// M.SSS = 1 into the gbuffer Color alpha, which reads back as O.SSS.
// (Under USE_R2_STATIC_SUN that channel carries the static-sun factor instead,
// so the flora test is disabled there.)
//
// Detection: metal from the material value; flora from the SSS flag.
//////////////////////////////////////////////////////////////////////////////////////////

// Material ID threshold - below this is definitely not metal
// Material 2 (Phong_Metal) is ~0.625, so 0.5 catches it correctly
#define OWA_METAL_MAT_THRESHOLD 0.5f

// Fresnel intensity controls (conservative values)
#define OWA_FRESNEL_DIELECTRIC 0.01f   // Base fresnel for non-metals
#define OWA_FRESNEL_METAL_ADD 0.04f    // Additional fresnel for metals

//////////////////////////////////////////////////////////////////////////////////////////
// Calculate metalness from material ID only
//////////////////////////////////////////////////////////////////////////////////////////
float owa_calc_metalness(float material_id)
{
	// Soft ramp from threshold (0.5) to Phong_Metal baseline (0.625).
	// Values above 1.0 (material_weight-heavy Metal_OrenNayar) saturate.
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
// OWA: Shadow terminator contrast shaping.
// Crisper lit/shadow boundary on directional (sun/sky) light only.
// 0.80× at the terminator (NdotL=0) → 1.0× for forward-facing surfaces.
//////////////////////////////////////////////////////////////////////////////////////////
float owa_terminator_contrast(float NdotL)
{
	return lerp(0.80, 1.0, smoothstep(0.0, 0.25, saturate(NdotL)));
}

//////////////////////////////////////////////////////////////////////////////////////////
// OWA: Specular Anti-Aliasing for Environment Reflections.
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
// Check if material is flora (for SSS treatment).
// IX-Ray-native signal: deffer_base writes M.SSS=1 into the gbuffer for
// USE_AREF + USE_TREEWAVE geometry (tree branches + HQ grass details).
// Under USE_R2_STATIC_SUN the same channel carries the static-sun factor,
// so the test is disabled in that mode.
//////////////////////////////////////////////////////////////////////////////////////////
bool owa_is_flora(float gbuffer_sss)
{
#ifndef USE_R2_STATIC_SUN
	return gbuffer_sss > 0.0f;
#else
	return false;
#endif
}

//////////////////////////////////////////////////////////////////////////////////////////
// Check if material should skip fresnel (flora - the SSS channel is the only
// reliable flag; no material-ID slot distinguishes flora in this engine).
//////////////////////////////////////////////////////////////////////////////////////////
bool owa_skip_fresnel(float gbuffer_sss)
{
	return owa_is_flora(gbuffer_sss);
}

#endif // OWA_MATERIAL_H_INCLUDED
