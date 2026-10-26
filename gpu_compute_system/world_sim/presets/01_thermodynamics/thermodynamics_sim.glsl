#[compute]
#version 450

// Group size of 8x8 threads.
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
    // required_layers order: LANDSCAPE (0), WATER (1), ATMOSPHERE (3), ENERGY (2)
    // Write buffers (the ones we calculate and update)
    int f_ground_temp;    // LANDSCAPE layer 4
    int f_water_temp;     // WATER layer 6
    int f_air_temp;       // ATMOSPHERE layer 2
    int f_ice_height;     // WATER layer 1 (mass changes via melt/freeze)
    int f_liquid_height;  // WATER layer 0 (mass changes via melt/freeze)

    // Read buffers (the ones we only sample for context)
    int f_bedrock_height; // LANDSCAPE layer 0
    int f_sediment_height;// LANDSCAPE layer 3
    int f_sunlight;       // ENERGY layer 0
    int f_humidity;       // ATMOSPHERE layer 3
    int f_canopy_shade;   // FLORA layer 1
    int f_rain;           // ATMOSPHERE layer 4 (RAIN -- read-only from read_tex binding 1)

    // --- USER PUSH CONSTANTS ---
    int a_atomic_liquid;       // Index for LIQUID_VOLUME in atomic grid
    int a_atomic_ice;          // Index for ICE_VOLUME in atomic grid
    int a_atomic_geothermal;   // Index for GEOTHERMAL in atomic grid
    int a_spell_geothermal;    // Index for SPELL_GEOTHERMAL in atomic grid (PLAYER_ACTIONS)
    int a_grasses;            // FLORA atomic layer 0 (GRASSES)
    int a_shrubs;             // FLORA atomic layer 1 (SHRUBS)
    int a_trees_canopy;       // FLORA atomic layer 2 (TREES_CANOPY)
    float atomic_multiplier;       // For converting uint to float (e.g. 100.0)
    float flora_atomic_multiplier; // For converting uint to float (e.g. 1000000.0)
    float heat_transfer_rate;    // Vertical heat exchange (e.g. 0.05)
    float thermal_diffusion_rate;// Horizontal heat exchange (e.g. 0.5)
    float latent_heat_capacity;  // Energy needed to change phase (e.g. 10.0)
    float thermal_ice_influence; // Base ice mass for full insulation (e.g. 0.05)
    float solar_heating_rate;    // Rate at which sunlight heats ground/water (e.g. 2.0 — increased from 0.01 for radiative balance)
    float geothermal_heating_rate;// Rate at which geothermal flux heats ground (e.g. 0.01)
    float ground_to_air_convection; // Ground→air convection strength (e.g. 0.5 — stronger coupling than old implicit 0.1)
    float emissivity;           // Stefan-Boltzmann emissivity [0, 1] (e.g. 0.7)
    float stefan_scale;         // Scaled Stefan-Boltzmann constant (e.g. 2.0e-7)
    float T_space;              // Effective space temperature in Kelvin (e.g. 3.0)
} params;

// The minimum representable precision cutoff for thermal diffusion to prevent subnormal float creep.
// 0.01°C is chosen because R16F precision breaks down around this scale at typical temperatures (e.g. ~10°C to 20°C).
// Furthermore, macroscopic ecology doesn't care about temperature differences smaller than 1/100th of a degree,
// so aggressively culling microscopic transfers here saves GPU cycles and lets the thermal simulation settle.
const float MINIMUM_EP = 0.01;
const float PI = 3.14159265359;

// Number of sub-steps for thermal diffusion (CFL stability at variable deltaTime).
// With 4 sub-steps, effective diff_k per step is 4× smaller, preventing instability.
const int THERMAL_SUBSTEPS = 4;

// [THERMAL RADIATION / GREENHOUSE STEP 2] Fraction of solar radiation absorbed directly by the air.
// Increased from 0.15 -> 0.40 to allow noticeable diurnal swings as the sun sweeps across the planet.
const float AIR_SOLAR_ABSORPTION = 0.40;

