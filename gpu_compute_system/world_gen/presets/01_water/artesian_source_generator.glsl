#[compute]
#version 450

// ==========================================
// ARTESIAN SOURCE GENERATOR
// ==========================================
// Seeds: 
//   - ARTESIAN_SOURCES (Atomic Grid, WATER)
// Initial Values: 
//   - Uses custom noise (Binding 1) to randomly seed subterranean water sources.
//   - Active only if noise exceeds 'artesian_threshold'.
//   - Scales volume using 'artesian_base_amount' and 'artesian_scale'.
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
        int a_artesian_sources; // ARTESIAN_SOURCES

        // User push constants
        float artesian_threshold;   // e.g. 0.8
        float artesian_base_amount; // e.g. 5.0
        float artesian_scale;       // e.g. 20.0
        float atomic_multiplier;    // e.g. 100.0
} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(atomic_tex);
	if (id.x >= size.x || id.y >= size.y) return;
	
	// Read noise from binding 1, layer 0
	float noise_val = imageLoad(custom_tex, ivec3(id.xy, 0)).r;
	
	// Determine if artesian source is active
	float is_active = step(params.artesian_threshold, noise_val);
	
	// Normalize noise between threshold and 1.0
	float normalized_noise = clamp((noise_val - params.artesian_threshold) / (1.0 - params.artesian_threshold), 0.0, 1.0);
	
	// Calculate artesian amount
	float artesian_val = is_active * (params.artesian_base_amount + (normalized_noise * params.artesian_scale));
	
	// Convert to uint
	uint artesian_uint = uint(artesian_val * params.atomic_multiplier);
	
	// Write to ARTESIAN_SOURCES (Atomic Grid: WATER Layer 2)
	imageStore(atomic_tex, ivec3(id.xy, params.a_artesian_sources), uvec4(artesian_uint, 0, 0, 0));
}

