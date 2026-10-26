#[compute]
#version 450

// ==========================================
// FLORA SEEDING GENERATOR
// ==========================================
// Seeds: 
//   - GROWTH_RATE_MODIFIER (Float Grid, FLORA)
//   - GRASSES (Atomic Grid, FLORA)
//   - SOIL_NUTRIENTS (Atomic Grid, LANDSCAPE)
// Initial Values: 
//   - Evaluates initial climate (TEMP, HUMIDITY, SUNLIGHT, LIQUID) to calculate
//     environmental 'suitability' (GROWTH_RATE_MODIFIER).
//   - Seeds GRASSES globally using 'seed_amount' scaled by 'flora_atomic_multiplier'.
//   - Seeds a baseline of 5.0 SOIL_NUTRIENTS globally using 'atomic_multiplier'.
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

layout(push_constant) uniform Params {
    // 1. Explicit Layer Indices
    int f_growth_rate_modifier; // FLORA layer 0 (GROWTH_RATE_MODIFIER)
    int f_ground_temp;           // LANDSCAPE layer 4 (GROUND_TEMP)
    int f_air_temp;              // ATMOSPHERE layer 2 (AIR_TEMP)
    int f_humidity;              // ATMOSPHERE layer 3 (HUMIDITY)
    int f_sunlight;              // ENERGY layer 0 (SUNLIGHT)
    int f_liquid_height;         // WATER layer 0 (WATER_LIQUID_HEIGHT)
    int f_ice_height;            // WATER layer 1 (WATER_ICE_HEIGHT)

    int a_grasses;               // FLORA atomic layer 0 (GRASSES)
    int a_soil_nutrients;        // LANDSCAPE atomic layer 1 (SOIL_NUTRIENTS)

    // 2. User / WorldConfig Constants
    float flora_atomic_multiplier; // e.g. 1000000.0
    float atomic_multiplier;       // e.g. 100.0
    float seed_amount;             // Base seed amount density (e.g. 0.5)
} params;

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    // Fetch environment states from write_tex
    float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
    float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
    float humidity = imageLoad(write_tex, ivec3(id.xy, params.f_humidity)).r;
    float sunlight = imageLoad(write_tex, ivec3(id.xy, params.f_sunlight)).r;
    float liquid = imageLoad(write_tex, ivec3(id.xy, params.f_liquid_height)).r;
    float ice = imageLoad(write_tex, ivec3(id.xy, params.f_ice_height)).r;

    // Fetch atomic nutrients from atomic_tex
    uint u_nutrients = imageLoad(atomic_tex, ivec3(id.xy, params.a_soil_nutrients)).r;
    float nutrients = float(u_nutrients) / params.atomic_multiplier;

    // Calculate suitability using the exact same evaluation as flora_ecology_sim
    float temp = mix(ground_temp, air_temp, 0.5);

    // Temperature Factor: Smooth curve centered around 22°C
    float temp_norm = (temp - 22.0) / 22.0;
    float temp_factor = clamp(1.0 - temp_norm * temp_norm, 0.0, 1.0) * step(0.0, temp);

    // Sunlight Factor (reduced under ice)
    float effective_sunlight = sunlight * clamp(1.0 - ice * 10.0, 0.0, 1.0);

    // Terrestrial Moisture Factor
    float soil_moisture = max(liquid, humidity);
    float terrestrial_moisture = clamp(0.5 + soil_moisture * 2.0, 0.5, 1.0) * clamp(2.0 - liquid / 0.3, 0.0, 1.0);

    // Soil Nutrient Factor
    float nutrient_factor = 0.5 + clamp(nutrients / 5.0, 0.0, 1.0);

    // Compute Overall Suitability for Terrestrial Flora [0.0, 1.0]
    float suitability = clamp(temp_factor * effective_sunlight * terrestrial_moisture * nutrient_factor, 0.0, 1.0);

    // Scale initial grass seed density by suitability
    float grass_biomass = params.seed_amount; //* suitability;
    uint grass_uint = uint(grass_biomass * params.flora_atomic_multiplier);

    // Seed baseline soil nutrients (LANDSCAPE atomic layer -> scaled by atomic_multiplier).
    // nutrient_factor saturates at nutrients = 5.0, so 5.0 maxes out fertility.
    float nutrient_biomass = 5.0; //* suitability;
    uint nutrient_uint = uint(nutrient_biomass * params.atomic_multiplier);

    // Store growth rate modifier float layer
    imageStore(write_tex, ivec3(id.xy, params.f_growth_rate_modifier), vec4(suitability, 0.0, 0.0, 0.0));

    // Atomic transaction to seed initial grass
    if (grass_uint > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_grasses), grass_uint);
    }

    // Atomic transaction to seed initial soil nutrients
    if (nutrient_uint > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_soil_nutrients), nutrient_uint);
    }
}
