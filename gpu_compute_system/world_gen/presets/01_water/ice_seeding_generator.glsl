#[compute]
#version 450

// =============================================================================
// ICE SEEDING GENERATOR
// Compute pass that seeds initial polar ice sheets and glaciers based on low atmospheric temperatures.
// Physical units: Ice thickness in hectometers (1.0 = 100 meters thickness), temperature in °C.
// Bindings: Reads atmospheric air temperature from write_tex (Set 0, Binding 0);
//           Writes ice thickness to write_tex (Set 0, Binding 0);
//           Accumulates initial ice volume in atomic_tex (Set 0, Binding 2).
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
    int f_water_ice_height;
    int f_air_temp;

    int a_atomic_ice;        // Index of ice volume layer in atomic texture array

    float ice_base_amount;   // Maximum initial ice sheet thickness in hectometers (e.g., 2.0 = 200m)
    float atomic_multiplier; // Scale factor converting physical float units to fixed-point uint (e.g., 100.0)
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    // Read surface atmospheric temperature in °C
    float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
    
    // Smoothly interpolate ice thickness fraction across the transition between 0.0°C (no ice) and -10.0°C (solid ice)
    float is_frozen_logic = 1.0 - smoothstep(-10.0, 0.0, air_temp); 
    
    // Compute physical ice thickness to deposit at this cell (hectometers)
    float ice_to_add = is_frozen_logic * params.ice_base_amount;
    
    // Quantize floating-point ice thickness into fixed-point integer for atomic storage
    uint ice_uint = uint(ice_to_add * params.atomic_multiplier);

    // Read current cached ice thickness, add newly seeded ice, and store back to float texture array
    float current_ice = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;
    imageStore(write_tex, ivec3(id.xy, params.f_water_ice_height), vec4(current_ice + ice_to_add, 0.0, 0.0, 0.0));

    // Accumulate seeded ice volume into the atomic simulation layer
    imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_atomic_ice), ice_uint);
}

