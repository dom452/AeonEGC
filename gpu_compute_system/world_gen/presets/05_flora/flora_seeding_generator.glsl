#[compute]
#version 450

// =============================================================================
// FLORA SEEDING GENERATOR
// Compute pass that seeds initial terrestrial flora biomass, growth modifiers, and soil nutrients.
// Physical units: Growth suitability [0.0, 1.0], biomass and nutrient densities scaled by atomic multipliers.
// Bindings: Reads climate from write_tex (Set 0, Binding 0) and soil nutrients from atomic_tex (Set 0, Binding 2);
//           Writes growth rate modifier to write_tex (Set 0, Binding 0);
//           Accumulates grass biomass and soil nutrients into atomic_tex (Set 0, Binding 2).
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
    int f_growth_rate_modifier; // Index of growth rate modifier layer in float texture array
    int f_ground_temp;          // Index of ground temperature layer in float texture array
    int f_air_temp;             // Index of air temperature layer in float texture array
    int f_humidity;             // Index of atmospheric humidity layer in float texture array
    int f_sunlight;             // Index of solar insolation layer in float texture array
    int f_liquid_height;        // Index of liquid water depth layer in float texture array
    int f_ice_height;           // Index of ice thickness layer in float texture array

    int a_grasses;        // Index of grass biomass layer in atomic texture array
    int a_soil_nutrients; // Index of soil nutrients layer in atomic texture array

    float flora_atomic_multiplier; // Scale factor converting vegetation biomass float to fixed-point uint
    float atomic_multiplier;       // Scale factor converting soil nutrients float to fixed-point uint
    float seed_amount;             // Baseline initial grass seed biomass density
} params;

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    // Read surface physical environment states from the float texture array
    float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
    float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
    float humidity = imageLoad(write_tex, ivec3(id.xy, params.f_humidity)).r;
    float sunlight = imageLoad(write_tex, ivec3(id.xy, params.f_sunlight)).r;
    float liquid = imageLoad(write_tex, ivec3(id.xy, params.f_liquid_height)).r;
    float ice = imageLoad(write_tex, ivec3(id.xy, params.f_ice_height)).r;

    // Read baseline soil nutrients from atomic storage and convert to float units
    uint u_nutrients = imageLoad(atomic_tex, ivec3(id.xy, params.a_soil_nutrients)).r;
    float nutrients = float(u_nutrients) / params.atomic_multiplier;

    // Compute interface temperature by averaging ground and atmospheric temperatures
    float temp = mix(ground_temp, air_temp, 0.5);

    // Temperature suitability curve: parabolic bell curve peaked at optimal 22°C (zero below 0°C)
    float temp_norm = (temp - 22.0) / 22.0;
    float temp_factor = clamp(1.0 - temp_norm * temp_norm, 0.0, 1.0) * step(0.0, temp);

    // Solar radiation factor: plants require light for photosynthesis, attenuated heavily under ice sheets
    float effective_sunlight = sunlight * clamp(1.0 - ice * 10.0, 0.0, 1.0);

    // Moisture factor: terrestrial flora requires soil moisture or humidity, but drowns if deeply submerged
    float soil_moisture = max(liquid, humidity);
    float terrestrial_moisture = clamp(0.5 + soil_moisture * 2.0, 0.5, 1.0) * clamp(2.0 - liquid / 0.3, 0.0, 1.0);

    // Nutrient fertility factor: fertility increases with available soil nutrients up to saturation at 5.0
    float nutrient_factor = 0.5 + clamp(nutrients / 5.0, 0.0, 1.0);

    // Overall biological suitability [0.0, 1.0] combining temperature, light, moisture, and nutrients
    float suitability = clamp(temp_factor * effective_sunlight * terrestrial_moisture * nutrient_factor, 0.0, 1.0);

    // Compute initial grass biomass density and convert to integer fixed-point
    float grass_biomass = params.seed_amount;
    uint grass_uint = uint(grass_biomass * params.flora_atomic_multiplier);

    // Set baseline soil nutrient reservoir density (5.0 provides full fertility saturation)
    float nutrient_biomass = 5.0;
    uint nutrient_uint = uint(nutrient_biomass * params.atomic_multiplier);

    // Store environmental suitability in the growth rate modifier layer of the float texture array
    imageStore(write_tex, ivec3(id.xy, params.f_growth_rate_modifier), vec4(suitability, 0.0, 0.0, 0.0));

    // Seed initial grass biomass into the atomic simulation layer
    if (grass_uint > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_grasses), grass_uint);
    }

    // Seed baseline soil nutrients into the atomic simulation layer
    if (nutrient_uint > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_soil_nutrients), nutrient_uint);
    }
}
