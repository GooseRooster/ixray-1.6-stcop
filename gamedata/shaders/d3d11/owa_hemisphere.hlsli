#ifndef OWA_HEMISPHERE_H_INCLUDED
#define OWA_HEMISPHERE_H_INCLUDED

// ============================================================================
// OWA: Hemisphere lighting model (classic deferred path).
//
// Differences from IX-Ray's stock legacy ambient (metalic_roughness_ambient):
// - hscale = h, no normal influence (SoC/CS/LA behavior)
// - Luminance/chrominance decoupling: cubemap normalized to unit luminance for
//   chroma; brightness comes from weather L_hemi_color * lumscale * intensity
// - hemi vibrance (weather key) via hemi_parameters.x
// - Material-based cubemap mips (diffuse/specular)
// - Sun chrominance split (SH probe direction stubbed to zero until the
//   Dynamic Indirect Light probe system exists)
// - Wet surface gloss boost + water-film Fresnel sheen (owa_wetness)
// - Schlick metalness fresnel on env specular
//
// Binder compensation note: IX-Ray's L_hemi_color binder bakes
// lumscale_hemi*4 and L_ambient bakes lumscale_amb*2, while this model wants
// net multipliers lumscale_hemi*2 and raw ambient*1 — so the defines below
// compensate the baked factors to net out correctly.
// ============================================================================

#include "owa_material.hlsli"
#include "owa_wetness.hlsli"
#include "owa_oklab.hlsli"

// OWA: Hemi intensity multiplier - compensates for cubemap luminance decoupling
#define OWA_HEMI_INTENSITY_MUL 2.0

// IX-Ray binder compensation (see header note):
// - hemi: L_hemi_color bakes lumscale_hemi*4, the model wants lumscale_hemi*2
//   net -> x0.5
// - ambient: L_ambient bakes lumscale_amb*2 and the model adds RAW ambient,
//   so the compensation needs the lumscale value -> bound as L_lumscale.z
//   (uniform slot layout: x=sun, y=hemi, z=amb).
#ifndef OWA_LUMSCALE_DECLARED
#define OWA_LUMSCALE_DECLARED
uniform float4 L_lumscale; // x=sun, y=hemi, z=amb (IX-Ray console values)
#endif
#define OWA_ENV_BINDER_COMPENSATION 0.5
#define OWA_AMBIENT_BINDER_COMPENSATION rcp(2.0 * L_lumscale.z)

// OWA: Env cubemaps + color multiplier
// env_color: xyz = color multiplier, w = blend factor (bound by phase_combine)
#ifndef OWA_ENV_DECLARED
#define OWA_ENV_DECLARED
uniform float4 env_color;
uniform float4 rain_params; // x = rain density, y = accumulated wetness, w = snowmask
#endif

// OWA: Hemi/weather parameters (semantics carried over from OW's
// hmodel_stuff slot):
// x = hemi vibrance (weather key hemi_vibrance)
// y = hemi contrast (weather key hemi_contrast)
// z = wet surface factor (weather key wet_surface_factor)
// w = reserved
uniform float4 hemi_parameters;

//=============================================================================
// OWA: Sun Chrominance Split
// Blends hemisphere chrominance toward warm (sun-facing) or cool (sky-facing).
//
// Parameters:
//   chroma      - Input chrominance to modulate (neutral = float3(1,1,1))
//   nw          - World-space surface normal
//   sh_dir_ws   - World-space SH primary direction (stub float3(0,0,0) until
//                 the Dynamic Indirect Light probe system provides it).
//   sky_chroma  - Pre-vibrance cubemap chrominance (env_d_chroma from caller).
//
// Uses Ldynamic_dir (world-space sun direction) and Ldynamic_color as globals.
// Strength scales to zero at night so there is no effect when the sun is dim.
//=============================================================================
float3 OWA_SunChrominanceSplit(float3 chroma, float3 nw, float3 sh_dir_ws, float3 sky_chroma)
{
    // World-space toward-sun direction (-Ldynamic_dir is toward the sun)
    float3 sun_dir_ws = normalize(-Ldynamic_dir.xyz);

    // Sun chrominance: the sun's pure hue without its brightness
    float sun_lum = dot(Ldynamic_color.rgb, float3(0.2126, 0.7152, 0.0722));
    float3 sun_chroma = Ldynamic_color.rgb / max(sun_lum, 0.001);

    // Base facing factor: 0 = surface points away from sun, 1 = toward sun
    float sun_facing = dot(nw, sun_dir_ws) * 0.5 + 0.5;

    // SH modulation: skipped while the SH probe direction is stubbed to zero.
    float sh_mag = length(sh_dir_ws);
    if (sh_mag > 0.001)
    {
        float sh_facing = dot(nw, sh_dir_ws / sh_mag) * 0.5 + 0.5;
        sun_facing = lerp(sun_facing, sh_facing, saturate(sh_mag * 3.0));
    }

    // Chrominance target: sun_chroma when facing sun, sky_chroma when facing away.
    float3 dir_chroma = lerp(sky_chroma, sun_chroma, sun_facing);

    // Scale effect by sun brightness - no chrominance split at night
    float strength = 0.15 * saturate(sun_lum * 2.0);

    return lerp(chroma, dir_chroma, strength);
}

