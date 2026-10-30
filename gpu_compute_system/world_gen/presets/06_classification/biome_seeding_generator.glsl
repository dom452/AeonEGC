#[compute]
#version 450

// =============================================================================
// BIOME SEEDING GENERATOR
// Compute pass that classifies initial biomes across all world cells at the end of world generation.
// Physical units: Evaluates 6D environmental feature vector (temperature in °C, humidity [0, 1],
//                water depth in meters, tree/herbaceous cover [0, 1], salinity [0, 1])
//                against 18 canonical biome centroids.
// Bindings: Reads climate from write_tex (Set 0, Binding 0) and vegetation/salinity from atomic_tex (Set 0, Binding 2);
//           Writes 32-bit biome texel (ID in low byte, attribution in upper 24 bits) to atomic_tex (Set 0, Binding 2).
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
    int f_ground_temp;         // Index of ground temperature layer in float texture array
    int f_air_temp;            // Index of air temperature layer in float texture array
    int f_water_temp;          // Index of water temperature layer in float texture array
    int f_humidity;            // Index of atmospheric humidity layer in float texture array
    int f_water_liquid_height; // Index of liquid water depth layer in float texture array
    int f_water_ice_height;    // Index of ice thickness layer in float texture array
    int a_salinity;            // Index of salinity layer in atomic texture array
    int a_grasses;             // Index of grass biomass layer in atomic texture array
    int a_shrubs;              // Index of shrub biomass layer in atomic texture array
    int a_trees_canopy;        // Index of tree canopy biomass layer in atomic texture array
    int a_biome_type;          // Index of biome classification layer in atomic texture array

    float atomic_multiplier;       // Scale factor converting physical float units to fixed-point uint
    float flora_atomic_multiplier; // Scale factor converting vegetation biomass to fixed-point uint
} params;

// ===== GENERATED BIOME TABLES — DO NOT EDIT BELOW (tools/generate_biome_tables.py) =====
const uint BIOME_COUNT = 18u;
const uint BIOME_UNCLASSIFIED = 255u; // Sentinel indicating unclassified terrain
const float HYSTERESIS_DELTA = 0.15;

// Nearest-centroid dot product weights for the 18 biomes:
// Score_k = dot(x_part1, BIOME_TMWV[k]) + dot(x_part2, BIOME_HS[k]) - BIOME_OFFSET[k]
const vec4 BIOME_TMWV[18] = vec4[](
    vec4(0.111, 0.029, 0.771, 0.0), // Glacial Ice Sheet
    vec4(0.311, 0.071, 0.0, 0.0), // Polar Tundra
    vec4(0.422, 0.171, 0.0, 0.7), // Boreal Taiga
    vec4(0.467, 0.257, 0.0, 0.05), // Alpine Meadow
    vec4(0.578, 0.314, 0.0, 0.8), // Temperate Forest
    vec4(0.556, 0.143, 0.0, 0.05), // Temperate Grassland
    vec4(0.544, 0.743, 0.0, 0.95), // Temperate Rainforest
    vec4(0.633, 0.157, 0.0, 0.25), // Mediterranean Scrub
    vec4(0.8, 0.023, 0.0, 0.0), // Subtropical Desert
    vec4(0.733, 0.214, 0.0, 0.2), // Semi-Arid Savanna
    vec4(0.744, 0.914, 0.0, 0.98), // Tropical Rainforest
    vec4(0.711, 0.114, 0.05, 0.4), // Thermal Oasis
    vec4(0.667, 0.457, 0.086, 0.2), // Freshwater Wetland
    vec4(0.733, 0.514, 0.114, 0.75), // Mangrove Estuary
    vec4(0.578, 0.229, 0.404, 0.0), // Freshwater Lake
    vec4(0.244, 0.057, 0.488, 0.0), // Sea Ice / Frozen Sea
    vec4(0.667, 0.286, 0.461, 0.0), // Shallow Coastal Shelf
    vec4(0.556, 0.286, 0.971, 0.0) // Pelagic Deep Ocean
);
const vec2 BIOME_HS[18] = vec2[](
    vec2(0.0, 0.0), // Glacial Ice Sheet
    vec2(0.35, 0.0), // Polar Tundra
    vec2(0.3, 0.0), // Boreal Taiga
    vec2(0.6, 0.0), // Alpine Meadow
    vec2(0.4, 0.0), // Temperate Forest
    vec2(0.9, 0.0), // Temperate Grassland
    vec2(0.65, 0.0), // Temperate Rainforest
    vec2(0.65, 0.05), // Mediterranean Scrub
    vec2(0.05, 0.125), // Subtropical Desert
    vec2(0.75, 0.0), // Semi-Arid Savanna
    vec2(0.8, 0.0), // Tropical Rainforest
    vec2(0.85, 0.025), // Thermal Oasis
    vec2(0.85, 0.013), // Freshwater Wetland
    vec2(0.3, 0.5), // Mangrove Estuary
    vec2(0.15, 0.005), // Freshwater Lake
    vec2(0.0, 0.75), // Sea Ice / Frozen Sea
    vec2(0.35, 0.875), // Shallow Coastal Shelf
    vec2(0.05, 0.875) // Pelagic Deep Ocean
);
const float BIOME_OFFSET[18] = float[](
    0.303802, // Glacial Ice Sheet
    0.112131, // Polar Tundra
    0.393662, // Boreal Taiga
    0.323319, // Alpine Meadow
    0.61634, // Temperate Forest
    0.571043, // Temperate Grassland
    1.086493, // Temperate Rainforest
    0.456419, // Mediterranean Scrub
    0.329327, // Subtropical Desert
    0.592793, // Semi-Arid Savanna
    1.494666, // Tropical Rainforest
    0.702071, // Thermal Oasis
    0.711901, // Freshwater Wetland
    0.858491, // Mangrove Estuary
    0.286133, // Freshwater Lake
    0.431715, // Sea Ice / Frozen Sea
    0.813666, // Shallow Coastal Shelf
    1.050949 // Pelagic Deep Ocean
);

