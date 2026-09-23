#include "common.hlsli"
#include "tonemapping.hlsli"

struct v2p
{
    float2 tc0 : TEXCOORD0;
    float4 c : COLOR0;

//	Igor: for additional depth dest
#ifdef USE_SOFT_PARTICLES
    float4 tctexgen : TEXCOORD1;
#endif //	USE_SOFT_PARTICLES

    float4 hpos : SV_POSITION;
    float fog : FOG;
};

// Pixel
float4 main(v2p I) : SV_Target
{
    float4 result = I.c * s_base.Sample(smp_base, I.tc0);

    // OWA: HDR particle expansion for emissive particles (fire, sparks, muzzle flash)
    // HDR-only (dormant while hdr10_on = 0): TONEMAP_PARTICLE_EXPANSION
    // scales it: 0=none, 1.0=default (3x max), higher=more
    if (TONEMAP_IS_HDR) {
        float particle_lum = Luminance_Rec709(result.rgb);

        float max_c = max(result.r, max(result.g, result.b));
        float min_c = min(result.r, min(result.g, result.b));
        float saturation = (max_c > 0.001) ? (max_c - min_c) / max_c : 0.0;

        float high_lum_factor = smoothstep(0.7, 0.9, particle_lum);  // Very bright = expand
        float sat_factor = smoothstep(0.25, 0.5, saturation);       // Has color = expand
        float mid_lum_factor = smoothstep(0.4, 0.7, particle_lum);  // Medium bright

        float expansion_t = max(high_lum_factor, mid_lum_factor * sat_factor);
        float base_expansion = 3.0 * TONEMAP_PARTICLE_EXPANSION;
        float expansion_factor = 1.0 + expansion_t * base_expansion;

        result.rgb *= expansion_factor;
    }

    //	Igor: additional depth test
#ifdef USE_SOFT_PARTICLES
    float4 Point = GbufferGetPoint(I.hpos.xy);
    float spaceDepth = Point.z - I.tctexgen.z;
    result *= Contrast(saturate(spaceDepth * 1.3f), 2.0f);
#endif //	USE_SOFT_PARTICLES

    clip(result.a - (0.01f / 255.0f));
    return PushGamma(lerp(fog_color, result, I.fog));
}

