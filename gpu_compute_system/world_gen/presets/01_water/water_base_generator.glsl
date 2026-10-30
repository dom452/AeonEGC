#[compute]
#version 450

// =============================================================================
// WATER BASE GENERATOR
// Compute pass that seeds uniform global ocean depth and initial water column temperature.
// Physical units: Water depth in hectometers (1.0 = 100 meters depth), temperature in °C.
// Bindings: Reads ground temperature from write_tex (Set 0, Binding 0);
//           Writes liquid water depth and temperature to write_tex (Set 0, Binding 0);
//           Accumulates initial water volume in atomic_tex (Set 0, Binding 2).
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
    int f_water_liquid_height;
    int f_water_temp;
    int f_ground_temp;

    float max_elevation;     // Reference planetary max elevation in hectometers
    float sea_level_ratio;   // Desired global sea level fraction relative to max elevation
    int a_liquid_volume;     // Index of liquid water volume layer in atomic texture array
    float atomic_multiplier; // Scale factor converting physical float units to fixed-point uint
} params;

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

    // Calculate uniform baseline water column depth to drop across each cell (hectometers)
    float liq_val = params.max_elevation * params.sea_level_ratio;

    // Accumulate initial liquid water volume into the atomic simulation grid
    imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_liquid_volume), uint(liq_val * params.atomic_multiplier));

    // Store liquid water depth into the float texture array for display and physics sampling
    imageStore(write_tex, ivec3(id.xy, params.f_water_liquid_height), vec4(liq_val, 0.0, 0.0, 0.0));

    // Initialize water temperature equal to local ground temperature so initial water bodies
    // match the thermal profile of the ground below them
    float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
    imageStore(write_tex, ivec3(id.xy, params.f_water_temp), vec4(ground_temp, 0.0, 0.0, 0.0));
}


