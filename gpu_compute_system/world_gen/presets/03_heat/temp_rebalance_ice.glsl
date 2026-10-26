#[compute]
#version 450

// ==========================================
// TEMP REBALANCE ICE (GENERATOR POST-PROCESS)
// ==========================================
// Seeds: 
//   - Modifies existing AIR_TEMP and GROUND_TEMP
// Initial Values: 
//   - Re-reads WATER_ICE_HEIGHT generated in the previous step.
//   - Forces local temperatures downward toward 'freeze_threshold' 
//     proportional to the mass of ice present.
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
        int f_air_temp; // AIR_TEMP
        int f_ground_temp; // GROUND_TEMP (We will write to it)
        int f_water_ice_height; // WATER_ICE_HEIGHT

        // User push constants
        float freeze_threshold; // e.g. -4.0
        float cooling_factor;   // e.g. 0.2
} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Read Ice Height from the float cache (This is absolute mass, not normalized!)
	float ice_height = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;

	if (ice_height > 0.0) {
		float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
		float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;

		// We need to normalize the ice mass to determine its cooling power.
		// params.cooling_factor acts as the "ice mass required to reach 100% cooling weight"
		float cooling_weight = clamp(ice_height / params.cooling_factor, 0.0, 1.0);
		
		float target_air = min(air_temp, params.freeze_threshold);
		float target_ground = min(ground_temp, params.freeze_threshold);

		float new_air = mix(air_temp, target_air, cooling_weight);
		float new_ground = mix(ground_temp, target_ground, cooling_weight);

		imageStore(write_tex, ivec3(id.xy, params.f_air_temp), vec4(new_air, 0.0, 0.0, 0.0));
		imageStore(write_tex, ivec3(id.xy, params.f_ground_temp), vec4(new_ground, 0.0, 0.0, 0.0));
	}
}


