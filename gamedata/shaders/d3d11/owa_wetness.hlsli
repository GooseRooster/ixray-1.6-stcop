#ifndef OWA_WETNESS_H_INCLUDED
#define OWA_WETNESS_H_INCLUDED

// OWA Wetness System (ported from OW owa_wetness.h, verbatim).
// Provides physically-based wetness effects:
// - Porosity-based albedo darkening (porous materials absorb more light when wet)
// - Water film F0 overlay (wet surfaces gain water's reflectance characteristics)
//
// Usage:
//   float wetness = rain_params.y;  // 0-1 accumulated wetness
//   albedo.rgb *= calc_wet_albedo_factor(wetness, material_ID, metalness);
//   f0 = calc_wet_specular_f0(f0, wetness, metalness);

//=============================================================================
// Porosity-Based Albedo Darkening
//=============================================================================
// Physical basis: When surfaces get wet, light enters the water layer and
// bounces around before being absorbed. This makes wet surfaces appear darker.
// The effect is strongest on porous materials (concrete, fabric, soil) which
// absorb water into their microstructure. Non-porous materials (metal, plastic)
// bead water on the surface and show minimal darkening.
//
// Material ID mapping (after engine transform):
//   0 = OrenNayar (~0.125)  - organic/fabric/skin - HIGH porosity
//   1 = Blinn_Phong (~0.375) - plastic/hard surfaces - MEDIUM porosity
//   2 = Phong_Metal (~0.625) - metal - LOW porosity
//   3 = Metal_OrenNayar (~0.875) - rough metal - LOW porosity
//
// Returns: multiplier for albedo (1.0 = no change, <1.0 = darker)
//=============================================================================
float calc_wet_albedo_factor(float wetness, float material_ID, float metalness)
{
    // Porosity: porous materials darken more when wet
    // Low material ID = high porosity = more darkening
    // The 1.5 factor maps: mat_id 0 -> porosity ~1.0, mat_id 0.67+ -> porosity ~0
    float porosity = saturate(1.0 - material_ID * 1.5);

    // Metals bead water instead of absorbing it - minimal darkening
    // Reduce porosity effect by 80% for metals
    porosity *= (1.0 - metalness * 0.8);

    // Darkening factor: fully wet porous surface darkens to ~35% of original
    // This matches real-world observations of wet concrete, fabric, etc.
    float dark_factor = lerp(1.0, 0.35, porosity);

    // Apply based on wetness level
    return lerp(1.0, dark_factor, wetness);
}

//=============================================================================
// Water Film F0 Modification
//=============================================================================
// Physical basis: Water has a specific index of refraction (n ≈ 1.33) which
// gives it F0 ≈ 0.02 (2% reflectance at normal incidence). When a surface is
// wet, a water film forms on top, and this water film becomes the primary
// optical boundary. The water's F0 overlays on top of the surface's F0.
//
// Note: the classic (LUT) material path does not consume F0 — this helper is
// kept for the dormant PBR branch, exactly as in OW.
//=============================================================================
float3 calc_wet_specular_f0(float3 dry_f0, float wetness, float metalness)
{
    // Water F0 at normal incidence (n=1.33 -> F0 = ((1.33-1)/(1.33+1))^2 ≈ 0.02)
    float3 water_f0 = float3(0.02, 0.02, 0.02);

    // Metals bead water - reduced F0 blending
    // Non-metals get full water film overlay
    float blend = wetness * (1.0 - metalness * 0.5);

    // For non-metals: lerp toward water F0 (increases reflectance for most materials)
    // For metals: use max() to layer water on top without reducing metallic reflections
    float3 wet_f0 = lerp(dry_f0, water_f0, blend * (1.0 - metalness));

    // For metals, just add a slight water sheen on top
    wet_f0 = lerp(wet_f0, max(dry_f0, dry_f0 + water_f0 * blend), metalness);

    return wet_f0;
}

//=============================================================================
// Combined Wetness Application (convenience function)
//=============================================================================
void apply_wetness_effects(
    inout float3 albedo,
    inout float3 f0,
    float wetness,
    float material_ID,
    float metalness)
{
    albedo *= calc_wet_albedo_factor(wetness, material_ID, metalness);
    f0 = calc_wet_specular_f0(f0, wetness, metalness);
}

//=============================================================================
// Simplified Albedo Darkening (for combine shader)
//=============================================================================
// This version uses only material_ID, suitable for combine pass where
// metalness calculation may not be available (non-PBR path).
//=============================================================================
float calc_wet_albedo_factor_simple(float wetness, float material_ID)
{
    // Porosity from material ID
    float porosity = saturate(1.0 - material_ID * 1.5);

    // Darkening factor
    float dark_factor = lerp(1.0, 0.35, porosity);

    return lerp(1.0, dark_factor, wetness);
}

#endif // OWA_WETNESS_H_INCLUDED
