#include "common.hlsli"
#include "shadow.hlsli"

#include "metalic_roughness_light.hlsli"
#include "ScreenSpaceContactShadows.hlsl"

uniform float4 m_lmap[2];
uniform int Ldynamic_hud;

//LVutner: Force early-z
[earlydepthstencil]
float4 main(p_volume I, float4 pos2d : SV_POSITION) : SV_Target
{
    float2 tcProj = I.tc.xy / I.tc.w;
	
    IXrayGbuffer O;
    GbufferUnpack(tcProj, pos2d.xy, O);

    // OWA: Flora fix always on - align normal to light, soften gloss
    if (owa_is_flora(O.Metalness))
    {
        O.Normal = lerp(O.Normal, -normalize(O.Point.xyz - Ldynamic_pos.xyz), 0.5f);
        O.Roughness *= 0.5f;
    }

    float4 Point = float4(Ldynamic_hud > 0 ? O.PointHud.xyz : O.Point.xyz, 1.0f);

	float3 LightDirection = normalize(O.PointReal.xyz - Ldynamic_pos.xyz);

    // OWA: Direct lighting as material response tuple (rgb = LUT diffuse
    // response, a = specular response + fresnel). Albedo/gloss applied at
    // combine stage.
    float4 light = DirectLightResponse(Ldynamic_color, LightDirection, O.Normal, O.View.xyz, O.Metalness, O.Roughness, false);

    // OWA: Soft sqrt attenuation + seam blend (replaces vanilla q-linear).
    float att = ComputeLightAttention(Point.xyz - Ldynamic_pos.xyz, Ldynamic_pos.w, saturate(-dot(O.Normal, LightDirection)));
    light.rgb *= att;
    light.a *= att;
    Point.xyz += O.Normal * 0.025f;

    float4 PS = mul(m_shadow, Point);

    float3 Shadow = 1.0f;
#ifdef USE_SHADOW
    Shadow = max(Ldynamic_hud, shadow(PS));

    #ifdef USE_HUD_SHADOWS
		if (O.Depth < 0.02f && dot(Shadow * light.rgb, float3(1.0f, 1.0f, 1.0f)) > 0.0001f)
		{
			RayTraceContactShadow(tcProj, O.PointHud, LightDirection, Shadow);
		}
    #endif
#endif

    float4 Lightmap = 1.0f;
#ifdef USE_LMAP
    #ifdef USE_LMAPXFORM
		PS.x = dot(Point, m_lmap[0]);
		PS.y = dot(Point, m_lmap[1]);
    #endif
    Lightmap = s_lmap.SampleLevel(smp_rtlinear, PS.xy / PS.w, 0.0f);
#endif

	Lightmap = PushGamma(Lightmap);

    // OWA: rgb = light color × diffuse response × shadow × cookie (albedo at
    // combine); a = specular response × shadow × cookie alpha.
    return float4(Ldynamic_color.rgb * light.rgb * Shadow * Lightmap.rgb, light.a * Shadow.x * Lightmap.a);
}