// Normalization divisors for the 6D feature vector
const float DEPTH_LOG_DIVISOR = 3.5;  // Compresses [0, 3500m] water depth to [0, 1] via log10 scale
const float TEMP_RANGE = 90.0;        // Normalizes temperature from [-40°C, 50°C] into [0, 1]
const float TEMP_MIN_C = -40.0;
const float K_TREE = 5.0;             // Tree canopy saturation density
const float K_SHRUB = 3.0;            // Shrub cover saturation density
const float K_GRASS = 1.0;            // Grass cover saturation density
// ===== END GENERATED BIOME TABLES =====

// Evaluates the nearest-centroid score for a biome candidate: higher score indicates closer Euclidean distance
float evaluate_score(uint k, vec4 x_part1, vec2 x_part2) {
    return dot(x_part1, BIOME_TMWV[k]) + dot(x_part2, BIOME_HS[k]) - BIOME_OFFSET[k];
}

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

    // 1. Read environmental inputs from float texture array
    float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
    float air_temp    = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
    float water_temp  = imageLoad(write_tex, ivec3(id.xy, params.f_water_temp)).r;
    float humidity    = imageLoad(write_tex, ivec3(id.xy, params.f_humidity)).r;
    float liquid_h    = imageLoad(write_tex, ivec3(id.xy, params.f_water_liquid_height)).r;
    float ice_h       = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;

    // Read salinity and flora biomass from atomic storage
    uint u_salinity = imageLoad(atomic_tex, ivec3(id.xy, params.a_salinity)).r;
    uint u_grasses  = imageLoad(atomic_tex, ivec3(id.xy, params.a_grasses)).r;
    uint u_shrubs   = imageLoad(atomic_tex, ivec3(id.xy, params.a_shrubs)).r;
    uint u_trees    = imageLoad(atomic_tex, ivec3(id.xy, params.a_trees_canopy)).r;

    // 2. Build normalized 6D feature vector x = (Temperature, Moisture, Water Depth, Tree Density, Herbaceous Cover, Salinity)
    // Water column depth: convert hectometers to meters and compress via base-10 log scale
    float depth_m = (liquid_h + ice_h) * 100.0;
    float submerged = step(0.0001, liquid_h + ice_h);
    float w_norm = clamp(log2(1.0 + depth_m) / DEPTH_LOG_DIVISOR, 0.0, 1.0);

    // Temperature: blend of ground/air on land, water temperature when submerged
    float temp_c = mix(mix(ground_temp, air_temp, 0.5), water_temp, submerged);
    float t_norm = clamp((temp_c - TEMP_MIN_C) / TEMP_RANGE, 0.0, 1.0);

    // Atmospheric moisture ratio [0, 1]
    float m_norm = clamp(humidity, 0.0, 1.0);

    // Tree canopy cover normalized against saturation density
    float trees = float(u_trees) / params.flora_atomic_multiplier;
    float v_tree = clamp(trees / K_TREE, 0.0, 1.0);

    // Herbaceous vegetation (grasses + shrubs) normalized against saturation density
    float grasses = float(u_grasses) / params.flora_atomic_multiplier;
    float shrubs = float(u_shrubs) / params.flora_atomic_multiplier;
    float v_herb = clamp((grasses / K_GRASS + shrubs / K_SHRUB) * 0.5, 0.0, 1.0);

    // Dissolved water salinity concentration ratio [0, 1]
    float s_norm = clamp(float(u_salinity) / params.atomic_multiplier, 0.0, 1.0);

    vec4 x_part1 = vec4(t_norm, m_norm, w_norm, v_tree);
    vec2 x_part2 = vec2(v_herb, s_norm);

    // 3. Find the closest matching biome centroid via arg-max scoring
    float best_score = -1e9;
    uint best_id = 0u;
    for (uint i = 0u; i < BIOME_COUNT; i++) {
        float s = evaluate_score(i, x_part1, x_part2);
        if (s > best_score) {
            best_score = s;
            best_id = i;
        }
    }

    // 4. Encode full 32-bit texel: attribution bits in upper 24 bits (0 during generation)
    // and biome classification ID in low 8 bits
    uint new_texel = (0u << 8) | (best_id & 0xFFu);
    imageStore(atomic_tex, ivec3(id.xy, params.a_biome_type), uvec4(new_texel, 0u, 0u, 0u));
}
