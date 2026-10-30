#[compute]
#version 450

// =============================================================================
// GROUND HEAT GENERATOR
// Compute pass that calculates surface bedrock temperature from insolation and geothermal heat flux.
// Physical units: Ground surface temperature in °C.
// Bindings: Reads bedrock height and solar insolation from write_tex (Set 0, Binding 0);
//           Reads geothermal heat flux from atomic_tex (Set 0, Binding 2);
//           Writes ground temperature to write_tex (Set 0, Binding 0).
// =============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// === UNIFIED GENERATOR UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f)   | 1: Fine Float Read (r16f)    | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)       | 4: SSBO Read (std430)        | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f) | 7: Coarse Float Read (r32f) | 15: Custom Noise Read (r32f)
layout(r16f, set = 0, binding = 0) restrict uniform image2DArray write_tex;
layout(r16f, set = 0, binding = 1) restrict readonly uniform image2DArray read_tex;
layout(r32ui, set = 0, binding = 2) uniform uimage2DArray atomic_tex;
layout(r16f, set = 0, binding = 5) restrict writeonly uniform image2DArray atomic_vis_tex;
layout(r32f, set = 0, binding = 6) restrict uniform image2DArray coarse_write_tex;
layout(r32f, set = 0, binding = 7) restrict readonly uniform image2DArray coarse_read_tex;
layout(r32f, set = 0, binding = 15) restrict readonly uniform image2DArray custom_tex;

layout(push_constant) uniform Params {
    int f_ground_temp;    // Index of ground temperature layer in float texture array
    int f_bedrock_height; // Index of bedrock elevation layer in float texture array
    int f_sunlight;       // Index of solar insolation layer in float texture array

    int a_atomic_geothermal; // Index of geothermal heat layer in atomic texture array

    float solar_heat_scale;      // Conversion scale from dimensionless sunlight to °C (e.g., 35.0)
    float geothermal_heat_scale; // Multiplier converting geothermal flux to surface warming in °C (e.g., 1.0)
    float lapse_rate;            // Thermal drop with increasing elevation in °C per normalized altitude unit
    float atomic_multiplier;     // Scale factor converting fixed-point uint to physical float
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    // Read bedrock elevation in hectometers and solar insolation [0, 1]
    float altitude = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
    float sunlight = imageLoad(write_tex, ivec3(id.xy, params.f_sunlight)).r;
    
    // Read crustal geothermal heat flux from atomic storage and convert to float units
    uint geo_uint = imageLoad(atomic_tex, ivec3(id.xy, params.a_atomic_geothermal)).r;
    float geothermal = float(geo_uint) / params.atomic_multiplier;
    
    // Sum absorbed solar radiation and internal geothermal energy into surface ground heat
    float ground_heat = (sunlight * params.solar_heat_scale) + (geothermal * params.geothermal_heat_scale);
    
    // Deduct altitude cooling based on elevation above sea level
    float normalized_alt = altitude / 200.0;
    float final_temp = ground_heat - (normalized_alt * params.lapse_rate);
    
    // Blend toward deep-freeze temperatures (-50°C) near outer polar boundaries
    float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
    float pole_threshold = float(size.y) * 0.05;
    float pole_mask = smoothstep(0.0, pole_threshold, dist_from_pole);
    final_temp = mix(-50.0, final_temp, pole_mask);

    // Store calculated ground temperature in the landscape layer of the float texture array
    imageStore(write_tex, ivec3(id.xy, params.f_ground_temp), vec4(final_temp, 0.0, 0.0, 0.0));
}


