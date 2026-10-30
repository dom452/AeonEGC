#[compute]
#version 450

// =============================================================================
// TEMP REBALANCE ICE GENERATOR
// Post-processing pass that cools overlying atmospheric and ground temperatures in cells with ice sheets.
// Physical units: Ice thickness in hectometers (1.0 = 100 meters thickness), temperatures in °C.
// Bindings: Reads ice thickness from write_tex (Set 0, Binding 0);
//           Modifies air temperature and ground temperature in write_tex (Set 0, Binding 0).
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
    int f_air_temp;         // Index of air temperature layer in float texture array
    int f_ground_temp;      // Index of ground temperature layer in float texture array
    int f_water_ice_height; // Index of ice thickness layer in float texture array

    float freeze_threshold; // Target sub-zero temperature toward which iced cells are cooled (e.g., -4.0 °C)
    float cooling_factor;   // Reference ice thickness in hectometers required to reach maximum cooling influence
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    // Read surface ice thickness in physical hectometers
    float ice_height = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;

    // Apply cooling adjustment only if surface ice is present
    if (ice_height > 0.0) {
        float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
        float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;

        // Compute normalized cooling weight [0, 1] based on ice thickness relative to cooling_factor
        float cooling_weight = clamp(ice_height / params.cooling_factor, 0.0, 1.0);
        
        // Define target cooled temperatures (capped by freeze_threshold so warm air/ground is forced down)
        float target_air = min(air_temp, params.freeze_threshold);
        float target_ground = min(ground_temp, params.freeze_threshold);

        // Blend local temperatures toward freezing equilibrium proportional to ice mass
        float new_air = mix(air_temp, target_air, cooling_weight);
        float new_ground = mix(ground_temp, target_ground, cooling_weight);

        // Store updated temperatures in the float texture array
        imageStore(write_tex, ivec3(id.xy, params.f_air_temp), vec4(new_air, 0.0, 0.0, 0.0));
        imageStore(write_tex, ivec3(id.xy, params.f_ground_temp), vec4(new_ground, 0.0, 0.0, 0.0));
    }
}


