#[compute]
#version 450

// ==========================================
// GROUND HEAT GENERATOR
// ==========================================
// Seeds: 
//   - GROUND_TEMP (Float Grid, LANDSCAPE)
// Initial Values: 
//   - Combines incoming SUNLIGHT * 'solar_heat_scale' and ATOMIC_GEOTHERMAL * 'geothermal_heat_scale'.
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
        int f_ground_temp; // GROUND_TEMP
        int f_bedrock_height; // BEDROCK_HEIGHT
        int f_sunlight; // SUNLIGHT

        int a_atomic_geothermal;   // ATOMIC_GEOTHERMAL

        float solar_heat_scale;      // multiplier for sunlight (e.g. 35.0)
        float geothermal_heat_scale; // multiplier for geothermal (e.g. 1.0)
        float lapse_rate;            // altitude cooling (e.g. 5.0)
        float atomic_multiplier;     // to convert geothermal from uint (e.g. 100.0)
} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Read Altitude (Since we write to LANDSCAPE, we use the write index to read the previously generated bedrock)
	float altitude = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
	
	// Read Sunlight (Float grid)
	float sunlight = imageLoad(write_tex, ivec3(id.xy, params.f_sunlight)).r;
	
	// Read Geothermal (Atomic grid)
	uint geo_uint = imageLoad(atomic_tex, ivec3(id.xy, params.a_atomic_geothermal)).r;
	float geothermal = float(geo_uint) / params.atomic_multiplier;
	
	// Base Ground Heat is derived from Sunlight and Geothermal heat
	float ground_heat = (sunlight * params.solar_heat_scale) + (geothermal * params.geothermal_heat_scale);
	
	// Final Ground Temp subtracts the altitude lapse rate (assuming altitude max is 200.0)
	// Normalise the altitude between 0 and 1 so our lapse rate acts globally
	float normalized_alt = altitude / 200.0;
	float final_temp = ground_heat - (normalized_alt * params.lapse_rate);
	
	// Option 1: Ice Wall forced cooling (Model B: distance measured from polar boundary edges)
	float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
	float pole_threshold = float(size.y) * 0.05;
	float pole_mask = smoothstep(0.0, pole_threshold, dist_from_pole);
	final_temp = mix(-50.0, final_temp, pole_mask);

	// Write to GROUND_TEMP (Layer 4 of LANDSCAPE)
	imageStore(write_tex, ivec3(id.xy, params.f_ground_temp), vec4(final_temp, 0.0, 0.0, 0.0));
}


