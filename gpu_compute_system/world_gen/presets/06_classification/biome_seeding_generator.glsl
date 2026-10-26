#[compute]
#version 450

// ==========================================
// BIOME SEEDING GENERATOR (World-Gen Bootstrap)
// ==========================================
// One-shot classification of all 262,144 cells at the END of the world-gen
// stack. Runs exactly once (repeat_times = 1). Emits ZERO events — the runtime
// classifier only ever handles deltas from this baseline (plan §1 principle 5,
// §2.5).
//
// Algorithm: identical 6D feature vector + nearest-centroid evaluation as the
// runtime classifier (biome_classifier_sim.glsl), with exactly two differences:
//   1. No hysteresis, no incumbent — every cell takes its arg-max centroid
//      unconditionally.
//   2. Attribution bits are written as zero (no spells exist during generation),
//      but the FULL 32-bit texel format (ID low byte + attribution upper 24
//      bits) is written so the runtime classifier's read-modify pattern is
//      never surprised by a legacy texel shape.
//
// Single-writer discipline: plain exact imageStore on binding 2 — safe during
// generation (no concurrent consumers; nothing reads BIOME_TYPE before
// on_generation_complete).
//
// 6D INPUTS (all produced by earlier generators in the stack):
//   T: GROUND_TEMP / AIR_TEMP / WATER_TEMP  (gen_ground_heat, gen_air_temp, gen_water_base)
//   M: HUMIDITY                             (gen_thermodynamics)
//   W: WATER_LIQUID_HEIGHT + WATER_ICE_HEIGHT (gen_water_base/flow, gen_ice_*)
//   V_tree/V_herb: TREES_CANOPY / GRASSES / SHRUBS (gen_flora_seeding)
//   S: SALINITY                             (gen_water_flow — marine fill)
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

// === PUSH CONSTANTS ===
// WorldGen: NO deltaTime. Order MUST match push_constants_resources in
// gen_biome_seeding.tres.
layout(push_constant) uniform Params {
    // 1. Explicit Layer Indices
    int f_ground_temp;        // LANDSCAPE float layer 4 (GROUND_TEMP)
    int f_air_temp;           // ATMOSPHERE float layer 2 (AIR_TEMP)
    int f_water_temp;         // WATER float layer 6 (WATER_TEMP)
    int f_humidity;           // ATMOSPHERE float layer 3 (HUMIDITY)
    int f_water_liquid_height;// WATER float layer 0 (WATER_LIQUID_HEIGHT)
    int f_water_ice_height;   // WATER float layer 1 (WATER_ICE_HEIGHT)
    int a_salinity;           // WATER atomic layer 3 (SALINITY)
    int a_grasses;            // FLORA atomic layer 0 (GRASSES)
    int a_shrubs;             // FLORA atomic layer 1 (SHRUBS)
    int a_trees_canopy;       // FLORA atomic layer 2 (TREES_CANOPY)
    int a_biome_type;         // LANDSCAPE atomic layer 3 (BIOME_TYPE)

    // 2. WorldConfig Constants
    float atomic_multiplier;        // 100.0 — WATER/LANDSCAPE atomic conversion
    float flora_atomic_multiplier;  // 1,000,000.0 — FLORA atomic conversion
} params;

// ===== GENERATED BIOME TABLES — DO NOT EDIT BELOW (tools/generate_biome_tables.py) =====
const uint BIOME_COUNT = 18u;
const uint BIOME_UNCLASSIFIED = 255u; // sentinel: 'not yet evaluated' (plan §2.1)
const float HYSTERESIS_DELTA = 0.15;

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

// Normalization constants for the 6D feature vector (plan §2.2).
const float DEPTH_LOG_DIVISOR = 3.5;  // log10(1 + depth_m) / 3.5
const float TEMP_RANGE = 90.0;               // (temp_c + 40) / 90.0
const float TEMP_MIN_C = -40.0;
const float K_TREE = 5.0;
const float K_SHRUB = 3.0;
const float K_GRASS = 1.0;
// ===== END GENERATED BIOME TABLES =====

// === GENERATED CODE INJECTION POINT (tools/generate_biome_tables.py) ===

