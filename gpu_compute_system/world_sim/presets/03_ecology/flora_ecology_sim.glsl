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

    // --- AUTO-INJECTED LAYER INDICES ---
    int f_growth_rate_modifier; // FLORA layer 0 (GROWTH_RATE_MODIFIER)
    int f_canopy_shade;          // FLORA layer 1 (CANOPY_SHADE)
    int f_scent_grasses;         // FAUNA layer 9 (SCENT_FLORA_GRASSES)
    int f_scent_shrubs;          // FAUNA layer 10 (SCENT_FLORA_SHRUBS)
    int f_scent_trees;           // FAUNA layer 11 (SCENT_FLORA_TREES)
    int f_ground_temp;           // LANDSCAPE layer 4 (GROUND_TEMP)
    int f_air_temp;              // ATMOSPHERE layer 2 (AIR_TEMP)
    int f_humidity;              // ATMOSPHERE layer 3 (HUMIDITY)
    int f_sunlight;              // ENERGY layer 0 (SUNLIGHT)
    int f_liquid_height;         // WATER layer 0 (WATER_LIQUID_HEIGHT)
    int f_ice_height;            // WATER layer 1 (WATER_ICE_HEIGHT)

    int a_grasses;               // FLORA atomic layer 0 (GRASSES)
    int a_shrubs;                // FLORA atomic layer 1 (SHRUBS)
    int a_trees_canopy;          // FLORA atomic layer 2 (TREES_CANOPY)
    int a_aquatic;               // FLORA atomic layer 3 (AQUATIC)
    int a_flora_detritus;        // FLORA atomic layer 4 (FLORA_DETRITUS)
    int a_soil_nutrients;        // LANDSCAPE atomic layer 1 (SOIL_NUTRIENTS)

    // --- USER PUSH CONSTANTS ---
    float flora_atomic_multiplier; // e.g. 1000000.0 (FLORA atomic layers)
    float atomic_multiplier;       // e.g. 100.0 (LANDSCAPE atomic layers, e.g. SOIL_NUTRIENTS)
    float base_growth_rate;        // e.g. 1.0
    float dieoff_rate;             // e.g. 0.2
    float decomposition_rate;      // e.g. 0.1
    vec2 succ_grass_to_shrub;      // (min_grass, max_grass)
    vec2 succ_shrub_to_tree;       // (min_shrub, max_shrub)
    vec2 shrub_competition;        // (shrub_start, shrub_max_penalty)
    vec2 tree_competition;         // (tree_start, tree_max_penalty)
} params;

