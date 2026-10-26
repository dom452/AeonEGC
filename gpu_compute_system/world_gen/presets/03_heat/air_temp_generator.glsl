#[compute]
#version 450

// ==========================================
// AIR TEMP GENERATOR
// ==========================================
// Seeds: 
//   - AIR_TEMP (Float Grid, ATMOSPHERE)
// Initial Values: 
//   - Derived primarily from SUNLIGHT, mapping it between 'pole_temp' and 'equator_temp'.
//   - Mixed with GROUND_TEMP using 'ground_mix_factor'.
//   - Applies altitude lapse cooling via 'lapse_rate' based on BEDROCK_HEIGHT.
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
        
        int f_bedrock_height; // BEDROCK_HEIGHT
        int f_ground_temp; // GROUND_TEMP
        
        int f_sunlight; // SUNLIGHT

        // User push constants
        float equator_temp;        // Max base temp at equator (e.g. 40.0)
        float pole_temp;           // Min base temp at poles (e.g. -30.0)
        float ground_mix_factor;   // How much ground temp affects air temp (e.g. 0.4)
        float lapse_rate;          // Altitude cooling (e.g. 15.0)
} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Read Altitude, Ground Temp, and Sunlight (Float grid)
	float altitude = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
	float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
	float sunlight = imageLoad(write_tex, ivec3(id.xy, params.f_sunlight)).r;
	
	// Base air temp derived from sunlight (which handles the latitude curve)
	float lat_base_temp = mix(params.pole_temp, params.equator_temp, sunlight);
	
	// Mix with the actual ground temperature to account for geothermal/solar hotspots
	float base_air = mix(lat_base_temp, ground_temp, params.ground_mix_factor);
	
	// Apply lapse rate (altitude effect on air is typically stronger than on ground)
	// Normalise altitude so the lapse_rate value drops the peak temp cleanly
	float normalized_alt = altitude / 200.0;
	float final_air_temp = base_air - (normalized_alt * params.lapse_rate);
	
	// Option 1: Ice Wall forced cooling (Model B: distance measured from polar boundary edges)
	float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
	float pole_threshold = float(size.y) * 0.05;
	float pole_mask = smoothstep(0.0, pole_threshold, dist_from_pole);
	final_air_temp = mix(-50.0, final_air_temp, pole_mask);

	// Write to AIR_TEMP (Layer 2 of ATMOSPHERE)
	imageStore(write_tex, ivec3(id.xy, params.f_air_temp), vec4(final_air_temp, 0.0, 0.0, 0.0));
}


