#[compute]
#version 450

// =============================================================================
// LANDMASS HEIGHT GENERATOR
// Compute pass that generates baseline continental bedrock elevation from procedural noise.
// Physical units: Elevation in hectometers (1.0 = 100 meters above sea-level datum).
// Bindings: Reads procedural noise from custom_tex (Set 0, Binding 15);
//           Writes bedrock elevation to write_tex (Set 0, Binding 0).
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

layout(push_constant) uniform Params {
    int f_bedrock_height;

    float contrast; 
    float base_elevation;
    float terrain_height_variation;
    float detail_variation;
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

    // Sample procedural noise octaves from custom noise texture layers:
    // b_h: Continental landmass noise (macro-scale shape of oceans vs continents)
    // t_d: Mountain and regional terrain detail noise (mid-scale mountain ranges)
    // d_d: Micro-roughness displacement noise (high-frequency surface bumps)
    float b_h = imageLoad(custom_tex, ivec3(id.xy, 0)).r;
    float t_d = imageLoad(custom_tex, ivec3(id.xy, 1)).r;
    float d_d = imageLoad(custom_tex, ivec3(id.xy, 2)).r;

    // Apply non-linear power curve to sharpen continental boundaries (steep coastlines, flat ocean basins)
    float b_mod = pow(b_h, params.contrast);

    // Combine noise octaves into composite elevation in hectometers (1.0 = 100m):
    // 1. Continental macro elevation scaled by base_elevation
    // 2. Mid-frequency mountain ridges, masked so they primarily form on continental landmasses
    // 3. High-frequency micro detail for local terrain roughness
    float c = b_mod * params.base_elevation
        + clamp(((t_d + 0.2) * b_mod), 0.0, 1.0) * params.terrain_height_variation
        + d_d * params.detail_variation;

    // Compute distance to the nearest polar boundary (north or south texture edge)
    float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
    float pole_threshold = float(size.y) * 0.05; // Outer 5% polar rim
    float pole_mask = smoothstep(0.0, pole_threshold, dist_from_pole);

    // Blend elevation smoothly upward at extreme polar edges to create an impenetrable polar barrier
    float max_elev = params.base_elevation + params.terrain_height_variation + params.detail_variation;
    c = mix(max_elev, c, pole_mask);

    // Write final bedrock elevation to the bedrock layer in the simulation float texture array
    imageStore(write_tex, ivec3(id.xy, params.f_bedrock_height), vec4(c, 0.0, 0.0, 0.0));
}
