#[compute]
#version 450

// =============================================================================
// AIR TEMP GENERATOR
// Compute pass that initializes surface atmospheric temperatures across the globe.
// Physical units: Air temperature in °C.
// Bindings: Reads bedrock height, ground temperature, and solar insolation from write_tex (Set 0, Binding 0);
//           Writes air temperature to write_tex (Set 0, Binding 0).
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
    int f_air_temp;       // Index of air temperature layer in float texture array
    int f_bedrock_height; // Index of bedrock elevation layer in float texture array
    int f_ground_temp;    // Index of ground temperature layer in float texture array
    int f_sunlight;       // Index of solar insolation layer in float texture array

    float equator_temp;      // Baseline equatorial air temperature in °C (e.g., 40.0)
    float pole_temp;         // Baseline polar air temperature in °C (e.g., -30.0)
    float ground_mix_factor; // Fraction of ground heat conductively transferred to overlying air (e.g., 0.4)
    float lapse_rate;        // Atmospheric temperature decrease with elevation in °C per normalized altitude unit
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    // Read surface elevation, ground temperature, and solar insolation from the float cache
    float altitude = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
    float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
    float sunlight = imageLoad(write_tex, ivec3(id.xy, params.f_sunlight)).r;
    
    // Compute radiative air temperature baseline interpolated between polar and equatorial limits by solar flux
    float lat_base_temp = mix(params.pole_temp, params.equator_temp, sunlight);
    
    // Blend radiative air temperature with surface ground temperature to account for ground thermal conductivity
    float base_air = mix(lat_base_temp, ground_temp, params.ground_mix_factor);
    
    // Apply environmental lapse rate cooling: higher elevations experience colder air temperatures
    float normalized_alt = altitude / 200.0;
    float final_air_temp = base_air - (normalized_alt * params.lapse_rate);
    
    // Blend toward deep-freeze temperatures (-50°C) near outer polar edges
    float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
    float pole_threshold = float(size.y) * 0.05;
    float pole_mask = smoothstep(0.0, pole_threshold, dist_from_pole);
    final_air_temp = mix(-50.0, final_air_temp, pole_mask);

    // Store calculated air temperature in the atmospheric layer of the float texture array
    imageStore(write_tex, ivec3(id.xy, params.f_air_temp), vec4(final_air_temp, 0.0, 0.0, 0.0));
}


