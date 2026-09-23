#ifndef metalic_roughness_light_h_ixray_included
#define metalic_roughness_light_h_ixray_included

#include "common.hlsli"
#include "owa_material.hlsli"

float DistributionGGX(float NdotH, float Roughness)
{
    float Alpha = Roughness * Roughness;
    float AlphaTwo = Alpha * Alpha;

    float AlphaTwoInv = AlphaTwo - 1.0f;

    float Divider = NdotH * NdotH * AlphaTwoInv + 1.0f;
    return AlphaTwo * rcp(Divider * Divider);
}

// OWA: Soft sqrt attenuation — matches the static light path aesthetic.
// Gradual falloff from center outward; iso-intensity contours on flat
// surfaces are softer and blend into the surroundings rather than reading as
// a hard disc. (Replaces the vanilla q-linear attenuation.)
float ComputeLightAttention(float3 PointToLight, float MinAttention, float NdotL)
{
    float dist_normalized = sqrt(dot(PointToLight, PointToLight) * MinAttention);
    float att = saturate(1.0f - dist_normalized);
    att *= att; // slight squaring for shaping (still softer than Karis midrange)

    // OWA: Seam blend — tie the range boundary fade to surface orientation.
    // At the light center (att≈1): no effect. At the range boundary (att≈0): full
    // NdotL weight. Softens the circular seam edge on flat perpendicular geometry.
    att *= lerp(NdotL, 1.0f, att);
    return att;
}

float GeometrySmithD(float NdotL, float NdotV, float Roughness)
{
    float R = Roughness + 1.0f;
    float K = R * R * 0.125f;
    float InvK = 1.0f - K;

    float DivGGXL = 1.0f * rcp(K + NdotL * InvK);
    float DivGGXV = 1.0f * rcp(K + NdotV * InvK);

    return 0.25f * DivGGXL * DivGGXV;
}

float3 FresnelSchlick(float3 F, float NdotV)
{
    return F + (1.0f - F) * pow(1.0f - NdotV, 5.0f);
}

#ifdef USE_LEGACY_LIGHT
// OWA: Material response tuple (legacy LUT path).
// rgb = LUT diffuse response (terminator-contrasted for directional light)
// a   = LUT specular response + Schlick metalness fresnel boost
// The accumulator stores rgb=diffuse response, a=specular response; albedo and
// gloss are applied once at combine stage.
// FloraSignal: the gbuffer SSS flora marker (0 when unavailable - e.g. under
// static sun the channel carries the static-sun factor instead).
float4 DirectLightResponse(float4 Radiance, float3 Light, float3 Normal, float3 View, float Metalness, float Roughness, const bool Directional, float FloraSignal = 0.0f)
{
    float3 Half = normalize(Light + View);

    float NdotL = max(0.0f, -dot(Normal, Light));
    float NdotH = max(0.0f, -dot(Normal, Half));

    float2 Material = s_material.SampleLevel(smp_material, float3(NdotL, NdotH, Metalness), 0).xy;
    float4 Response = float4(Material.x, Material.x, Material.x, Material.y);

    // OWA: Metalness fresnel - adds Schlick fresnel for metallic materials
    if (!owa_skip_fresnel(FloraSignal))
    {
        float NdotV = max(0.0f, -dot(Normal, View));
        Response.a += owa_compute_fresnel(NdotV, owa_calc_metalness(Metalness), Material.x);
    }

    // OWA: Shadow terminator contrast shaping — directional (sun/sky) light only.
    // For omni lights this creates visible NdotL isocontour rings; directional
    // lights have no such geometry, so the effect reads as natural shading.
    if (Directional)
        Response.rgb *= owa_terminator_contrast(NdotL);

    return Response;
}
#endif

float3 SimpleTranslucencyResponse(float3 Light, float3 Normal)
{
	float NdotL = dot(Light, Normal);
	float Scale = 0.36f * NdotL;

	float Attention = Scale + 0.0769f; Attention *= Attention * 1.171f;
	float Factor = 1.0f - saturate(abs(Scale) * 13.0f - 1.0f);

	float SSS = lerp(saturate(NdotL), Attention, Factor * Factor);
	return saturate(3.5f * SSS + 0.1f);
}

float3 DirectLight(float4 Radiance, float3 Light, float3 Normal, float3 View, float3 Color, float Metalness, float Roughness, float3 F0 = 0.04f)
{
    float3 Half = normalize(Light + View);

    float NdotL = max(0.0f, -dot(Normal, Light));
    float NdotH = max(0.0f, -dot(Normal, Half));

#ifndef USE_LEGACY_LIGHT
    float NdotV = max(0.0f, -dot(Normal, View));
    float HdotV = max(0.0f, dot(Half, View));

    float3 D = DistributionGGX(NdotH, Roughness);
    float3 G = GeometrySmithD(NdotL, NdotV, Roughness);
    float3 F = FresnelSchlick(lerp(F0, Color, Metalness), HdotV);

    float3 Specular = D * G;
    float3 Diffuse = Color * (1.0f - Metalness);

    float3 BRDF = lerp(Diffuse, Specular, F);
    return PushGamma(Radiance.xyz) * NdotL * BRDF;
#else
    // Albedo-applied wrapper (forward/length-buffer paths only; the deferred
    // accumulator uses DirectLightResponse + combine-stage composition).
    float4 Response = DirectLightResponse(Radiance, Light, Normal, View, Metalness, Roughness, false);
    return Radiance.xyz * (Response.rgb * Color.xyz + Response.a * Roughness * Radiance.w);
#endif
}

float3 SimpleTranslucency(float3 Radiance, float3 Light, float3 Normal)
{
	return PushGamma(Radiance) * SimpleTranslucencyResponse(Light, Normal);
}

#endif

