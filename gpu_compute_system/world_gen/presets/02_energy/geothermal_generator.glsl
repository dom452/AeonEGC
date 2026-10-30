#[compute]
#version 450

// =============================================================================
// GEOTHERMAL GENERATOR
// Compute pass that generates subterranean crustal geothermal heat flux from cellular noise.
// Physical units: Heat flux scaled to integer units for atomic accumulation
//                (1.0 = baseline geothermal heat unit multiplied by atomic multiplier).
// Bindings: Reads cellular noise from custom_tex (Set 0, Binding 15);
//           Writes initial geothermal heat flux to atomic_tex (Set 0, Binding 2).
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
    int a_geothermal; // Index of geothermal heat layer in atomic texture array

    float geothermal_threshold; // Noise cutoff below which no volcanic or hydrothermal activity occurs (e.g., 0.6)
    float geothermal_base;      // Minimum geothermal heat emitted at active tectonic sites
    float geothermal_scale;     // Scaling multiplier for high-intensity geothermal hotspots
    float atomic_multiplier;    // Scale factor converting physical float units to fixed-point uint (e.g., 100.0)
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(atomic_tex);
    if (id.x >= size.x || id.y >= size.y) return;
    
    // Sample cellular noise from layer 0 of the custom noise texture
    float noise_val = imageLoad(custom_tex, ivec3(id.xy, 0)).r;
    
    // Normalize cellular noise magnitude in the active range above the threshold [0, 1]
    float normalized_noise = clamp((noise_val - params.geothermal_threshold) / (1.0 - params.geothermal_threshold), 0.0, 1.0);
    
    // Threshold gate: 1.0 if noise exceeds threshold (active rift/hotspot), 0.0 otherwise
    float is_active = step(params.geothermal_threshold, noise_val);
    
    // Compute total geothermal heat output: base heat plus hotspot variation, gated by activity
    float geothermal = is_active * (params.geothermal_base + (normalized_noise * params.geothermal_scale));
    
    // Quantize floating-point heat flux into fixed-point integer for atomic storage
    uint geo_uint = uint(geothermal * params.atomic_multiplier);
    
    // Store initial geothermal heat into the atomic texture layer
    imageStore(atomic_tex, ivec3(id.xy, params.a_geothermal), uvec4(geo_uint, 0, 0, 0));
}

