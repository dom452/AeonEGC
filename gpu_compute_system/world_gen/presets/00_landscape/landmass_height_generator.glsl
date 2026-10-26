#[compute]
#version 450

// ==========================================
// LANDMASS HEIGHT GENERATOR
// ==========================================
// Seeds: 
//   - BEDROCK_HEIGHT (Float Grid, LANDSCAPE)
// Initial Values: 
//   - Procedurally generated from custom noise textures (Binding 1).
//   - Uses 'base_elevation', 'terrain_height_variation', and 'detail_variation' 
//     push constants to scale the noise into physical float units (1.0 = 100m).
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

layout(push_constant) uniform Params {
int f_bedrock_height;

float contrast; 
float base_elevation;
float terrain_height_variation;
float detail_variation;
} params; 

void main() {
ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
ivec3 size = imageSize(write_tex);
if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

float b_h = imageLoad(custom_tex, ivec3(id.xy, 0)).r;
float t_d = imageLoad(custom_tex, ivec3(id.xy, 1)).r;
float d_d = imageLoad(custom_tex, ivec3(id.xy, 2)).r;

float b_mod = pow(b_h, params.contrast);

// Write height directly in absolute physical float units (Hectometers: 1.0 = 100m)
float c = b_mod * params.base_elevation
    + clamp(((t_d + 0.2) * b_mod), 0.0, 1.0) * params.terrain_height_variation
    + d_d * params.detail_variation;

// Option 1: The Ice Wall (Model B: distance measured from polar boundary edges)
float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
float pole_threshold = float(size.y) * 0.05; // 5% of the height
float pole_mask = smoothstep(0.0, pole_threshold, dist_from_pole);

// Force height to the maximum possible elevation at the absolute poles
float max_elev = params.base_elevation + params.terrain_height_variation + params.detail_variation;
c = mix(max_elev, c, pole_mask);

// save the heightmap to the first layer
imageStore(write_tex, ivec3(id.xy, params.f_bedrock_height), vec4(c, 0.0, 0.0, 0.0));
}
