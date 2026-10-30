#[compute]
#version 450

// =============================================================================
// SUNLIGHT GENERATOR
// Compute pass that calculates baseline top-of-atmosphere daily average solar insolation.
// Physical units: Dimensionless solar insolation flux [0.0, 1.0], peaking at the sub-solar latitude.
// Bindings: Writes baseline solar insolation to write_tex (Set 0, Binding 0).
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
    int f_sunlight; // Index of sunlight insolation layer in the float texture array

    float max_axial_tilt;       // Planetary axial tilt in radians (e.g., 0.409 rad ≈ 23.5 degrees)
    float initial_season_phase; // Initial orbital position in radians (e.g., 0.0 = northern summer solstice)
} params;

const float PI = 3.14159265359;

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;
    
    // Calculate initial solar declination (latitude where the sun is directly overhead at noon)
    // based on planetary tilt angle and current orbital seasonal phase
    float declination_init = params.max_axial_tilt * cos(params.initial_season_phase);

    // Map cell-centered vertical coordinate into latitude from North Pole (+PI/2) to South Pole (-PI/2)
    float normalized_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - normalized_y) * PI;

    // Compute angular distance in radians between this cell's latitude and the sub-solar point
    float dist_from_solar_lat = abs(latitude - declination_init);

    // Evaluate cosine insolation: peak insolation (1.0) occurs directly beneath the sun,
    // dropping to 0.0 where sunlight strikes at grazing angles or in darkness
    float sunlight = max(0.0, cos(dist_from_solar_lat));

    // Store baseline daily insolation in the sunlight layer of the float texture array
    imageStore(write_tex, ivec3(id.xy, params.f_sunlight), vec4(sunlight, 0.0, 0.0, 0.0));
}


