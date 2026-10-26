#[compute]
#version 450

// ==========================================
// PRESSURE GENERATOR
// ==========================================
// Seeds ATMOSPHERE.PRESSURE (Float Grid, index 6)
//
// Initial Values:
//   - Base: Hadley/Ferrel/Polar cell latitudinal pattern via -cos(3*lat) * amplitude
//   - Hydrostatic: -altitude * lapse_rate (lower pressure at high terrain)
//   - Thermal: air_temp * thermal_coef (warm → low pressure, so negative coefficient)
//   - All values are normalized anomalies from standard 1013.25 hPa
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
	// Write target
	int f_pressure; // ATMOSPHERE.PRESSURE (index 6)

	// Read sources
	int f_bedrock_height; // LANDSCAPE.BEDROCK_HEIGHT
	int f_air_temp;       // ATMOSPHERE.AIR_TEMP (index 2)

	// Configuration push constants
	float base_pressure_sea_level;   // Reference sea-level pressure anomaly (e.g. 0.0)
	float latitude_pressure_amp;     // Amplitude of latitudinal variation (e.g. 0.08)
	float altitude_lapse_rate;       // Pressure drop per unit height (e.g. 0.00012)
	float thermal_pressure_coef;     // Thermal coupling; warm→low pressure (e.g. -0.003)
} params;

// Convert pixel Y to cell-centered normalized latitude in range (-1, 1) (North Pole = +1, South Pole = -1)
// Model B (cell-centered): poles reside on outer texture boundary edges (y = -0.5, y = tex_size.y - 0.5)
float pixel_to_latitude(ivec2 pixel_pos, ivec2 tex_size) {
	float norm_y = (float(pixel_pos.y) + 0.5) / float(tex_size.y);
	return (0.5 - norm_y) * 2.0;
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// --- Read source data ---
	float altitude = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
	float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;

	// --- Compute latitude ---
	float lat = pixel_to_latitude(id.xy, size.xy);

	// --- 1. Latitudinal climatology (Hadley/Ferrel/Polar cells) ---
	// Pattern: equatorial low (~30°N/S), subtropical highs (~60°), polar lows
	// Approximated by -cos(3*latitude * PI/2)
	float hadley_pattern = -cos(3.14159265 * 1.5 * lat); // ranges [-1, +1]
	float lat_pressure = hadley_pattern * params.latitude_pressure_amp;

	// --- 2. Hydrostatic correction (terrain lowers surface pressure) ---
	float hydrostatic_correction = -altitude * params.altitude_lapse_rate;

	// --- 3. Thermal deviation (warm air → lower surface pressure) ---
	float thermal_deviation = air_temp * params.thermal_pressure_coef;

	// --- Combine all components ---
	float final_pressure = params.base_pressure_sea_level
	                     + lat_pressure
	                     + hydrostatic_correction
	                     + thermal_deviation;

	// Force scalar uniformity over the poles
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

	// Write to PRESSURE layer (ATMOSPHERE index 6)
	// SWE column height h: 1.0 = reference height (swe_reference_height).
	// Seed at 1.0 (rest). Thermal forcing creates deviations from this baseline.
	imageStore(write_tex, ivec3(id.xy, params.f_pressure), vec4(1.0, 0.0, 0.0, 0.0));
}
