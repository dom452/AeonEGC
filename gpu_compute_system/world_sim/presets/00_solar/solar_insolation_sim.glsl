#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// === UNIFIED SIMULATION UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f) | 1: Fine Float Read (r16f) | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)     | 4: SSBO Read (std430)     | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f)| 7: Coarse Float Read (r32f)
layout(r16f, set = 0, binding = 0) restrict uniform image2DArray write_tex;
layout(r16f, set = 0, binding = 1) restrict readonly uniform image2DArray read_tex;
layout(r32ui, set = 0, binding = 2) uniform uimage2DArray atomic_tex;
layout(r16f, set = 0, binding = 5) restrict writeonly uniform image2DArray atomic_vis_tex;
layout(r32f, set = 0, binding = 6) restrict uniform image2DArray coarse_write_tex;
layout(r32f, set = 0, binding = 7) restrict readonly uniform image2DArray coarse_read_tex;

layout(push_constant) uniform Params {
    float deltaTime; 

    int f_sunlight;
    int f_tidal_force;

    // --- USER PUSH CONSTANTS ---
    float time_msec;           // Total elapsed simulation time in milliseconds
    float days_per_year;       // How many in-game days make a year (e.g. 36.0 or 365.0)
    float max_axial_tilt;      // e.g. 0.409 radians (23.5 degrees)
    float base_solar_power;    // Max intensity multiplier at zenith
    float planetary_diameter;  // Physical diameter in km (e.g. 12742.0 for Earth)
} params;

// Constants
const float PI = 3.14159265359;
const float TWO_PI = 6.28318530718;

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Time calculations
    // params.time_msec now directly receives total elapsed simulated days from GameStateManager
    float elapsed_days = params.time_msec;
    
    // Day cycle: 0 to 2PI over the course of 1 elapsed day
    float time_of_day = fract(elapsed_days) * TWO_PI;
    
    // Year cycle: 0 to 2PI over the course of days_per_year
    float time_of_year = fract(elapsed_days / params.days_per_year) * TWO_PI;

    // Latitude mapping
    // Model B (cell-centered): poles reside on outer texture boundary edges (y = -0.5, y = size.y - 0.5)
    float normalized_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - normalized_y) * PI;

    // Solar Declination (Axial Tilt based on season)
    // Positive in Northern Hemisphere summer, Negative in winter
    float declination = params.max_axial_tilt * cos(time_of_year);

    // Cache trigonometric values to avoid redundant sin/cos evaluations
    // (used by both cos_zenith and tidal_pull calculations)
    float sin_lat = sin(latitude);
    float cos_lat = cos(latitude);
    float sin_dec = sin(declination);
    float cos_dec = cos(declination);

    // Longitude mapping (cell-centered)
    // X = 0 to size.x-1 maps to 0 to TWO_PI
    float longitude = ((float(id.x) + 0.5) / float(size.x)) * TWO_PI;

    // Solar Zenith Angle (The angle of the sun in the sky relative to directly overhead)
    // Standard formula: cos(zenith) = sin(lat)*sin(dec) + cos(lat)*cos(dec)*cos(hour_angle)
    // Incorporate longitude so daytime sweeps horizontally across the X-axis
    float hour_angle = time_of_day + longitude - PI;
    
    float cos_zenith = sin_lat * sin_dec + cos_lat * cos_dec * cos(hour_angle);
    
    // Calculate twilight arc width W based on planetary diameter
    // On Earth (diameter = 12742.0 km), W is ~0.157 (~9° twilight transition band)
    float W = clamp(2000.0 / max(params.planetary_diameter, 1.0), 0.01, 0.5);

    // C1 smooth Lambertian solar insolation curve with soft twilight transition [-W, +W]
    // Preserves smooth 1.0 -> 0.0 solar gradient across the day side while eliminating hard edges
    float clamped_x = clamp(cos_zenith, -W, W);
    float twilight_entry = (clamped_x + W) * (clamped_x + W) / (4.0 * W);
    float insolation = twilight_entry + max(0.0, cos_zenith - W);
    
    // Apply power multiplier (base_solar_power = 1.0 for normalized ENERGY.SUNLIGHT in [0.0, 1.0])
    float final_sunlight = insolation * params.base_solar_power;

    // Solar Tidal Force Calculation (Semidiurnal Tide)
    // Tidal pull peaks at subsolar (midday) and antisolar (midnight) points
    // Uses cached trig values: cos(lat-dec) = cos_lat*cos_dec + sin_lat*sin_dec
    float tidal_pull = cos(2.0 * hour_angle) * (cos_lat * cos_dec + sin_lat * sin_dec);

    // Write to the ENERGY float grid (SUNLIGHT and TIDAL_FORCE layers)
    imageStore(write_tex, ivec3(id, params.f_sunlight), vec4(final_sunlight, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_tidal_force), vec4(tidal_pull, 0.0, 0.0, 0.0));
}
