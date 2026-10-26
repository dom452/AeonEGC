#[compute]
#version 450

// ==========================================
// LANDMASS SEDIMENT GENERATOR
// ==========================================
// Seeds: 
//   - SEDIMENT_HEIGHT (Float Grid, LANDSCAPE)
// Initial Values: 
//   - Calculated based on BEDROCK_HEIGHT and SLOPE.
//   - Uses a blurred heightmap to detect valleys/concavity and lowland bias.
//   - Scaled by 'max_sediment_depth' push constant (e.g., 1.0 = 100m).
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

const float PI2 = 6.28318530718;

// === BRANCHLESS SPHERICAL COORDINATE WRAPPING ===
// Handles continuous 360° cylindrical X-wrapping and 180° polar Y-crossover.
// Zero branching (no 'if' statements) to prevent warp divergence in GPU execution.
ivec2 polar_wrap(ivec2 pos, ivec2 size, out float sign_flip) {
    int W = size.x;
    int H = size.y;
    int H2 = 2 * H; // Full Great Circle circumference (360° latitude loop)
    
    // 1. Map Y into [0, 2H - 1] via GLSL modulo
    int y_mod = ((pos.y % H2) + H2) % H2;
    
    // 2. Back hemisphere flag: 0 if front hemisphere (Y in 0..H-1), 1 if back hemisphere (Y in H..2H-1)
    int back = y_mod / H; 
    
    // 3. Mirror Y back into [0, H-1] if on the back hemisphere
    int y_final = (1 - back) * y_mod + back * (H2 - 1 - y_mod);
    
    // 4. Offset X by 180° (+W/2) if on the back hemisphere, then wrap X continuously into [0, W-1]
    int x_final = ((pos.x + back * (W / 2)) % W + W) % W;
    
    // 5. Calculate vector directional sign flip (+1.0 for front hemisphere, -1.0 for back hemisphere)
    sign_flip = 1.0 - 2.0 * float(back);
    
    return ivec2(x_final, y_final);
}

layout(push_constant) uniform Params {
    int f_bedrock_height;
    int f_slope_x;
    int f_slope_y;
    int f_sediment_height;

    float BLUR_DIRECTIONS; // default 8.0
    float BLUR_QUALITY; // default 4.0
    float BLUR_SIZE; // default 16.0
    float SEDIMENT_STICK_FACTOR; // stickiness of material default 4
    float max_elevation; // From WorldConfig for normalization
    float max_sediment_depth; // From WorldConfig (e.g. 1.0 = 100 meters max accumulation)
} params;

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

    // 1. READ BASE HEIGHT AND FLOW
    float h = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
    
    // Normalize h based on max_elevation to properly calculate base sediment distribution
    float normalized_h = h / max(params.max_elevation, 1.0);
    
    float gx = imageLoad(write_tex, ivec3(id.xy, params.f_slope_x)).r;
    float gy = imageLoad(write_tex, ivec3(id.xy, params.f_slope_y)).r;

    // Calculate steepness. Flat terrain (length ~ 0) gives a mask near 1.0. Cliffs give 0.0.
    float slope_length = length(vec2(gx, gy));
    float flat_mask = pow(max(0.0, 1.0 - slope_length), params.SEDIMENT_STICK_FACTOR);

    // 2. CALCULATE SEDIMENT ACCUMULATION
    // Base sediment prefers lowlands (e.g. river basins) over high peaks.
    float lowland_bias = max(0.0, 1.0 - normalized_h);

    // 2.1 Measure local terrain concavity (Valleys vs Peaks) via a blurred average
    float blurred_height = h; 

    for(float d = 0.0; d < PI2; d += PI2 / params.BLUR_DIRECTIONS) {
        for(float i = 1.0 / params.BLUR_QUALITY; i <= 1.0; i += 1.0 / params.BLUR_QUALITY) {
            vec2 pixel_offset = vec2(cos(d), sin(d)) * params.BLUR_SIZE * i;
            ivec2 raw_sample_id = id.xy + ivec2(round(pixel_offset));
            float s_flip;
            ivec2 sample_id = polar_wrap(raw_sample_id, size.xy, s_flip);
            blurred_height += imageLoad(write_tex, ivec3(sample_id, params.f_bedrock_height)).r;
        }
    }

    blurred_height = blurred_height / (params.BLUR_QUALITY * params.BLUR_DIRECTIONS + 1.0);
    
    // Concavity: If the blurred neighborhood is higher than the local height, we are in a valley/bowl.
    // If the local height is higher, we are on a ridge/peak (which will clamp to 0.0).
    float concavity = max(blurred_height - h, 0.0);
    
    // Normalize concavity against a reasonable local terrain variation estimate (e.g., 50 meters = 0.5 units)
    float valley_accumulation = clamp(concavity / 0.5, 0.0, 1.0);

    // Combine factors: Lowlands + Valleys + Flat Ground
    float sediment_ratio = (lowland_bias * 0.5 + valley_accumulation * 0.5) * flat_mask;

    // Scale by the physical max sediment depth (e.g. 1.0 unit = 100 meters)
    float final_sediment = sediment_ratio * params.max_sediment_depth;

    // 3. FINAL WRITE-BACK
    imageStore(write_tex, ivec3(id.xy, params.f_sediment_height), vec4(final_sediment, 0.0, 0.0, 0.0));
} 
