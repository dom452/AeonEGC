#[compute]
#version 450

// =============================================================================
// SOLAR INSOLATION SIMULATION
// Compute pass that calculates diurnal and seasonal solar insolation and solar gravitational tidal pull.
// Physical units: Sunlight flux in normalized intensity [0.0, 1.0], tidal gravitational pull [-1.0, 1.0].
// Bindings: Writes solar insolation and tidal force layers to write_tex (Set 0, Binding 0).
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

    int f_sunlight;    // Index of solar insolation layer in float texture array
    int f_tidal_force; // Index of solar tidal force layer in float texture array

    float time_msec;          // Total elapsed simulation time in days
    float days_per_year;      // Number of simulation days in an orbital year (e.g., 365.0)
    float max_axial_tilt;     // Planetary rotational axis tilt in radians (e.g., 0.409 rad ≈ 23.5°)
    float base_solar_power;   // Maximum solar radiation flux multiplier at the sub-solar point
    float planetary_diameter; // Physical planetary diameter in kilometers (e.g., 12742.0)
} params;

const float PI = 3.14159265359;
const float TWO_PI = 6.28318530718;

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Time calculations:
    // elapsed_days tracks the continuous progression of simulation days
    float elapsed_days = params.time_msec;
    
    // Day cycle: fractional day progress converted to radians [0, 2π]
    float time_of_day = fract(elapsed_days) * TWO_PI;
    
    // Year cycle: orbital year progress converted to radians [0, 2π]
    float time_of_year = fract(elapsed_days / params.days_per_year) * TWO_PI;

    // Latitude mapping from North Pole (+π/2) to South Pole (-π/2)
    float normalized_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - normalized_y) * PI;

    // Solar Declination: latitude directly under the sun, oscillating seasonally with axial tilt
    // Positive during northern hemisphere summer; negative during northern winter
    float declination = params.max_axial_tilt * cos(time_of_year);

    // Cache trigonometric values to avoid duplicate transcendentals across solar and tidal equations
    float sin_lat = sin(latitude);
    float cos_lat = cos(latitude);
    float sin_dec = sin(declination);
    float cos_dec = cos(declination);

    // Longitude mapping: converts horizontal pixel position to radians [0, 2π]
    float longitude = ((float(id.x) + 0.5) / float(size.x)) * TWO_PI;

    // Solar Zenith Angle: computes cosine of the angular distance between zenith and sun
    // hour_angle sweeps sunlight horizontally across the grid as the planet rotates
    float hour_angle = time_of_day + longitude - PI;
    float cos_zenith = sin_lat * sin_dec + cos_lat * cos_dec * cos(hour_angle);
    
    // Atmospheric twilight arc width W: wider on small planets, narrower on large planets
    // Earth-sized planets (12742 km) produce an approximately 9° soft atmospheric twilight transition band
    float W = clamp(2000.0 / max(params.planetary_diameter, 1.0), 0.01, 0.5);

    // Continuous C1 Lambertian insolation curve with soft twilight blending across [-W, +W]
    // Prevents harsh terminator shadows and provides physically plausible dawn/dusk gradients
    float clamped_x = clamp(cos_zenith, -W, W);
    float twilight_entry = (clamped_x + W) * (clamped_x + W) / (4.0 * W);
    float insolation = twilight_entry + max(0.0, cos_zenith - W);
    
    // Scale dimensionless insolation by the base solar flux constant
    float final_sunlight = insolation * params.base_solar_power;

    // Semidiurnal Solar Tidal Force:
    // Gravitational tidal forces peak twice daily: at midday (subsolar) and midnight (antisolar)
    float tidal_pull = cos(2.0 * hour_angle) * (cos_lat * cos_dec + sin_lat * sin_dec);

    // Store calculated insolation and tidal pull in the energy layers of the float texture array
    imageStore(write_tex, ivec3(id, params.f_sunlight), vec4(final_sunlight, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_tidal_force), vec4(tidal_pull, 0.0, 0.0, 0.0));
}
