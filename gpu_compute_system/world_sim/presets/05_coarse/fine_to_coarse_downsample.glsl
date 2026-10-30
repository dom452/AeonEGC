#[compute]
#version 450

// =============================================================================
// FINE TO COARSE DOWNSAMPLE SIMULATION PASS
// Compute pass that downsamples fine atmospheric temperature and surface elevations onto the coarse 64x64 grid.
// Physical units: Temperatures in °C, bedrock and sediment surface heights in hectometers (1.0 = 100 meters).
// Bindings: Reads fine-grid data from read_tex (Set 0, Binding 1);
//           Writes downsampled temperature, terrain, and roughness to coarse_write_tex (Set 0, Binding 6).
// =============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// === UNIFIED SIMULATION UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f)   | 1: Fine Float Read (r16f)    | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)       | 4: SSBO Read (std430)        | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f) | 7: Coarse Float Read (r32f)
layout(r16f, set = 0, binding = 0) restrict uniform image2DArray write_tex;
layout(r16f, set = 0, binding = 1) restrict readonly uniform image2DArray read_tex;
layout(r32ui, set = 0, binding = 2) uniform uimage2DArray atomic_tex;
layout(r16f, set = 0, binding = 5) restrict writeonly uniform image2DArray atomic_vis_tex;
layout(r32f, set = 0, binding = 6) restrict uniform image2DArray coarse_write_tex;
layout(r32f, set = 0, binding = 7) restrict readonly uniform image2DArray coarse_read_tex;

layout(push_constant) uniform Params {
    float deltaTime; // Time step duration in seconds

    // Output target indices on the coarse texture array (Binding 6)
    int c_air_temp;  // Index of downsampled coarse air temperature layer
    int c_terrain;   // Index of downsampled mean terrain elevation layer
    int c_roughness; // Index of sub-grid topographic roughness layer

    // Source input indices on the fine float texture array (Binding 1)
    int f_air_temp;  // Index of fine air temperature layer
    int f_bedrock;   // Index of fine bedrock elevation layer
    int f_sediment;  // Index of fine sediment depth layer
} params;

void main() {
    // Determine 2D coordinate for this compute thread within the coarse grid (64x64)
    ivec2 coarse_id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 coarse_size = imageSize(coarse_write_tex).xy;
    if (coarse_id.x >= coarse_size.x || coarse_id.y >= coarse_size.y) return;

    // Calculate dimensions of fine-grid block corresponding to one coarse cell (e.g., 8x8 fine cells per coarse cell)
    ivec2 fine_size = imageSize(read_tex).xy;
    int block_w = fine_size.x / coarse_size.x;
    int block_h = fine_size.y / coarse_size.y;

    float temp_sum = 0.0;
    float terrain_sum = 0.0;
    float b_min = 1e6;
    float b_max = -1e6;
    float count = float(block_w * block_h);

    // Accumulate fine-grid temperature and terrain elevation samples across the block
    for (int dy = 0; dy < block_h; dy++) {
        for (int dx = 0; dx < block_w; dx++) {
            ivec2 fine_pos = coarse_id * ivec2(block_w, block_h) + ivec2(dx, dy);
            fine_pos.x = (fine_pos.x % fine_size.x + fine_size.x) % fine_size.x;
            fine_pos.y = clamp(fine_pos.y, 0, fine_size.y - 1);

            float fine_temp = imageLoad(read_tex, ivec3(fine_pos, params.f_air_temp)).r;
            float fine_bed  = imageLoad(read_tex, ivec3(fine_pos, params.f_bedrock)).r;
            float fine_sed  = imageLoad(read_tex, ivec3(fine_pos, params.f_sediment)).r;
            float b = fine_bed + fine_sed;

            temp_sum += fine_temp;
            terrain_sum += b;
            b_min = min(b_min, b);
            b_max = max(b_max, b);
        }
    }

    // Compute block spatial averages and sub-grid topographic roughness (peak-to-valley variance)
    float mean_temp = temp_sum / count;
    float mean_terrain = terrain_sum / count;
    float roughness = max(0.0, b_max - b_min);

    // Store downsampled values into the coarse write texture array
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_air_temp), vec4(mean_temp, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_terrain), vec4(mean_terrain, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(coarse_id, params.c_roughness), vec4(roughness, 0.0, 0.0, 0.0));
}
