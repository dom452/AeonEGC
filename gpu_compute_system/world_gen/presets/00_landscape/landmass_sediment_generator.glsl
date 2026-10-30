#[compute]
#version 450

// =============================================================================
// LANDMASS SEDIMENT GENERATOR
// Compute pass that calculates loose soil and sediment deposition depth across the terrain.
// Physical units: Sediment depth in hectometers (1.0 = 100 meters depth).
// Bindings: Reads bedrock height and slope gradients from write_tex (Set 0, Binding 0);
//           Writes calculated sediment depth to write_tex (Set 0, Binding 0).
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

const float PI2 = 6.28318530718;

// === BRANCHLESS SPHERICAL COORDINATE WRAPPING ===
// Re-maps coordinates that step over texture edges into valid spherical grid positions.
// Horizontally, coordinates wrap seamlessly across 360° longitude.
// Vertically, overstepping a pole crosses into the antipodal longitude (offset by +W/2)
// and reflects latitude, preventing seam artifacts without branching.
ivec2 polar_wrap(ivec2 pos, ivec2 size, out float sign_flip) {
    int W = size.x;
    int H = size.y;
    int H2 = 2 * H; // Full great circle circumference (360° latitude loop)
    
    // Map Y into periodic coordinate space [0, 2H - 1]
    int y_mod = ((pos.y % H2) + H2) % H2;
    
    // Flag whether the coordinate passed over the pole onto the antipodal hemisphere
    int back = y_mod / H; 
    
    // Mirror Y back into primary grid range [0, H-1]
    int y_final = (1 - back) * y_mod + back * (H2 - 1 - y_mod);
    
    // Shift X by 180° longitude (+W/2) when traversing over a pole, then wrap to [0, W-1]
    int x_final = ((pos.x + back * (W / 2)) % W + W) % W;
    
    // Set vector inversion factor: +1.0 on front hemisphere, -1.0 across polar crossover
    sign_flip = 1.0 - 2.0 * float(back);
    
    return ivec2(x_final, y_final);
}

layout(push_constant) uniform Params {
    int f_bedrock_height;
    int f_slope_x;
    int f_slope_y;
    int f_sediment_height;

    float BLUR_DIRECTIONS; // Number of radial sampling rays (e.g., 8.0)
    float BLUR_QUALITY;    // Number of sampling steps along each ray (e.g., 4.0)
    float BLUR_SIZE;       // Blur radius in grid cells (e.g., 16.0)
    float SEDIMENT_STICK_FACTOR; // Power exponent controlling sediment cling to slopes (e.g., 4.0)
    float max_elevation;   // Reference planet elevation cap for normalization (hectometers)
    float max_sediment_depth; // Maximum physical sediment accumulation cap (hectometers: 1.0 = 100m)
} params;

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

    // Read bedrock elevation in hectometers and normalize against the global elevation cap
    float h = imageLoad(write_tex, ivec3(id.xy, params.f_bedrock_height)).r;
    float normalized_h = h / max(params.max_elevation, 1.0);
    
    // Read slope vector components (downhill gradient)
    float gx = imageLoad(write_tex, ivec3(id.xy, params.f_slope_x)).r;
    float gy = imageLoad(write_tex, ivec3(id.xy, params.f_slope_y)).r;

    // Compute surface steepness: flat plains (gradient ~ 0) retain sediment (flat_mask ~ 1.0),
    // whereas steep vertical cliffs shed all loose sediment (flat_mask ~ 0.0)
    float slope_length = length(vec2(gx, gy));
    float flat_mask = pow(max(0.0, 1.0 - slope_length), params.SEDIMENT_STICK_FACTOR);

    // Prefer deposition in lowlands and ocean/river basins rather than mountaintops
    float lowland_bias = max(0.0, 1.0 - normalized_h);

    // Compute regional mean elevation by multi-directional circular sampling around the cell
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

    // Divide accumulated height samples by total sample count to get average neighborhood elevation
    blurred_height = blurred_height / (params.BLUR_QUALITY * params.BLUR_DIRECTIONS + 1.0);
    
    // Evaluate concavity: if the blurred neighborhood is higher than the current cell,
    // this location is a valley, crater, or basin where sediment naturally gathers
    float concavity = max(blurred_height - h, 0.0);
    
    // Normalize concavity (0.5 hectometers = 50 meters relief) into an accumulation ratio [0, 1]
    float valley_accumulation = clamp(concavity / 0.5, 0.0, 1.0);

    // Blend lowland preference with valley concavity, modulated by slope flatness
    float sediment_ratio = (lowland_bias * 0.5 + valley_accumulation * 0.5) * flat_mask;

    // Convert dimensionless sediment ratio into physical sediment depth (hectometers: 1.0 = 100m)
    float final_sediment = sediment_ratio * params.max_sediment_depth;

    // Write calculated sediment depth into the sediment layer of the float texture array
    imageStore(write_tex, ivec3(id.xy, params.f_sediment_height), vec4(final_sediment, 0.0, 0.0, 0.0));
}