//=============================================================================
// OWA: Hemisphere lighting (classic deferred style)
// m     - material LUT coordinate (gbuffer Metalness channel: THM material
//         value (mtl+0.5)/4, range 0.125-1.125 with weight)
// sss   - gbuffer SSS channel (1.0 for engine-flagged flora; carries the
//         static-sun factor under USE_R2_STATIC_SUN - owa_is_flora guards)
// h     - hemispheric light factor
// gloss - surface gloss
// Pnt   - view-space position
// normal- view-space normal
//=============================================================================
void owa_hemisphere
(
	out float3 hdiffuse, out float3 hspecular,
	float m, float h, float gloss, float3 Pnt, float3 normal, float sss
)
{
	normal = normalize(normal);

	// OWA: Wetness factor for wet surface effects
	// rain_params.y = accumulated wetness (0-1, gradual accumulation/drying)
	float wetness = rain_params.y;

// hscale - something like diffuse reflection
	float3	nw		= mul((float3x3)m_invV, normal );

	// OWA: Classic deferred style - no normal influence on hscale
	// All S.T.A.L.K.E.R. deferred renderers (SoC R2, CS R2, LA R2/R3) use hscale = h
	float	hscale = h;

// reflection vector
	float3	v2PntL	= normalize( Pnt );
	float3	v2Pnt	= mul((float3x3)m_invV, v2PntL );
	float3	vreflect= reflect( v2Pnt, nw );
	float	hspec	= .5h + .5h * dot( vreflect, v2Pnt );

// material	// sample material
	float4	light	= s_material.SampleLevel( smp_material, float3( hscale, hspec, m ), 0 ).xxxy;

// diffuse color
	// OWA: Material-based cubemap blur for diffuse hemisphere lighting.
	// The LUT coordinate m is the THM material value (baselines 0.125/0.375/
	// 0.625/0.875, shifted up by material_weight, live range up to 1.125):
	// everything below 0.5 (the two diffuse-ish clusters) uses the blurriest
	// diffuse mip, metallic baselines sharpen toward mip 0.
	float diff_mip = (m < 0.5) ? 7.0 : lerp(4.0, 0.0, saturate((m - 0.5) * 4.0));

	float3	e0d		= env_s0.SampleLevel( smp_rtlinear, nw, diff_mip );
	float3	e1d		= env_s1.SampleLevel( smp_rtlinear, nw, diff_mip );
	float3	env_d	= env_color.xyz * lerp( e0d, e1d, env_color.w );

	// OWA: Separate luminance and chrominance for hemi lighting
	// Cubemap normalized to unit luminance: weather hemi controls brightness,
	// cubemap only contributes color variation.
	float env_d_lum = dot(env_d, float3(0.2126, 0.7152, 0.0722));
	float3 env_d_chroma = env_d / max(env_d_lum, 0.001);

	// Apply hemi vibrance (hemi_parameters.x)
	// 0 = neutral white (no color tinting), 1 = full cubemap color tinting
	float3 env_d_color = lerp(float3(1.0, 1.0, 1.0), env_d_chroma, saturate(hemi_parameters.x));

	// OWA: Wet surface gloss boost (classic materials)
	// Bring low-gloss surfaces up toward wet_gloss_max, add extra boost proportional to roughness
	float wet_gloss_max = 0.85;  // Maximum gloss when fully wet
	float wet_gloss_add = wetness * 0.35;  // Add up to 0.35 gloss
	float wet_gloss = saturate(lerp(gloss, max(gloss, wet_gloss_max), wetness) + wet_gloss_add * (1.0 - gloss));

	// OWA: Directional chrominance split (no probe data available yet — zero stub)
	float3 env_d_color_split = OWA_SunChrominanceSplit(env_d_color, nw, float3(0, 0, 0), env_d_chroma);

	// OWA: Weather hemi controls brightness via L_hemi_color (binder-compensated)
	hdiffuse = env_d_color_split * light.xyz * L_hemi_color.rgb * OWA_ENV_BINDER_COMPENSATION * OWA_HEMI_INTENSITY_MUL + L_ambient.rgb * OWA_AMBIENT_BINDER_COMPENSATION;

// specular color
	float3 vreflectabs    = abs(vreflect);
    float  vreflectmax    = max(vreflectabs.x, max(vreflectabs.y, vreflectabs.z));
           vreflect      /= vreflectmax;

	// OWA: Classic deferred style - unconditional Y remap
	if (vreflect.y < 0.999)
		vreflect.y = vreflect.y*2-1;     // fake remapping

	// OWA: Material-based cubemap blur - diffuse materials get blurry reflections
	float spec_mip = (1.0 - saturate(m * 1.5)) * 6.0;  // m=0 → mip 6, m>=0.67 → mip 0

	float3	e0s		= env_s0.SampleLevel( smp_rtlinear, vreflect, spec_mip );
	float3	e1s		= env_s1.SampleLevel( smp_rtlinear, vreflect, spec_mip );
	float3	env_s	= env_color.xyz * lerp( e0s, e1s, env_color.w);

	hspecular = env_s * light.w * wet_gloss;

	// OWA: Metalness fresnel - adds Schlick fresnel for metallic materials
	if (!owa_skip_fresnel(sss))
	{
		float metalness = owa_calc_metalness(m);
		float NdotV = saturate(dot(nw, -v2Pnt));

		// Use environment specular luminance to scale fresnel intensity
		float env_luminance = dot(env_s, float3(0.2126f, 0.7152f, 0.0722f));
		float fresnel_boost = owa_compute_fresnel(NdotV, metalness, env_luminance);

		// Apply AA'd mip to fresnel reflection to reduce shimmer on metal edges
		float fresnel_rough_aa = specAA_rough_env(nw, 0.3);
		float3 e0s_f = env_s0.SampleLevel(smp_rtlinear, vreflect, fresnel_rough_aa * 6.0);
		float3 e1s_f = env_s1.SampleLevel(smp_rtlinear, vreflect, fresnel_rough_aa * 6.0);
		float3 env_s_f = env_color.xyz * lerp(e0s_f, e1s_f, env_color.w);

		hspecular += env_s_f * fresnel_boost;
	}

	// OWA: Wet surface Fresnel sheen (classic path)
	// Water has strong Fresnel (F0=0.02, F90~1.0) - wet surfaces show pronounced edge reflections
	if (wetness > 0.01)
	{
		float NdotV_wet = saturate(dot(nw, -v2Pnt));
		float wet_rough_aa = specAA_rough_env(nw, 0.12);
		float grazing = pow(1.0 - NdotV_wet, 3.0);

		// Scale by wetness and material porosity (porous materials absorb more water = weaker sheen)
		// OWA: Engine-flagged flora is fully porous (no water film on foliage)
		float porosity = saturate(1.0 - m * 1.5);
		if (owa_is_flora(sss))
			porosity = 1.0;
		float sheen_strength = wetness * (1.0 - porosity * 0.3);

		float3 e0s_wet = env_s0.SampleLevel(smp_rtlinear, vreflect, wet_rough_aa * 6.0);
		float3 e1s_wet = env_s1.SampleLevel(smp_rtlinear, vreflect, wet_rough_aa * 6.0);
		float3 env_s_wet = env_color.xyz * lerp(e0s_wet, e1s_wet, env_color.w);

		hspecular += env_s_wet * grazing * sheen_strength * 0.25;
	}
}

#endif // OWA_HEMISPHERE_H_INCLUDED
