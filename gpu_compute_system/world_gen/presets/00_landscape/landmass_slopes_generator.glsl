#[compute]
#version 450

// =============================================================================
// LANDMASS SLOPES GENERATOR
// Compute pass that calculates surface gradient vectors from bedrock elevation.
// Physical units: Dimensionless downhill flow slope gradient vectors (rise over run per cell).
// Bindings: Reads bedrock height from write_tex (Set 0, Binding 0);
//           Writes downhill slope X and Y components to write_tex (Set 0, Binding 0).
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

const float PI = 3.14159265359;
const float HALF_PI = 1.57079632679;

layout(push_constant) uniform Params {
	int f_bedrock_height;
	int f_slope_x;
	int f_slope_y;
} params;

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

// Samples bedrock elevation at a neighbor position with spherical edge wrapping
float get_height(ivec2 pos, ivec2 size) {
    float unused_sign;
    ivec2 wrapped_pos = polar_wrap(pos, size, unused_sign);
    return imageLoad(write_tex, ivec3(wrapped_pos, params.f_bedrock_height)).r;
}

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

    // Sample bedrock elevation of the 8 surrounding neighbors:
    // tl: top-left (northwest)  | t: top (north)  | tr: top-right (northeast)
    // l:  left (west)           |                 | r:  right (east)
    // bl: bottom-left (southwest)| b: bottom (south)| br: bottom-right (southeast)
    float tl = get_height(id.xy + ivec2(-1, -1), size.xy);
    float t  = get_height(id.xy + ivec2( 0, -1), size.xy);
    float tr = get_height(id.xy + ivec2( 1, -1), size.xy);
    float l  = get_height(id.xy + ivec2(-1,  0), size.xy);
    float r  = get_height(id.xy + ivec2( 1,  0), size.xy);
    float bl = get_height(id.xy + ivec2(-1,  1), size.xy);
    float b  = get_height(id.xy + ivec2( 0,  1), size.xy);
    float br = get_height(id.xy + ivec2( 1,  1), size.xy);

    // Compute surface elevation gradient using a 3x3 Scharr/Sobel filter kernel:
    // gx: horizontal elevation difference (weighted east neighbors minus west neighbors)
    // gy: vertical elevation difference (weighted south neighbors minus north neighbors)
    float gx = ((3*tr + 10*r + 3*br) - (3*tl + 10*l + 3*bl))/32.0;
    float gy = ((3*bl + 10*b + 3*br) - (3*tl + 10*t + 3*tr))/32.0;

    // Invert gradient signs so the vector represents downhill gravity flow instead of uphill ascent
    float flow_x = -gx;
    float flow_y = -gy;

    // Store downhill slope vectors in the slope X and Y layers of the float texture array
    imageStore(write_tex, ivec3(id.xy, params.f_slope_x), vec4(flow_x, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id.xy, params.f_slope_y), vec4(flow_y, 0.0, 0.0, 0.0));
}
