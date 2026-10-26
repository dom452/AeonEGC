#[compute]
#version 450

// ==========================================
// WATER BASE GENERATOR
// ==========================================
// Seeds: 
//   - LIQUID_VOLUME (Atomic Grid, WATER)
//   - WATER_LIQUID_HEIGHT (Float Grid, WATER)
//   - WATER_TEMP (Float Grid, WATER)
// Initial Values: 
//   - Dumps uniform water globally: max_elevation * sea_level_ratio.
//   - Sets initial WATER_TEMP equal to the local GROUND_TEMP.
// ==========================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
// === UNIFIED GENERATOR UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f) | 1: Fine Float Read (r16f)    | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)     | 4: SSBO Read (std430)        | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f)| 7: Coarse Float Read (r32f) | 15: Custom Noise Read (r32f)
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

    // User variables
    float max_elevation;         // From WorldConfig
    float sea_level_ratio;       // From WorldConfig
    int a_liquid_volume;       // Direct index for LIQUID_VOLUME in the atomic grid
    float atomic_multiplier;     // Scaling factor for float -> uint atomic conversion
} params;

void main() {
ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
ivec3 size = imageSize(write_tex);
if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

// Calculate the absolute global volume of water to drop per cell to achieve the desired sea level
float liq_val = params.max_elevation * params.sea_level_ratio;

// Write to Atomic Grid (LIQUID_VOLUME)
imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_liquid_volume), uint(liq_val * params.atomic_multiplier));

// Write to Float Grid (Cached visualization / physics arrays)
imageStore(write_tex, ivec3(id.xy, params.f_water_liquid_height), vec4(liq_val, 0.0, 0.0, 0.0)); // WATER_LIQUID_HEIGHT

// Pre-heat the water using the ground temperature so the flow pass can advect real thermal gradients
// Since GROUND_TEMP is generated before water, we can directly inherit it.
float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;

imageStore(write_tex, ivec3(id.xy, params.f_water_temp), vec4(ground_temp, 0.0, 0.0, 0.0)); // WATER_TEMP
}