// === BRANCHLESS SPHERICAL COORDINATE WRAPPING ===
ivec2 polar_wrap(ivec2 pos, ivec2 size, out float sign_flip) {
    int W = size.x;
    int H = size.y;
    int H2 = 2 * H; // Full Great Circle circumference (360° latitude loop)
    
    // 1. Map Y into [0, 2H - 1] via GLSL modulo
    int y_mod = ((pos.y % H2) + H2) % H2;
    
    // 2. Back hemisphere flag: 0 if front hemisphere (Y in 0..H-1), 1 if back hemisphere (Y in H..2H-1)
    int back = y_mod / H; 
    
    // 3. Mirror Y back into [0, H-1] if on the back hemisphere
    int y_final = (1 - back) * y_mod + back * (H2 - 1 - y_mod);
    
    // 4. Offset X by 180° (+W/2) if on the back hemisphere, then wrap X continuously into [0, W-1]
    int x_final = ((pos.x + back * (W / 2)) % W + W) % W;
    
    // 5. Calculate vector directional sign flip (+1.0 for front hemisphere, -1.0 for back hemisphere)
    sign_flip = 1.0 - 2.0 * float(back);
    
    return ivec2(x_final, y_final);
}

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(read_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // 1. Fetch Environment States (Read from read_tex)
    float ground_temp = imageLoad(read_tex, ivec3(id, params.f_ground_temp)).r;
    float air_temp = imageLoad(read_tex, ivec3(id, params.f_air_temp)).r;
    float humidity = imageLoad(read_tex, ivec3(id, params.f_humidity)).r;
    float sunlight = imageLoad(read_tex, ivec3(id, params.f_sunlight)).r;
    float liquid = imageLoad(read_tex, ivec3(id, params.f_liquid_height)).r;
    float ice = imageLoad(read_tex, ivec3(id, params.f_ice_height)).r;

    // 2. Fetch Atomic Resources (Read from atomic_tex)
    uint u_grasses = imageLoad(atomic_tex, ivec3(id, params.a_grasses)).r;
    uint u_shrubs = imageLoad(atomic_tex, ivec3(id, params.a_shrubs)).r;
    uint u_trees = imageLoad(atomic_tex, ivec3(id, params.a_trees_canopy)).r;
    uint u_aquatic = imageLoad(atomic_tex, ivec3(id, params.a_aquatic)).r;
    uint u_detritus = imageLoad(atomic_tex, ivec3(id, params.a_flora_detritus)).r;
    uint u_nutrients = imageLoad(atomic_tex, ivec3(id, params.a_soil_nutrients)).r;

    float grasses = float(u_grasses) / params.flora_atomic_multiplier;
    float shrubs = float(u_shrubs) / params.flora_atomic_multiplier;
    float trees = float(u_trees) / params.flora_atomic_multiplier;
    float aquatic = float(u_aquatic) / params.flora_atomic_multiplier;
    float detritus = float(u_detritus) / params.flora_atomic_multiplier;
    float nutrients = float(u_nutrients) / params.atomic_multiplier;

    // 3. Seed Sampling (Neighbor Sampling using polar_wrap)
    float flip;
    ivec2 n_pos;

    n_pos = polar_wrap(id + ivec2(1, 0), size, flip);
    uint n_g1 = imageLoad(atomic_tex, ivec3(n_pos, params.a_grasses)).r;
    uint n_s1 = imageLoad(atomic_tex, ivec3(n_pos, params.a_shrubs)).r;
    uint n_t1 = imageLoad(atomic_tex, ivec3(n_pos, params.a_trees_canopy)).r;

    n_pos = polar_wrap(id + ivec2(-1, 0), size, flip);
    uint n_g2 = imageLoad(atomic_tex, ivec3(n_pos, params.a_grasses)).r;
    uint n_s2 = imageLoad(atomic_tex, ivec3(n_pos, params.a_shrubs)).r;
    uint n_t2 = imageLoad(atomic_tex, ivec3(n_pos, params.a_trees_canopy)).r;

    n_pos = polar_wrap(id + ivec2(0, 1), size, flip);
    uint n_g3 = imageLoad(atomic_tex, ivec3(n_pos, params.a_grasses)).r;
    uint n_s3 = imageLoad(atomic_tex, ivec3(n_pos, params.a_shrubs)).r;
    uint n_t3 = imageLoad(atomic_tex, ivec3(n_pos, params.a_trees_canopy)).r;

    n_pos = polar_wrap(id + ivec2(0, -1), size, flip);
    uint n_g4 = imageLoad(atomic_tex, ivec3(n_pos, params.a_grasses)).r;
    uint n_s4 = imageLoad(atomic_tex, ivec3(n_pos, params.a_shrubs)).r;
    uint n_t4 = imageLoad(atomic_tex, ivec3(n_pos, params.a_trees_canopy)).r;

    float neighbor_grass = (float(n_g1) + float(n_g2) + float(n_g3) + float(n_g4)) / params.flora_atomic_multiplier;
    float neighbor_shrub = (float(n_s1) + float(n_s2) + float(n_s3) + float(n_s4)) / params.flora_atomic_multiplier;
    float neighbor_tree  = (float(n_t1) + float(n_t2) + float(n_t3) + float(n_t4)) / params.flora_atomic_multiplier;

    // 4. Environmental Suitability Calculations
    float temp = mix(ground_temp, air_temp, 0.5);

    // Temperature Factor: Smooth curve centered around 22°C
    float temp_norm = (temp - 22.0) / 22.0;
    float temp_factor = clamp(1.0 - temp_norm * temp_norm, 0.0, 1.0) * step(0.0, temp);

    // Sunlight Factor (reduced under ice)
    float effective_sunlight = sunlight * clamp(1.0 - ice * 10.0, 0.0, 1.0);

    // Terrestrial Moisture Factor
    float soil_moisture = max(liquid, humidity);
    float terrestrial_moisture = clamp(0.5 + soil_moisture * 2.0, 0.5, 1.0) * clamp(2.0 - liquid / 0.3, 0.0, 1.0);

    // Aquatic Moisture Factor
    float aquatic_moisture = clamp((liquid - 0.02) / 0.2, 0.0, 1.0);

    // Soil Nutrient Factor
    float nutrient_factor = 0.5 + clamp(nutrients / 5.0, 0.0, 1.0);

    // Compute Overall Growth Rate Modifier for Terrestrial Flora [0.0, 1.0]
    float growth_modifier = clamp(temp_factor * effective_sunlight * terrestrial_moisture * nutrient_factor, 0.0, 1.0);

    // Compute Canopy Shade Float [0.0, 0.95] from tree density
    // tree density is normalized around 1.0 (1,000,000 uints)
    float canopy_shade = clamp(trees * 0.95, 0.0, 0.95);

    // Effective sunlight hitting understory flora (grasses & shrubs) after canopy shading
    // Note: We use dynamic tree_competition for growth now, but we retain canopy_shade for thermodynamic topology drag
    float understory_growth_mod = growth_modifier;

    // 5. Succession & Logistic Growth Calculations
    const float SEED_THRESHOLD = 0.005;
    float dt = params.deltaTime;

    // Competition multipliers
    // Shrub competition penalizes grass (1.0 -> dynamic max penalty)
    float grass_from_shrub_mult = mix(1.0, 1.0 - params.shrub_competition.y, smoothstep(params.shrub_competition.x, params.shrub_competition.x + 0.5, shrubs));
    
    // Tree competition penalizes both understory layers (1.0 -> dynamic max penalty)
    float understory_from_tree_mult = mix(1.0, 1.0 - params.tree_competition.y, smoothstep(params.tree_competition.x, params.tree_competition.x + 0.5, trees));

    // Combine penalties and apply directly to Carrying Capacity (K) 
    // This forces shaded flora to die off (dieoff exceeds growth) down to the new lower capacity
    float grass_K_mult = grass_from_shrub_mult * understory_from_tree_mult;
    float shrub_K_mult = understory_from_tree_mult;

    // Carrying Capacities (K)
    float K_grass = understory_growth_mod * 1.0 * grass_K_mult; // Max out at 1.0 (1M uints)
    float K_shrub = understory_growth_mod * 3.0 * shrub_K_mult;
    float K_tree = growth_modifier * 5.0; 
    float K_aquatic = temp_factor * effective_sunlight * aquatic_moisture * nutrient_factor * 2.0;

    // Succession multipliers (enable growth of next stage)
    // Once established (>0.1), they bypass the predecessor requirement to sustain themselves
    float shrub_succession_mult = clamp(
        smoothstep(params.succ_grass_to_shrub.x, params.succ_grass_to_shrub.y, grasses) + 
        smoothstep(0.0, 0.1, shrubs), 0.0, 1.0);
        
    float tree_succession_mult = clamp(
        smoothstep(params.succ_shrub_to_tree.x, params.succ_shrub_to_tree.y, shrubs) + 
        smoothstep(0.0, 0.1, trees), 0.0, 1.0);

    // To ensure the affected species actively recede when shaded, we multiply their dieoff rate
    // inversely by the remaining carrying capacity multiplier
    float grass_dieoff_penalty = 1.0 / max(grass_K_mult, 0.1);
    float shrub_dieoff_penalty = 1.0 / max(shrub_K_mult, 0.1);

    // --- Grasses (Terrestrial Pioneer) ---
    bool can_grass_grow = (grasses > 0.0) || (neighbor_grass > SEED_THRESHOLD);
    float grass_growth = 0.0;
    if (can_grass_grow && K_grass > 0.001) {
        float N_g = max(grasses, 0.005);
        float r_g = params.base_growth_rate * understory_growth_mod;
        grass_growth = r_g * N_g * max(1.0 - (grasses / K_grass), 0.0) * dt;
    }
    float grass_dieoff = grasses * (step(0.4, liquid) + step(temp, -2.0) * 0.5 + (1.0 - temp_factor) * 0.1) * params.dieoff_rate * grass_dieoff_penalty * dt;

    // --- Shrubs ---
    bool can_shrub_grow = (shrubs > 0.0) || (grasses > params.succ_grass_to_shrub.x) || (neighbor_shrub > SEED_THRESHOLD);
    float shrub_growth = 0.0;
    if (can_shrub_grow && K_shrub > 0.001) {
        float N_s = max(shrubs, 0.005);
        float r_s = params.base_growth_rate * 0.5 * understory_growth_mod * shrub_succession_mult;
        shrub_growth = r_s * N_s * max(1.0 - (shrubs / K_shrub), 0.0) * dt;
    }
    float shrub_dieoff = shrubs * (step(0.4, liquid) + step(temp, -5.0) * 0.5 + (1.0 - temp_factor) * 0.1) * params.dieoff_rate * shrub_dieoff_penalty * dt;

    // --- Trees Canopy ---
    bool can_tree_grow = (trees > 0.0) || (shrubs > params.succ_shrub_to_tree.x) || (neighbor_tree > SEED_THRESHOLD);
    float tree_growth = 0.0;
    if (can_tree_grow && K_tree > 0.001) {
        float N_t = max(trees, 0.005);
        float r_t = params.base_growth_rate * 0.2 * growth_modifier * tree_succession_mult;
        tree_growth = r_t * N_t * max(1.0 - (trees / K_tree), 0.0) * dt;
    }
    float tree_dieoff = trees * (step(0.5, liquid) + step(temp, -10.0) * 0.5 + (1.0 - temp_factor) * 0.05) * params.dieoff_rate * dt;

    // --- Aquatic Flora ---
    bool can_aquatic_grow = (aquatic > 0.0) || (aquatic_moisture > 0.1);
    float aquatic_growth = 0.0;
    if (can_aquatic_grow && K_aquatic > 0.001) {
        float N_a = max(aquatic, 0.005);
        // NOTE: K_aquatic already computes (temp_factor * effective_sunlight * aquatic_moisture * nutrient_factor * 2.0),
        //       so we reuse it here rather than recalculating the product.
        float r_a = params.base_growth_rate * (K_aquatic * 0.5);
        aquatic_growth = r_a * N_a * max(1.0 - (aquatic / K_aquatic), 0.0) * dt;
    }
    float aquatic_dieoff = aquatic * (step(liquid, 0.01) + step(temp, -2.0) * 0.5) * params.dieoff_rate * dt;

    // --- Nutrient Consumption & Detritus Production ---
    float total_growth = grass_growth + shrub_growth + tree_growth + aquatic_growth;
    float total_dieoff = grass_dieoff + shrub_dieoff + tree_dieoff + aquatic_dieoff;

    float nutrient_consumed = min(nutrients, total_growth * 0.1);

    // Detritus Decomposition into Soil Nutrients
    float decomp_factor = temp_factor * clamp(liquid + 0.1, 0.1, 1.0);
    float detritus_decomposed = min(detritus, detritus * decomp_factor * params.decomposition_rate * dt);

    // 6. Atomic Transactions
    int d_grass = int(round((grass_growth - grass_dieoff) * params.flora_atomic_multiplier));
    int d_shrubs = int(round((shrub_growth - shrub_dieoff) * params.flora_atomic_multiplier));
    int d_trees = int(round((tree_growth - tree_dieoff) * params.flora_atomic_multiplier));
    int d_aquatic = int(round((aquatic_growth - aquatic_dieoff) * params.flora_atomic_multiplier));
    int d_detritus = int(round((total_dieoff - detritus_decomposed) * params.flora_atomic_multiplier));
    int d_nutrients = int(round((detritus_decomposed - nutrient_consumed) * params.atomic_multiplier));

    if (d_grass < 0) d_grass = -int(min(uint(-d_grass), u_grasses));
    if (d_grass != 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_grasses), uint(d_grass));

    if (d_shrubs < 0) d_shrubs = -int(min(uint(-d_shrubs), u_shrubs));
    if (d_shrubs != 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_shrubs), uint(d_shrubs));

    if (d_trees < 0) d_trees = -int(min(uint(-d_trees), u_trees));
    if (d_trees != 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_trees_canopy), uint(d_trees));

    if (d_aquatic < 0) d_aquatic = -int(min(uint(-d_aquatic), u_aquatic));
    if (d_aquatic != 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_aquatic), uint(d_aquatic));

    if (d_detritus < 0) d_detritus = -int(min(uint(-d_detritus), u_detritus));
    if (d_detritus != 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_flora_detritus), uint(d_detritus));

    if (d_nutrients < 0) d_nutrients = -int(min(uint(-d_nutrients), u_nutrients));
    if (d_nutrients != 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_soil_nutrients), uint(d_nutrients));

    // 7. Write Float Grid Outputs (to write_tex, Binding 0)
    imageStore(write_tex, ivec3(id, params.f_growth_rate_modifier), vec4(growth_modifier, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_canopy_shade), vec4(canopy_shade, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_scent_grasses), vec4(clamp(grasses, 0.0, 1.0), 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_scent_shrubs), vec4(clamp(shrubs, 0.0, 1.0), 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_scent_trees), vec4(clamp(trees, 0.0, 1.0), 0.0, 0.0, 0.0));
}