// Evaluates the 18-challenger nearest-centroid score for a normalized feature
// vector split as (T, M, W, V_tree) + (V_herb, S): Score_k = x·b_k - C_k.
float evaluate_score(uint k, vec4 x_part1, vec2 x_part2) {
    return dot(x_part1, BIOME_TMWV[k]) + dot(x_part2, BIOME_HS[k]) - BIOME_OFFSET[k];
}

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

    // --- 1. Fetch 6D feature sources ---
    float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
    float air_temp    = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
    float water_temp  = imageLoad(write_tex, ivec3(id.xy, params.f_water_temp)).r;
    float humidity    = imageLoad(write_tex, ivec3(id.xy, params.f_humidity)).r;
    float liquid_h    = imageLoad(write_tex, ivec3(id.xy, params.f_water_liquid_height)).r;
    float ice_h       = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;

    uint u_salinity = imageLoad(atomic_tex, ivec3(id.xy, params.a_salinity)).r;
    uint u_grasses  = imageLoad(atomic_tex, ivec3(id.xy, params.a_grasses)).r;
    uint u_shrubs   = imageLoad(atomic_tex, ivec3(id.xy, params.a_shrubs)).r;
    uint u_trees    = imageLoad(atomic_tex, ivec3(id.xy, params.a_trees_canopy)).r;

    // --- 2. Build the normalized 6D feature vector x (plan §2.2) ---
    // 1. Water depth / submersion: [0m, 3500m] -> [0, 1] log scale.
    // (GLSL has no log10; log2(x)/log2(10) is the exact base-10 logarithm.)
    float depth_m = (liquid_h + ice_h) * 100.0; // hectometers -> meters
    float submerged = step(0.0001, liquid_h + ice_h);
    float w_norm = clamp(log2(1.0 + depth_m) / DEPTH_LOG_DIVISOR, 0.0, 1.0);

    // 2. Temperature: ground/air blend on land, WATER_TEMP when submerged
    //    (plan §7.5 — marine centroids sit between water and air baselines).
    float temp_c = mix(mix(ground_temp, air_temp, 0.5), water_temp, submerged);
    float t_norm = clamp((temp_c - TEMP_MIN_C) / TEMP_RANGE, 0.0, 1.0);

    // 3. Atmospheric moisture: specific humidity ratio clamped to [0, 1].
    float m_norm = clamp(humidity, 0.0, 1.0);

    // 4. Tree canopy density: biomass / K_tree.
    float trees = float(u_trees) / params.flora_atomic_multiplier;
    float v_tree = clamp(trees / K_TREE, 0.0, 1.0);

    // 5. Herbaceous cover: (grass/K_grass + shrub/K_shrub) * 0.5.
    float grasses = float(u_grasses) / params.flora_atomic_multiplier;
    float shrubs = float(u_shrubs) / params.flora_atomic_multiplier;
    float v_herb = clamp((grasses / K_GRASS + shrubs / K_SHRUB) * 0.5, 0.0, 1.0);

    // 6. Salinity: dimensionless concentration ratio [0, 1].
    float s_norm = clamp(float(u_salinity) / params.atomic_multiplier, 0.0, 1.0);

    vec4 x_part1 = vec4(t_norm, m_norm, w_norm, v_tree);
    vec2 x_part2 = vec2(v_herb, s_norm);

    // --- 3. Unconditional arg-max over the 18 centroids (no incumbent, no
    //       hysteresis at bootstrap — plan §2.5) ---
    float best_score = -1e9;
    uint best_id = 0u;
    for (uint i = 0u; i < BIOME_COUNT; i++) {
        float s = evaluate_score(i, x_part1, x_part2);
        // Strict '>' keeps the FIRST maximum — catalog order breaks ties
        // deterministically and identically to the runtime classifier.
        if (s > best_score) {
            best_score = s;
            best_id = i;
        }
    }

    // --- 4. Write the full 32-bit texel: attribution zero (no spells exist
    //       during generation) + biome ID low byte ---
    uint new_texel = (0u << 8) | (best_id & 0xFFu);
    imageStore(atomic_tex, ivec3(id.xy, params.a_biome_type), uvec4(new_texel, 0u, 0u, 0u));
}
