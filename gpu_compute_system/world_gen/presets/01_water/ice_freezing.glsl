#[compute]
#version 450

// ==========================================
// ICE FREEZING GENERATOR (POST-PROCESS)
// ==========================================
// Seeds: 
//   - Modifies existing WATER_ICE_HEIGHT, WATER_LIQUID_HEIGHT, WATER_TEMP (Float Grid)
//   - Modifies ICE_VOLUME, LIQUID_VOLUME (Atomic Grid)
// Initial Values: 
//   - Freezes standing water into ice iteratively based on local AIR_TEMP
//     and total_freeze curves.
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
        int f_water_ice_height;
        int f_air_temp;
        int f_ground_temp;

        int a_atomic_liquid;       // Index for LIQUID_VOLUME in atomic grid
        int a_atomic_ice;          // Index for ICE_VOLUME in atomic grid

        float total_freeze_temp;     // e.g. -40.0
        float total_freeze_curve;    // e.g. 0.58 (Lebedev's exponent for insulation)
        float max_ice_thickness;     // e.g. 5.0 (Absolute thermodynamic equilibrium cap)
        float atomic_multiplier;     // e.g. 100.0
} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Read Temps
	float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
	float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
	
	float avg_temp = (air_temp + ground_temp) * 0.5;

	// We only process if temperature is below freezing (avg_temp < 0.0)
	// Ensure we only operate when avg_temp is negative
	float is_freezing = 1.0 - step(0.0, avg_temp);
	
	// Calculate freezing intensity based on temperature delta
	float freeze_intensity = clamp(avg_temp / params.total_freeze_temp, 0.0, 1.0);
	freeze_intensity = pow(freeze_intensity, params.total_freeze_curve);
	
	// Multiply by logic gate to prevent positive temps from triggering
	freeze_intensity *= is_freezing;

	if (freeze_intensity > 0.0) {
		// Fetch current liquid water from the float cache
		float liquid_water = imageLoad(write_tex, ivec3(id.xy, params.f_water_liquid_height)).r;
		
		if (liquid_water > 0.0) {
			// Determine the absolute mass of ice the temperature WANTS to form
			float desired_ice = freeze_intensity * params.max_ice_thickness;
			
			// We cannot freeze more water than exists in the cell
			float ice_to_form = min(desired_ice, liquid_water);
			
			// Subtract from Liquid Float Cache
			imageStore(write_tex, ivec3(id.xy, params.f_water_liquid_height), vec4(liquid_water - ice_to_form, 0.0, 0.0, 0.0));
			
			// Subtract from Liquid Atomic Grid
			// Since we're subtracting in uint space, we safely atomicAdd with the two's complement if needed,
			// or since it's generation, we can just fetch, subtract and store, OR use imageAtomicAdd with integer underflow wrapper.
			// Actually, fetching, subtracting and writing is safe since threads own their pixels.
			uint current_atomic_liquid = imageLoad(atomic_tex, ivec3(id.xy, params.a_atomic_liquid)).r;
			uint ice_uint = uint(ice_to_form * params.atomic_multiplier);
			
			// Prevent underflow
			uint new_liquid_uint = current_atomic_liquid > ice_uint ? current_atomic_liquid - ice_uint : 0;
			imageStore(atomic_tex, ivec3(id.xy, params.a_atomic_liquid), uvec4(new_liquid_uint, 0, 0, 0));
			
			// Add to Ice Atomic Grid
			imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_atomic_ice), ice_uint);
			
			// Add to Ice Float Cache
			float current_ice_float = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;
			imageStore(write_tex, ivec3(id.xy, params.f_water_ice_height), vec4(current_ice_float + ice_to_form, 0.0, 0.0, 0.0));
		}
	}
}

