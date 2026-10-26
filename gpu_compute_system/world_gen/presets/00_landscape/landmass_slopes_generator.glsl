#[compute]
#version 450

// ==========================================
// LANDMASS SLOPES GENERATOR
// ==========================================
// Seeds: 
//   - SLOPE.X (Float Grid, LANDSCAPE)
//   - SLOPE.Y (Float Grid, LANDSCAPE)
// Initial Values: 
//   - Derived by calculating the downhill gradient of BEDROCK_HEIGHT
//     using neighboring cell sampling.
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

const float PI = 3.14159265359;
const float HALF_PI = 1.57079632679;

layout(push_constant) uniform Params {
	int f_bedrock_height;
	int f_slope_x;
	int f_slope_y;
} params;

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

float get_height(ivec2 pos, ivec2 size) {
    float unused_sign;
    ivec2 wrapped_pos = polar_wrap(pos, size, unused_sign);
    return imageLoad(write_tex, ivec3(wrapped_pos, params.f_bedrock_height)).r;
}

void main() {
ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
ivec3 size = imageSize(write_tex);
if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

float tl = get_height(id.xy + ivec2(-1, -1), size.xy);
float t  = get_height(id.xy + ivec2( 0, -1), size.xy);
float tr = get_height(id.xy + ivec2( 1, -1), size.xy);
float l  = get_height(id.xy + ivec2(-1,  0), size.xy);
float r  = get_height(id.xy + ivec2( 1,  0), size.xy);
float bl = get_height(id.xy + ivec2(-1,  1), size.xy);
float b  = get_height(id.xy + ivec2( 0,  1), size.xy);
float br = get_height(id.xy + ivec2( 1,  1), size.xy);

// 1. FLOW ANGLE & STEEPNESS 
float gx = ((3*tr + 10*r + 3*br) - (3*tl + 10*l + 3*bl))/32.0;
float gy = ((3*bl + 10*b + 3*br) - (3*tl + 10*t + 3*tr))/32.0;

// Invert the gradient so it points downhill instead of uphill
float flow_x = -gx;
float flow_y = -gy;

// 2. FINAL WRITE-BACK
imageStore(write_tex, ivec3(id.xy, params.f_slope_x), vec4(flow_x, 0.0, 0.0, 0.0));
imageStore(write_tex, ivec3(id.xy, params.f_slope_y), vec4(flow_y, 0.0, 0.0, 0.0));
}
