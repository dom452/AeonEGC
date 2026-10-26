#[compute]
#version 450

// ==========================================
// ICE SEEDING GENERATOR
// ==========================================
// Seeds: 
//   - ICE_VOLUME (Atomic Grid, WATER)
//   - WATER_ICE_HEIGHT (Float Grid, WATER)
// Initial Values: 
//   - Reads AIR_TEMP to seed polar ice caps and glaciers.
//   - Creates a smooth gradient between 0.0°C (no ice) and -10.0°C (max ice).
//   - Max ice thickness set by 'ice_base_amount'.
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
        int f_water_ice_height;
        int f_air_temp;

        int a_atomic_ice;         // Index for ICE_VOLUME in atomic grid

        float ice_base_amount;      // How much ice to drop
        float atomic_multiplier;    // e.g. 100.0
} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Read Air Temp
	float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
	
	// Instead of a hard binary step, use smoothstep to create a gradual gradient for ice thickness
	// between -10.0 C (fully thick) and 0.0 C (no ice)
	float is_frozen_logic = 1.0 - smoothstep(-10.0, 0.0, air_temp); 
	
	// Multiply the logic by the base amount 
	float ice_to_add = is_frozen_logic * params.ice_base_amount;
	
	// Convert to uint for atomic addition
	uint ice_uint = uint(ice_to_add * params.atomic_multiplier);

	
	// Read current cached float, add, and write back
	// Wait, is write_tex layout matching what we think?
	// WATER is write_layer 0-6. 
	float current_ice = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;

	// Explicitly write a massive number to force visual validation.
	imageStore(write_tex, ivec3(id.xy, params.f_water_ice_height), vec4(current_ice + ice_to_add, 0.0, 0.0, 0.0));

	// Unconditional writes are safer in GLSL compute for coalescing and predictability
	imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_atomic_ice), ice_uint);
	
}

