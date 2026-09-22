#include "common.hlsli"

#if defined(USE_OFFSCREEN_REFLECTIONS) && !defined(USE_SSLR_REFLECTIONS)
#define USE_VIEW_REFLECTIONS
#endif

#include "owa_hemisphere.hlsli"
#include "metalic_roughness_light.hlsli"
#include "metalic_roughness_ambient.hlsli"
#include "reflections.hlsli"

Texture2D<float> s_occ;

// OWA texture contrast (Build 3120 style) — 0-1 range, scales effect strength
uniform float4 tex_contrast;

struct _input
{
    float4 tc0 : TEXCOORD0;
    float2 tcJ : TEXCOORD1;
    float4 pos2d : SV_POSITION;
};

float4 main(_input I) : SV_Target
{
    IXrayGbuffer O;
    GbufferUnpack(I.tc0.xy, I.pos2d.xy, O);
    float4 Light = s_accumulator.Load(int3(I.pos2d.xy, 0));

    float Occ = O.AO * s_occ.SampleLevel(smp_rtlinear, I.tc0.xy, 0.0f).x;

#ifndef USE_LEGACY_LIGHT
	#ifdef USE_R2_STATIC_SUN
		Light.rgb += O.SSS * DirectLight(Ldynamic_color, Ldynamic_dir.xyz, O.Normal, O.View.xyz, O.Color, O.Metalness, O.Roughness, O.F0);
	#endif

	#ifdef USE_SSLR_REFLECTIONS
		float3 SpecularIrradance = s_refl.SampleLevel(smp_rtlinear, I.tc0, 0.0).xyz;
		SpecularIrradance *= rcp(1.00001f - SpecularIrradance);
	#else
		float3 SpecularIrradance = CompureSpecularIrradance(reflect(O.View, O.Normal), O.Hemi, O.Roughness);
	#endif

	float3 DiffuseIrradance = CompureDiffuseIrradance(O.Normal, O.Hemi) + L_ambient.xyz;
    float3 Ambient = AmbientLighting(DiffuseIrradance, SpecularIrradance, max(0.0, dot(O.Normal, -O.View.xyz)), O.Color, O.Metalness, O.Roughness, O.F0);
    float3 Color = Occ * Ambient + Light.rgb;
#else
    // OWA: Hemisphere lighting model (OW hmodel port)
    float3 hdiffuse, hspecular;
    owa_hemisphere(hdiffuse, hspecular, O.Metalness, O.Hemi, O.Roughness, O.Point.xyz, O.Normal);

    // OWA: Static sun - material response tuple (directional), scaled by SSS mask.
    float4 sun_static = 0.0f;
    #ifdef USE_R2_STATIC_SUN
        float4 sun_response = DirectLightResponse(Ldynamic_color, Ldynamic_dir.xyz, O.Normal, O.View.xyz, O.Metalness, O.Roughness, true);
        sun_static = Ldynamic_color * sun_response * O.SSS;
    #endif

    // OWA: Porosity-based wet albedo darkening
    float wetness = rain_params.y;
    float3 albedo = O.Color.rgb * calc_wet_albedo_factor_simple(wetness, O.Metalness);

    // OWA texture contrast boost (Build 3120 style)
    // tex_contrast.x: 0-1 range - scales texture contrast effect strength
    // Full effect multiplies hemisphere lighting by texture color for punchier textures
    float3 contrast_hdiffuse = hdiffuse * (albedo * 0.60 + 0.40);
    hdiffuse = oklab_lerp(hdiffuse, contrast_hdiffuse, tex_contrast.x);

    // OWA Unified Pipeline: Allow values to exceed 1.0 - final tonemapping
    // (hermite spline, Phase 3) will handle highlight compression
    hdiffuse.rgb = max(0, hdiffuse.rgb);

    // OWA: Multibounce AO is deferred to the DIL phase; screen-space AO applies
    // to ambient only (direct light is shadowed by the sun shadow map).
    hdiffuse *= Occ;
    hspecular *= Occ;

    // OWA: Albedo and gloss applied once here (OW composition):
    // light = direct response + hemi; C = albedo.gloss * light(diffuse.specular)
    float4 light = float4(Light.rgb + hdiffuse + sun_static.rgb, Light.a + sun_static.a);
    float4 C = float4(albedo, O.Roughness) * light;

    // OWA: Direct specular blends toward the raw sun color.
    // Light.rgb bakes in the material LUT diffuse response which dampens
    // specular on rough surfaces. Blending 35% toward the pure sun color gives
    // highlights their proper chromatic intensity. (Phase 3 swaps in the
    // light-expanded sun color.)
    float3 owa_spec_light = lerp(Light.rgb, Ldynamic_color.rgb, 0.35f);
    float3 spec = hspecular * C.rgb + C.w * lerp(C.rgb, 1.0h, 0.5h) * owa_spec_light;

    float3 Color = C.rgb + spec;
#endif

    float Fog = PushGamma(saturate(O.ViewDist * fog_params.w + fog_params.x));
    Color = lerp(Color, PushGamma(fog_color.xyz), Fog);

#ifdef USE_LEGACY_LIGHT
	Fog *= Fog;
#endif

    return float4(Color, Fog);
}