// [THERMAL RADIATION / GREENHOUSE STEP 3] Air radiates a fraction as much as ground (thinner column).
// Increased from 0.30 -> 0.70 so thin air radiates rapidly to space on the night side.
const float AIR_RADIATION_FRACTION = 0.70;

// [RAIN LATENT HEAT STEP 3] Latent heat released per unit of precipitation intensity, warming the air.
// Condensation is exothermic: vapor -> rain releases sensible thermal energy into the column.
const float RAIN_LATENT_HEAT = 8.0;

// [THERMAL RADIATION / GREENHOUSE STEP 3] Greenhouse factor: humidity-dependent radiation retention.
// Dry air retains GREENHOUSE_BASE of outgoing radiation; water vapor adds up to GREENHOUSE_HUMIDITY_FACTOR more.
// At humidity=0 → 0.40, at humidity=1.0 → 0.80. Clamped to 0.95 so some radiation always escapes to space.
// This is what makes humid areas (oceans/tropics) cool slower at night than dry areas (deserts).
const float GREENHOUSE_BASE = 0.40;
const float GREENHOUSE_HUMIDITY_FACTOR = 0.40;

// [THERMAL RADIATION / GREENHOUSE STEP 4] Fraction of greenhouse-absorbed ground radiation that heats the air.
// Of the radiation absorbed by the atmosphere (greenhouse fraction), this much warms the air directly; the
// remainder is re-radiated (handled implicitly via the air→space block in Step 3). This is the primary warming
// mechanism for air and the key driver of the desert-vs-ocean ground-air gap: humid air (high greenhouse)
// absorbs more ground radiation → smaller ground-air gap; dry air (low greenhouse) → larger gap.
// Tuned from 0.50 → 0.30: at 0.50 air was slightly warmer than ground (back-radiation over-warmed air
// relative to its weak air→space cooling sink). 0.30 keeps ground warmer than air as intended.
const float BACK_RADIATION_FACTOR = 0.30;

// [THERMAL RADIATION / GREENHOUSE STEP 5] Cloud albedo: humidity-driven solar reflection (saturating curve).
// Replaces the old linear `cloud_attenuation = clamp(1 - humidity * 0.75, 0.1, 1.0)` which was a crude hard clamp.
// Cloud albedo in reality saturates — the first bit of humidity (thin clouds) blocks most sunlight, and
// adding more humidity (thicker clouds) yields diminishing returns. This is modeled with an exponential:
//   cloud_albedo = CLOUD_ALBEDO_MAX * (1 - exp(-humidity * CLOUD_ALBEDO_RATE))
// CLOUD_ALBEDO_MAX = 0.35 → max 35% of sunlight reflected (Earth avg albedo ~0.3). CLOUD_ALBEDO_RATE = 4.0
// → albedo saturates fast (humidity=0.5 already reflects ~28%). Net effect: deserts (low humidity) get full
// sun, oceans (high humidity) get ~35% less — making deserts hotter than oceans at the same latitude.
const float CLOUD_ALBEDO_MAX  = 0.35;
const float CLOUD_ALBEDO_RATE = 4.0;

// Relative volumetric heat capacities (thermal mass per unit area, dimensionless).
// Air ≈ 1.0 (reference, small thermal inertia), Ground ≈ 50.0 (rock/soil).
// Higher C -> smaller dT -> stays closer to its own current temperature.
const float HEAT_CAPACITY_GROUND = 50.0;
const float HEAT_CAPACITY_AIR    = 1.0;

