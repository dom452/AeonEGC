#[compute]
#version 450

// ==========================================
// GEOTHERMAL GENERATOR
// ==========================================
// Seeds: 
//   - GEOTHERMAL (Atomic Grid, ENERGY)
// Initial Values: 
//   - Reads custom cellular noise (Binding 1).
//   - Zero if below 'geothermal_threshold'.
//   - Above threshold: 'geothermal_base' + (normalized noise * 'geothermal_scale').
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
        int a_geothermal; // GEOTHERMAL

        // User push constants
        float geothermal_threshold; // Threshold above which geothermal activity happens (e.g. 0.6)
        float geothermal_base;      // Base geothermal heat when threshold is passed
        float geothermal_scale;     // Multiplier for the noise value
        float atomic_multiplier;    // e.g. 100.0 for 0.01 precision in integer
} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(atomic_tex);
	if (id.x >= size.x || id.y >= size.y) return;
	
	// Read custom cellular noise from binding 1, layer 0
	float noise_val = imageLoad(custom_tex, ivec3(id.xy, 0)).r;
	
	// Isolate noise above threshold and clamp (saturate) to 0.0 - 1.0
	float normalized_noise = clamp((noise_val - params.geothermal_threshold) / (1.0 - params.geothermal_threshold), 0.0, 1.0);
	
	// step() returns 0.0 if noise is below threshold, 1.0 if above
	float is_active = step(params.geothermal_threshold, noise_val);
	
	// Apply base heat and scale, then multiply by is_active to zero out inactive cells
	float geothermal = is_active * (params.geothermal_base + (normalized_noise * params.geothermal_scale));
	
	// Write GEOTHERMAL to Atomic Grid (ENERGY Layer 2)
	// Must convert to uint using atomic_multiplier
	uint geo_uint = uint(geothermal * params.atomic_multiplier);
	
	// In generation passes, a direct imageStore is acceptable since each thread owns its pixel
	imageStore(atomic_tex, ivec3(id.xy, params.a_geothermal), uvec4(geo_uint, 0, 0, 0));
}

