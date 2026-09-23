#include "common.hlsli"
#include "tonemapping.hlsli"

// OWA: This stage is the end-of-chain tonemapper. Input: gamma-encoded scene
// from the game postprocess quad (rt_BackbufferLUT). ApplyTonemap_World
// linearizes with pure 2.2, applies LogC color grading, runs the BT.2408
// hermite spline, and encodes to sRGB for the swapchain. The legacy
// rs_c_gamma/brightness/contrast pass is superseded here; the engine still
// binds color_params/color_grading but the shader no longer consumes them.

struct PSInput
{
    float4 hpos : SV_POSITION;
    float2 texcoord : TEXCOORD0;
};

float4 main(in PSInput I) : SV_Target
{
	float3 color = s_image.Sample(smp_nofilter, I.texcoord.xy).xyz;

	color = ApplyTonemap_World(color);

    color = deband_color(color, I.texcoord.xy);
	return float4(color, 1.0f);
}
