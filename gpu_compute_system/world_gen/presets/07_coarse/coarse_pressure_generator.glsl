#[compute]
#version 450

// ============================================================================
// COARSE PRESSURE GENERATOR
// ============================================================================
// Seeds the initial coarse dynamics state (64x64, R32F, binding 6).
// Downsamples fine elevation & air temperature to initialize coarse terrain,
// temperature, and roughness, and analytically computes column height h
// in hydrostatic balance with latitude and topography:
//   h(lat, b) = h0 + delta_h * cos(lat) - gamma * b
// Clears coarse wind vectors (u = 0, v = 0) to prevent startup transient shockwaves.
// ============================================================================

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

layout(push_constant) uniform Params {
    // Coarse write target indices (9-layer 2-layer SWE layout)
    int c_h_upper;        // COARSE.H_UPPER (layer 0)
    int c_wind_upper_x;   // COARSE.WIND_UPPER_X (layer 1)
    int c_wind_upper_y;   // COARSE.WIND_UPPER_Y (layer 2)
    int c_h_lower;        // COARSE.H_LOWER (layer 3)
    int c_wind_lower_x;   // COARSE.WIND_LOWER_X (layer 4)
    int c_wind_lower_y;   // COARSE.WIND_LOWER_Y (layer 5)
    int c_air_temp;       // COARSE.AIR_TEMP (layer 6)
    int c_terrain;        // COARSE.TERRAIN (layer 7)
    int c_roughness;      // COARSE.ROUGHNESS (layer 8)

    // Fine read source indices
    int f_bedrock_height; // LANDSCAPE.BEDROCK_HEIGHT
    int f_sediment_height;// LANDSCAPE.SEDIMENT_HEIGHT
    int f_air_temp;       // ATMOSPHERE.AIR_TEMP

    // Configuration constants
    float swe_reference_height; // Reference h0 (e.g. 1.0)
    float latitude_pressure_amp;// Equator-to-pole variation (e.g. 0.08)
    float altitude_lapse_rate;  // Pressure reduction per terrain height
} params;

const float PI = 3.14159265359;

void main() {
    ivec2 coarse_id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 coarse_size = imageSize(coarse_write_tex).xy;
    if (coarse_id.x >= coarse_size.x || coarse_id.y >= coarse_size.y) return;

    ivec2 fine_size = imageSize(write_tex).xy;
    int block_w = fine_size.x / coarse_size.x;
    int block_h = fine_size.y / coarse_size.y;

    float temp_sum = 0.0;
    float terrain_sum = 0.0;
    float b_min = 1e6;
    float b_max = -1e6;
    float count = float(block_w * block_h);

    for (int dy = 0; dy < block_h; dy++) {
        for (int dx = 0; dx < block_w; dx++) {
            ivec2 fine_coord = coarse_id * ivec2(block_w, block_h) + ivec2(dx, dy);
            fine_coord.x = (fine_coord.x % fine_size.x + fine_size.x) % fine_size.x;
            fine_coord.y = clamp(fine_coord.y, 0, fine_size.y - 1);

            float bed = imageLoad(write_tex, ivec3(fine_coord, params.f_bedrock_height)).r;
            float sed = imageLoad(write_tex, ivec3(fine_coord, params.f_sediment_height)).r;
            float temp = imageLoad(write_tex, ivec3(fine_coord, params.f_air_temp)).r;
            float b = bed + sed;

            temp_sum += temp;
            terrain_sum += b;
            b_min = min(b_min, b);
            b_max = max(b_max, b);
        }
    }

    float mean_temp = temp_sum / count;
    float mean_terrain = terrain_sum / count;
    float roughness = max(0.0, b_max - b_min);

    // Cell-centered latitude: phi in [-PI/2, PI/2]
    float norm_y = (float(coarse_id.y) + 0.5) / float(coarse_size.y);
    float lat = (0.5 - norm_y) * PI;

    // Analytic hydrostatic column height for 2-layer atmosphere
    // Reference column height h0 is shared across upper and lower layers (0.5 * h0 each).
    // Lower layer feels topography directly; upper layer rides on top.
    float lat_variation = cos(lat) * params.latitude_pressure_amp;
    float terrain_correction = mean_terrain * params.altitude_lapse_rate;
    float initial_h_lower = max(0.1, 0.5 * params.swe_reference_height + lat_variation - terrain_correction);
    float initial_h_upper = max(0.1, 0.5 * params.swe_reference_height + 0.5 * lat_variation);

    // Write all coarse layers to the active write buffer
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_h_upper), vec4(initial_h_upper, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_wind_upper_x), vec4(0.0, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_wind_upper_y), vec4(0.0, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_h_lower), vec4(initial_h_lower, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_wind_lower_x), vec4(0.0, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_wind_lower_y), vec4(0.0, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_air_temp), vec4(mean_temp, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_terrain), vec4(mean_terrain, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_roughness), vec4(roughness, 0.0, 0.0, 0.0));
}