// === BRANCHLESS SPHERICAL COORDINATE WRAPPING ===
// Handles continuous 360° cylindrical X-wrapping and 180° polar Y-crossover.
// Zero branching (no 'if' statements) to prevent warp divergence in GPU execution.
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

    // Latitude & row convergence factor
    // Model B (cell-centered): poles reside on outer texture boundary edges (y = -0.5, y = size.y - 0.5)
    float norm_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * PI;
    float cos_lat = max(cos(latitude), 0.05);

    float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
    float polar_dampen = smoothstep(0.0, 10.0, dist_from_pole);

    // Neighbor coordinates and values (shared by diffusion + polar damping)
    ivec2 n_id, s_id, e_id, w_id;
    float n_gt, s_gt, e_gt, w_gt;
    float n_at, s_at, e_at, w_at;

    // 1. Fetch current cell states (Read from read_tex!)
    float liquid = imageLoad(read_tex, ivec3(id, params.f_liquid_height)).r;
    float ice = imageLoad(read_tex, ivec3(id, params.f_ice_height)).r;
    float water_temp = imageLoad(read_tex, ivec3(id, params.f_water_temp)).r;
    float air_temp = imageLoad(read_tex, ivec3(id, params.f_air_temp)).r;
    float ground_temp = imageLoad(read_tex, ivec3(id, params.f_ground_temp)).r;
    float sunlight = imageLoad(read_tex, ivec3(id, params.f_sunlight)).r;
    float humidity = imageLoad(read_tex, ivec3(id, params.f_humidity)).r;
    float canopy_shade = imageLoad(read_tex, ivec3(id, params.f_canopy_shade)).r;
    
    float water_mass = liquid + ice;

    uint u_grasses = imageLoad(atomic_tex, ivec3(id, params.a_grasses)).r;
    uint u_shrubs = imageLoad(atomic_tex, ivec3(id, params.a_shrubs)).r;
    uint u_trees = imageLoad(atomic_tex, ivec3(id, params.a_trees_canopy)).r;
    float total_local_biomass = (float(u_grasses) + float(u_shrubs) + float(u_trees)) / params.flora_atomic_multiplier;

    // --- 2. SOLAR & GEOTHERMAL HEATING + RADIATIVE COOLING ---
    // Geothermal = natural baseline (ENERGY.GEOTHERMAL, WorldGen-seeded) + spell sources
    // (PLAYER_ACTIONS.SPELL_GEOTHERMAL, managed by spell_effects_sim as a presence ->
    // source mirror). Summing keeps natural vents untouched while player vents heat via
    // the same rate; dispelling zeroes the spell half automatically next frame.
    uint geo_uint = imageLoad(atomic_tex, ivec3(id, params.a_atomic_geothermal)).r;
    uint spell_geo_uint = imageLoad(atomic_tex, ivec3(id, params.a_spell_geothermal)).r;
    float geothermal = (float(geo_uint) + float(spell_geo_uint)) / params.atomic_multiplier;

    // Attenuate sunlight by cloud albedo (humidity-driven, saturating) and canopy shade.
    // [THERMAL RADIATION / GREENHOUSE STEP 5] Replaced the linear `cloud_attenuation` clamp with a saturating
    // exponential albedo curve: thin clouds (low humidity) already block most sunlight, thicker clouds add
    // diminishing returns. This makes deserts (low humidity) hotter than oceans (high humidity) at the same
    // latitude — the key diagnostic for Step 5.
    float cloud_albedo = CLOUD_ALBEDO_MAX * (1.0 - exp(-humidity * CLOUD_ALBEDO_RATE));
    float shade_attenuation = clamp(1.0 - canopy_shade, 0.05, 1.0);
    float effective_sunlight = sunlight * (1.0 - cloud_albedo) * shade_attenuation;

    // Sunlight and geothermal heat GROUND temperature (full rate), and AIR temperature (AIR_SOLAR_ABSORPTION fraction).
    // [THERMAL RADIATION / GREENHOUSE STEP 2] Direct solar→air heating restored at 15% absorption.
    // Real atmosphere absorbs ~20% of incoming solar directly; the rest heats the ground, which heats air via convection.
    ground_temp += (effective_sunlight * params.solar_heating_rate + geothermal * params.geothermal_heating_rate) * params.deltaTime;
    air_temp += effective_sunlight * params.solar_heating_rate * AIR_SOLAR_ABSORPTION * params.deltaTime;

    // [THERMAL RADIATION / GREENHOUSE STEP 3] Shared terms for ground + air radiative cooling.
    // T_space4 is hoisted to shared scope so both the ground and air radiation blocks can reuse it
    // (it is a uniform-derived constant, independent of the cell). The greenhouse factor is computed
    // here (before the ground block) so Step 4's back-radiation split can reference it without rework.
    float T_space4 = params.T_space * params.T_space * params.T_space * params.T_space;
    float greenhouse = clamp(GREENHOUSE_BASE + humidity * GREENHOUSE_HUMIDITY_FACTOR, 0.0, 0.95);

    // [PHASE 0.1 / THERMAL RADIATION STEP 4] Stefan-Boltzmann radiative cooling, split by greenhouse.
    // Ground radiates as T^4; the greenhouse factor determines how much escapes to space vs is absorbed
    // by the atmosphere. The absorbed fraction (rad_to_air) warms the air directly (back-radiation) — this
    // is the primary air-warming mechanism and the key humidity-dependent ground-air gap driver.
    // P_rad = ε * σ_scale * (T^4 - T_space^4) * dt; T converted to Kelvin for physical correctness.
    {
        float T_kelvin = ground_temp + 273.15;
        float T4 = T_kelvin * T_kelvin * T_kelvin * T_kelvin;
        float total_rad = params.emissivity * params.stefan_scale * (T4 - T_space4) * params.deltaTime;

        // Greenhouse splits radiation: (1 - greenhouse) escapes to space, greenhouse * BACK_RADIATION_FACTOR
        // is absorbed by the atmosphere and heats the air. The remainder of the absorbed fraction is
        // re-radiated (handled implicitly by the air→space block below, which already reduces cooling by
        // (1 - greenhouse * 0.5)).
        float rad_to_space = total_rad * (1.0 - greenhouse);
        float rad_to_air   = total_rad * greenhouse * BACK_RADIATION_FACTOR;

        ground_temp -= rad_to_space + rad_to_air;  // ground loses both fractions
        air_temp    += rad_to_air;                  // air gains the greenhouse-absorbed fraction
    }

    // [THERMAL RADIATION / GREENHOUSE STEP 3] Air → Space radiative cooling, reduced by greenhouse.
    // This is the missing heat sink for air: without it, air accumulates solar + convective heat and
    // ends up hotter than ground (it had no exit except slow diffusion). The greenhouse factor models
    // how much of the atmosphere's own outgoing radiation is re-absorbed, so humid air (high greenhouse)
    // cools slower than dry air — the key day/night diagnostic for AIR_TEMP.
    {
        float T_air_K = air_temp + 273.15;
        float T_air4 = T_air_K * T_air_K * T_air_K * T_air_K;
        float air_rad_loss = params.emissivity * params.stefan_scale * (T_air4 - T_space4)
                           * AIR_RADIATION_FRACTION * (1.0 - greenhouse * 0.5) * params.deltaTime;
        air_temp -= air_rad_loss;
    }

    // [RAIN LATENT HEAT STEP 3] Rain latent heat: condensation in the column warms the air.
    // Reads RAIN from the previous frame (read_tex, binding 1).
    float rain = imageLoad(read_tex, ivec3(id, params.f_rain)).r;
    air_temp += rain * RAIN_LATENT_HEAT * params.deltaTime;

    // --- 3. NEIGHBOR READS (shared by diffusion and polar damping) ---
    // Read neighbors once — used by both thermal diffusion sub-steps and pole scalar uniformity.
    {
        float s_flip;
        n_id = polar_wrap(id + ivec2(0, -1), size, s_flip);
        s_id = polar_wrap(id + ivec2(0,  1), size, s_flip);
        e_id = polar_wrap(id + ivec2(1,  0), size, s_flip);
        w_id = polar_wrap(id + ivec2(-1,  0), size, s_flip);

        n_gt = imageLoad(read_tex, ivec3(n_id, params.f_ground_temp)).r;
        s_gt = imageLoad(read_tex, ivec3(s_id, params.f_ground_temp)).r;
        e_gt = imageLoad(read_tex, ivec3(e_id, params.f_ground_temp)).r;
        w_gt = imageLoad(read_tex, ivec3(w_id, params.f_ground_temp)).r;

        n_at = imageLoad(read_tex, ivec3(n_id, params.f_air_temp)).r;
        s_at = imageLoad(read_tex, ivec3(s_id, params.f_air_temp)).r;
        e_at = imageLoad(read_tex, ivec3(e_id, params.f_air_temp)).r;
        w_at = imageLoad(read_tex, ivec3(w_id, params.f_air_temp)).r;
    }

    // --- 4. THERMAL DIFFUSION (SUB-STEPPED) ---
    // [PHASE 0.4] Thermal diffusion is now sub-stepped for CFL stability at variable deltaTime.
    // With THERMAL_SUBSTEPS=4, each step uses dt/4, keeping diff_k well below 0.25.
    {
        float sub_dt = params.deltaTime / float(THERMAL_SUBSTEPS);
        float diff_k = min(params.thermal_diffusion_rate * sub_dt, 0.25);

        for (int s = 0; s < THERMAL_SUBSTEPS; s++) {
            // Ground temperature diffusion
            float gt_diff = (n_gt - ground_temp) + (s_gt - ground_temp) + cos_lat * ((e_gt - ground_temp) + (w_gt - ground_temp));
            gt_diff = floor(gt_diff / MINIMUM_EP) * MINIMUM_EP;
            ground_temp += diff_k * gt_diff;

            // Air temperature diffusion
            float at_diff = (n_at - air_temp) + (s_at - air_temp) + cos_lat * ((e_at - air_temp) + (w_at - air_temp));
            at_diff = floor(at_diff / MINIMUM_EP) * MINIMUM_EP;
            air_temp += diff_k * at_diff;
        }
    }

    // --- 4. LOCAL HEAT TRANSFER (Heat-Capacity Weighted Convection) ---
    // Ground has ~50× the volumetric heat capacity of surface air.
    // Sensible heat flux is proportional to the ground-air temperature difference.
    // Ground barely shifts (C = 50.0) while thin air shifts toward ground (C = 1.0).
    float has_water = step(0.001, water_mass);
    
    // Insulation factor derived from plant biomass reduces heat exchange rate
    float insulation_factor_bio = 1.0 / (1.0 + total_local_biomass * 0.5);
    float effective_heat_transfer = params.heat_transfer_rate * insulation_factor_bio;

    // Exponential decay equivalent for stable integration
    float local_transfer = 1.0 - exp(-effective_heat_transfer * params.deltaTime);

    // Calculate the target equilibrium temperature for water cells based on thermal mass.
    // Water has immensely higher thermal capacity than air or ground surface.
    // If water exists, it dominates the equilibrium.
    float target_temp_water = (ground_temp * 0.1 + air_temp * 0.1 + water_temp * 0.8);

    // Heat flux exchanged between ground and air (proportional to temperature difference)
    float g2a = params.ground_to_air_convection;
    float heat_flux = g2a * (ground_temp - air_temp) * local_transfer;

    // Ground barely shifts due to large heat capacity (C = 50.0)
    float gt_land = ground_temp - heat_flux / HEAT_CAPACITY_GROUND;

    // Air shifts toward ground due to small heat capacity (C = 1.0)
    float at_land = air_temp    + heat_flux / HEAT_CAPACITY_AIR;

    // Water exchange paths remain unchanged (water's thermal inertia is already encoded in target_temp_water)
    float wt_water = mix(water_temp, target_temp_water, local_transfer);
    float gt_water = mix(ground_temp, target_temp_water, local_transfer);
    float at_water = mix(air_temp, target_temp_water, local_transfer);

    // Branchless application based on whether water is present
    water_temp = mix(water_temp, wt_water, has_water);
    ground_temp = mix(gt_land, gt_water, has_water);
    air_temp = mix(at_land, at_water, has_water);

    // --- 5. LATENT HEAT & PHASE CHANGE ---
    float insulation_factor = clamp(1.0 - (ice / max(params.thermal_ice_influence, 0.001)), 0.0, 1.0);

    float is_melting = step(0.0, water_temp) * step(0.001, ice);
    float is_freezing = step(0.0, -water_temp) * step(0.001, liquid);

    float desired_melt = (max(0.0, water_temp) / params.latent_heat_capacity) * params.deltaTime;
    float desired_freeze = (max(0.0, -water_temp) / params.latent_heat_capacity) * insulation_factor * params.deltaTime;

    float melt_mass = min(ice, desired_melt) * is_melting;
    float freeze_mass = min(liquid, desired_freeze) * is_freezing;

    // --- 7. ATOMIC GRID TRANSACTIONS ---
    // Only execute atomic operations if a change actually occurred
    uint atomic_melt = uint(melt_mass * params.atomic_multiplier);
    uint atomic_freeze = uint(freeze_mass * params.atomic_multiplier);
    
    float final_melt = 0.0;
    float final_freeze = 0.0;
    
    if (atomic_melt > 0) {
        // Fetch actual atomic value to ensure we don't underflow if float cache desynced
        uint current_ice = imageLoad(atomic_tex, ivec3(id, params.a_atomic_ice)).r;
        uint actual_melt = min(atomic_melt, current_ice);
        if (actual_melt > 0) {
            imageAtomicAdd(atomic_tex, ivec3(id, params.a_atomic_ice), uint(-int(actual_melt)));
            imageAtomicAdd(atomic_tex, ivec3(id, params.a_atomic_liquid), actual_melt);
            final_melt = float(actual_melt) / params.atomic_multiplier;
        }
    }
    
    if (atomic_freeze > 0) {
        uint current_liquid = imageLoad(atomic_tex, ivec3(id, params.a_atomic_liquid)).r;
        uint actual_freeze = min(atomic_freeze, current_liquid);
        if (actual_freeze > 0) {
            imageAtomicAdd(atomic_tex, ivec3(id, params.a_atomic_liquid), uint(-int(actual_freeze)));
            imageAtomicAdd(atomic_tex, ivec3(id, params.a_atomic_ice), actual_freeze);
            final_freeze = float(actual_freeze) / params.atomic_multiplier;
        }
    }

    float new_ice = ice + final_freeze - final_melt;
    float new_liquid = liquid + final_melt - final_freeze;

    // Update sensible heat (temperature) after phase change consumes/releases it.
    // If we had a massive temperature extreme but only a tiny bit of water to freeze/melt,
    // this perfectly refunds the leftover extreme temperature.
    water_temp += (final_freeze - final_melt) * params.latent_heat_capacity;
    
    // Clamp the temperature so it doesn't cross 0.0 strictly due to latent heat refund overshoots.
    // If it was melting (>0), it cannot fall below 0. If it was freezing (<0), it cannot rise above 0.
    water_temp = mix(water_temp, max(water_temp, 0.0), is_melting);
    water_temp = mix(water_temp, min(water_temp, 0.0), is_freezing);

    // --- 6. PHASE-LOCKING (ENTHALPY) ---
    // Strict lock: ONLY if substantial amounts of both liquid and ice exist simultaneously.
    // This prevents epsilon floating point noise from falsely locking the temperature to 0.0.
    float is_locked = step(0.01, new_ice) * step(0.01, new_liquid);
    water_temp = mix(water_temp, 0.0, is_locked);

    // Force scalar uniformity over the poles
    if (dist_from_pole < 5.0) {
        float ew_mix = 0.5 * params.deltaTime; // Smooth blur over time 
        ground_temp = mix(ground_temp, (e_gt + w_gt) * 0.5, ew_mix); 
        air_temp = mix(air_temp, (e_at + w_at) * 0.5, ew_mix);
        water_temp = mix(water_temp, (imageLoad(read_tex, ivec3(e_id, params.f_water_temp)).r + imageLoad(read_tex, ivec3(w_id, params.f_water_temp)).r) * 0.5, ew_mix);
    }

    // --- 8. WRITE OUT CACHED FLOATS ---
    imageStore(write_tex, ivec3(id, params.f_ground_temp), vec4(ground_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_water_temp), vec4(water_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_air_temp), vec4(air_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_liquid_height), vec4(new_liquid, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_ice_height), vec4(new_ice, 0.0, 0.0, 0.0));
}

