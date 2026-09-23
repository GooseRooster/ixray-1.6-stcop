#include "common.hlsli"
#include "mblur.hlsli"
#include "dof.hlsli"

Texture3D s_lut;

float3 main(v2p_aa_AA I) : SV_Target
{
    float3 Color = max(0.0f, dof(I.Tex0));
    float4 Bloom = s_bloom.Sample(smp_rtlinear, I.Tex0);

#ifdef USE_CGIM_BLOOM_TWEAK
	Bloom = BrokeBloom(Bloom);
#endif

    // OWA: no tonemapping here anymore - the hermite spline tonemap runs once
    // at the final quad (gamma_apply stage). The old bloom compose stays until
    // the Kawase bloom replaces it.
    Color = combine_bloom(Color, Bloom).xyz;

#ifdef USE_CGIM_COLOR_TWEAK
	Color = Uncharted2Tonemap(Color);
#endif
	
#ifdef USE_LUT_TEXTURE
 	Color = s_lut.Sample(smp_rtlinear, saturate(Color)).xyz;
#endif

	return Color;
}

