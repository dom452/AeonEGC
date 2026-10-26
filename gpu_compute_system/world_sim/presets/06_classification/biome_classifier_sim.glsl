#[compute]
#version 450

// ==========================================
// BIOME CLASSIFIER (Runtime, End-of-Frame)
// ==========================================
// Nearest-centroid biome classification over the 6D feature vector with
// hysteresis gating and the 255-sentinel self-heal guard (plan section 2.4/2.6).
// Pure imageStore to BIOME_TYPE (r32ui, binding 2): low byte = biome ID,
// upper 24 bits = ACTION_KEY attribution snapshot. NO event emission, NO
// atomic counters (plan section 1, principle 3 — binding 8's EventBuffer was
// decommissioned with the geothermal POC at §8.4; biome causation rides in
// this texel's attribution bits instead).
//
// MUST be dispatched AFTER flora_ecology_sim in the sim_layers array
// (end-of-frame — it must observe the most current world state).
// execution_steps = 1 (no sub-cycling).
//
// Single-writer discipline: one plain full-texel imageStore per cell
// (pattern per REF_impact_detector_sim.glsl, minus event emission). The
// seeding generator is the only other writer, and only during generation.
// ==========================================

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

// === PUSH CONSTANTS ===
// Order MUST match the push_constants_resources array in biome_classifier_sim.tres.
//   float deltaTime            @ offset 0   (LayerSimulator injects at 0)
//   int   f_ground_temp        @ offset 4   -- LANDSCAPE float sub-layer 4
//   int   f_air_temp           @ offset 8   -- ATMOSPHERE float sub-layer 2
//   int   f_water_temp         @ offset 12  -- WATER float sub-layer 6
//   int   f_humidity           @ offset 16  -- ATMOSPHERE float sub-layer 3
//   int   f_water_liquid_height@ offset 20  -- WATER float sub-layer 0
//   int   f_water_ice_height   @ offset 24  -- WATER float sub-layer 1
//   int   a_trees_canopy       @ offset 28  -- FLORA atomic sub-layer 2
//   int   a_grasses            @ offset 32  -- FLORA atomic sub-layer 0
//   int   a_shrubs             @ offset 36  -- FLORA atomic sub-layer 1
//   int   a_salinity           @ offset 40  -- WATER atomic sub-layer 3
//   int   a_biome_type         @ offset 44  -- LANDSCAPE atomic sub-layer 3
//   int   a_action_key         @ offset 48  -- PLAYER_ACTIONS atomic sub-layer 0
//   float atomic_multiplier    @ offset 52  -- WorldConfig.atomic_multiplier
//   float flora_atomic_multiplier @ offset 56 -- WorldConfig.flora_atomic_multiplier
// Total: 60 bytes, padded to 64 (plan section 2.4).
layout(push_constant) uniform Params {
    float deltaTime;

    // --- AUTO-INJECTED LAYER INDICES ---
    int f_ground_temp;          // LANDSCAPE float layer 4 (GROUND_TEMP)
    int f_air_temp;             // ATMOSPHERE float layer 2 (AIR_TEMP)
    int f_water_temp;           // WATER float layer 6 (WATER_TEMP)
    int f_humidity;             // ATMOSPHERE float layer 3 (HUMIDITY)
    int f_water_liquid_height;  // WATER float layer 0 (WATER_LIQUID_HEIGHT)
    int f_water_ice_height;     // WATER float layer 1 (WATER_ICE_HEIGHT)
    int a_trees_canopy;         // FLORA atomic layer 2 (TREES_CANOPY)
    int a_grasses;              // FLORA atomic layer 0 (GRASSES)
    int a_shrubs;               // FLORA atomic layer 1 (SHRUBS)
    int a_salinity;             // WATER atomic layer 3 (SALINITY)
    int a_biome_type;           // LANDSCAPE atomic layer 3 (BIOME_TYPE)
    int a_action_key;           // PLAYER_ACTIONS atomic layer 0 (ACTION_KEY bitmask)

    // --- WORLD CONFIG CONSTANTS ---
    float atomic_multiplier;        // uint -> float conversion (WATER/LANDSCAPE)
    float flora_atomic_multiplier;  // uint -> float conversion (FLORA)
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
// vector split as (T, M, W, V_tree) + (V_herb, S): Score_k = x*b_k - C_k.
float evaluate_score(uint k, vec4 x_part1, vec2 x_part2) {
    return dot(x_part1, BIOME_TMWV[k]) + dot(x_part2, BIOME_HS[k]) - BIOME_OFFSET[k];
}

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(read_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // --- 1. Fetch 6D feature sources ---
    float ground_temp = imageLoad(read_tex, ivec3(id, params.f_ground_temp)).r;
    float air_temp    = imageLoad(read_tex, ivec3(id, params.f_air_temp)).r;
    float water_temp  = imageLoad(read_tex, ivec3(id, params.f_water_temp)).r;
    float humidity    = imageLoad(read_tex, ivec3(id, params.f_humidity)).r;
    float liquid_h    = imageLoad(read_tex, ivec3(id, params.f_water_liquid_height)).r;
    float ice_h       = imageLoad(read_tex, ivec3(id, params.f_water_ice_height)).r;

    uint u_salinity = imageLoad(atomic_tex, ivec3(id, params.a_salinity)).r;
    uint u_grasses  = imageLoad(atomic_tex, ivec3(id, params.a_grasses)).r;
    uint u_shrubs   = imageLoad(atomic_tex, ivec3(id, params.a_shrubs)).r;
    uint u_trees    = imageLoad(atomic_tex, ivec3(id, params.a_trees_canopy)).r;

    // --- 2. Build the normalized 6D feature vector x (plan section 2.2) ---
    float depth_m = (liquid_h + ice_h) * 100.0; // hectometers -> meters
    float submerged = step(0.0001, liquid_h + ice_h);
    // (GLSL has no log10; log2(x)/log2(10) is the exact base-10 logarithm.)
    float w_norm = clamp(log2(1.0 + depth_m) / DEPTH_LOG_DIVISOR, 0.0, 1.0);

    // Submerged cells must not blend seafloor ground_temp with surface air (7.5).
    float temp_c = mix(mix(ground_temp, air_temp, 0.5), water_temp, submerged);
    float t_norm = clamp((temp_c - TEMP_MIN_C) / TEMP_RANGE, 0.0, 1.0);

    float m_norm = clamp(humidity, 0.0, 1.0);

    float trees = float(u_trees) / params.flora_atomic_multiplier;
    float v_tree = clamp(trees / K_TREE, 0.0, 1.0);

    float grasses = float(u_grasses) / params.flora_atomic_multiplier;
    float shrubs = float(u_shrubs) / params.flora_atomic_multiplier;
    float v_herb = clamp((grasses / K_GRASS + shrubs / K_SHRUB) * 0.5, 0.0, 1.0);

    float s_norm = clamp(float(u_salinity) / params.atomic_multiplier, 0.0, 1.0);

    vec4 x_part1 = vec4(t_norm, m_norm, w_norm, v_tree);
    vec2 x_part2 = vec2(v_herb, s_norm);

    // --- 3. Incumbent score with the sentinel guard (plan 2.4/2.6) ---
    // Valid incumbents are 0..17 ONLY. Anything else (255 = unclassified, any
    // other value defensively) classifies immediately — no hysteresis — and
    // prevents out-of-bounds centroid indexing on undefined VRAM contents.
    uint current_texel = imageLoad(atomic_tex, ivec3(id, params.a_biome_type)).r;
    uint current_biome_id = current_texel & 0xFFu;
    bool unclassified = (current_biome_id > 17u);
    // Clamp the incumbent to a valid index before evaluating its score.
    float current_score = unclassified ? -1e9 : evaluate_score(min(current_biome_id, 17u), x_part1, x_part2);

    // --- 4. Challenger sweep ---
    float best_challenger_score = -1e9;
    uint best_challenger_id = current_biome_id;
    for (uint i = 0u; i < BIOME_COUNT; i++) {
        float s = evaluate_score(i, x_part1, x_part2);
        // Strict '>' keeps the FIRST maximum — catalog order breaks ties
        // deterministically, identically to the seeding generator.
        if (s > best_challenger_score) {
            best_challenger_score = s;
            best_challenger_id = i;
        }
    }

    // --- 5. Attribution snapshot: the spell-presence bitmask rides in the
    //       upper 24 bits. Captured EVERY write (even self-healing ones) so
    //       the CPU diff always has a causation record (plan 2.4). ---
    uint action_key = imageLoad(atomic_tex, ivec3(id, params.a_action_key)).r & 0xFFFFFFu;
    uint new_texel = (action_key << 8) | (best_challenger_id & 0xFFu);

    // --- 6. Unclassified cells adopt the winner silently (self-heal, 2.6). ---
    if (unclassified) {
        imageStore(atomic_tex, ivec3(id, params.a_biome_type), uvec4(new_texel, 0u, 0u, 0u));
        return;
    }

    // --- 7. Transition rule: the challenger must definitively exceed the
    //       incumbent by the hysteresis margin (border-flutter suppression
    //       against diurnal and seasonal oscillation, 2.4). ---
    if (best_challenger_id != current_biome_id && (best_challenger_score > current_score + HYSTERESIS_DELTA)) {
        // Single plain store — biome ID + attribution. No event, no counter, no race.
        imageStore(atomic_tex, ivec3(id, params.a_biome_type), uvec4(new_texel, 0u, 0u, 0u));
    }
}