#[compute]
#version 450

// =============================================================================
// PRESSURE GENERATOR
// Compute pass that calculates baseline atmospheric column height and surface pressure.
// Physical units: Dimensionless fluid column thickness anomaly relative to standard 1.0 resting depth.
// Bindings: Reads bedrock elevation and air temperature from write_tex (Set 0, Binding 0);
//           Writes resting column height (1.0) to write_tex (Set 0, Binding 0).
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
	int f_pressure; // Index of atmospheric pressure layer in float texture array

	int f_bedrock_height; // Index of bedrock elevation layer in float texture array
	int f_air_temp;       // Index of air temperature layer in float texture array

	float base_pressure_sea_level; // Reference sea-level pressure baseline anomaly
	float latitude_pressure_amp;   // Amplitude of planetary latitudinal circulation bands
	float altitude_lapse_rate;     // Hydrostatic pressure decrease per unit of elevation
	float thermal_pressure_coef;   // Thermal coupling coefficient (warm air produces lower surface pressure)
} params;

// Maps pixel vertical coordinate to cell-centered normalized latitude [-1, 1] (+1 = North Pole, -1 = South Pole)
float pixel_to_latitude(ivec2 pixel_pos, ivec2 tex_size) {
	float norm_y = (float(pixel_pos.y) + 0.5) / float(tex_size.y);
	return (0.5 - norm_y) * 2.0;
}

void main() {
	// Determine 2D coordinate for this compute thread within the world grid
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Read surface bedrock elevation and atmospheric air temperature
	float altitude = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
	float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;

	// Calculate latitude coordinate [-1, 1]
	float lat = pixel_to_latitude(id.xy, size.xy);

	// 1. Latitudinal climatology: models planetary Hadley, Ferrel, and Polar circulation bands
	// Creates equatorial low, subtropical highs, subpolar lows, and polar highs
	float hadley_pattern = -cos(3.14159265 * 1.5 * lat);
	float lat_pressure = hadley_pattern * params.latitude_pressure_amp;

	// 2. Hydrostatic terrain correction: high elevation terrain reduces total overlying air column mass
	float hydrostatic_correction = -altitude * params.altitude_lapse_rate;

	// 3. Thermal deviation: warm air expands and creates low surface pressure
	float thermal_deviation = air_temp * params.thermal_pressure_coef;

	// Sum pressure components into total barometric pressure anomaly
	float final_pressure = params.base_pressure_sea_level
	                     + lat_pressure
	                     + hydrostatic_correction
	                     + thermal_deviation;

	// Polar boundary smoothing: homogenize pressure values near the polar singularity
	float dist_from_pole = min(float(id.y), float(size.y - 1 - id.y));
	if (dist_from_pole < 5.0) {
		float e_alt = imageLoad(write_tex, ivec3((id.x + 1) % size.x, id.y, params.f_bedrock_height)).r;
		float w_alt = imageLoad(write_tex, ivec3((id.x - 1 + size.x) % size.x, id.y, params.f_bedrock_height)).r;
		float e_temp = imageLoad(write_tex, ivec3((id.x + 1) % size.x, id.y, params.f_air_temp)).r;
		float w_temp = imageLoad(write_tex, ivec3((id.x - 1 + size.x) % size.x, id.y, params.f_air_temp)).r;
		
		float e_pressure = params.base_pressure_sea_level + lat_pressure - (e_alt * params.altitude_lapse_rate) + (e_temp * params.thermal_pressure_coef);
		float w_pressure = params.base_pressure_sea_level + lat_pressure - (w_alt * params.altitude_lapse_rate) + (w_temp * params.thermal_pressure_coef);
		
		final_pressure = mix(final_pressure, (e_pressure + w_pressure) * 0.5, 0.5);
	}

	// Seed atmospheric column height h at resting baseline 1.0 (thermal forcing drives runtime dynamics)
	imageStore(write_tex, ivec3(id.xy, params.f_pressure), vec4(1.0, 0.0, 0.0, 0.0));
}
