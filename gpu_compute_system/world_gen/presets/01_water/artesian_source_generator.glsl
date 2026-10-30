#[compute]
#version 450

// =============================================================================
// ARTESIAN SOURCE GENERATOR
// Compute pass that seeds subterranean pressurized spring locations and water recharge.
// Physical units: Water volume scaled to integer units for atomic accumulation
//                (1.0 = 100 meters water depth equivalent multiplied by atomic scalar).
// Bindings: Reads procedural noise from custom_tex (Set 0, Binding 15);
//           Writes initial spring recharge amounts to atomic_tex (Set 0, Binding 2).
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
    int a_artesian_sources; // Index of the artesian water layer in the atomic texture array

    float artesian_threshold;   // Minimum noise value required to trigger an artesian spring (e.g., 0.8)
    float artesian_base_amount; // Minimum initial water volume for active springs (e.g., 5.0)
    float artesian_scale;       // Additional variable volume scaling above the threshold (e.g., 20.0)
    float atomic_multiplier;    // Scale factor converting physical float units to fixed-point uint (e.g., 100.0)
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(atomic_tex);
    if (id.x >= size.x || id.y >= size.y) return;
    
    // Sample subterranean water noise from layer 0 of the custom noise texture
    float noise_val = imageLoad(custom_tex, ivec3(id.xy, 0)).r;
    
    // Evaluate binary threshold gate: only cells exceeding the threshold contain an artesian spring
    float is_active = step(params.artesian_threshold, noise_val);
    
    // Normalize noise value within the active range above the threshold [0, 1]
    float normalized_noise = clamp((noise_val - params.artesian_threshold) / (1.0 - params.artesian_threshold), 0.0, 1.0);
    
    // Compute total spring recharge volume (0.0 if below threshold)
    float artesian_val = is_active * (params.artesian_base_amount + (normalized_noise * params.artesian_scale));
    
    // Quantize floating-point water volume into integer fixed-point for atomic storage
    uint artesian_uint = uint(artesian_val * params.atomic_multiplier);
    
    // Store initial artesian water source volume into the atomic texture layer
    imageStore(atomic_tex, ivec3(id.xy, params.a_artesian_sources), uvec4(artesian_uint, 0, 0, 0));
}

