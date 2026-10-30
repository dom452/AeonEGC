#[compute]
#version 450

// =============================================================================
// THERMODYNAMICS SIMULATION
// Compute pass that simulates surface thermodynamics, radiative equilibrium, thermal diffusion, and ice phase changes.
// Physical units: Temperatures in °C (Kelvin for radiation), water and ice depths in hectometers (1.0 = 100 meters).
// Bindings: Reads climate from read_tex (Set 0, Binding 1);
//           Writes updated temperatures and water/ice depths to write_tex (Set 0, Binding 0);
//           Synchronizes liquid and ice volumes in atomic_tex (Set 0, Binding 2).
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

    // Output layer indices (updated in write_tex)
    int f_ground_temp;   // Index of ground temperature layer in float texture array
    int f_water_temp;    // Index of water temperature layer in float texture array
    int f_air_temp;      // Index of air temperature layer in float texture array
    int f_ice_height;    // Index of ice thickness layer in float texture array
    int f_liquid_height; // Index of liquid water depth layer in float texture array

    // Input layer indices (read from read_tex)
    int f_bedrock_height;  // Index of bedrock elevation layer in float texture array
    int f_sediment_height; // Index of sediment depth layer in float texture array
    int f_sunlight;        // Index of solar insolation layer in float texture array
    int f_humidity;        // Index of atmospheric humidity layer in float texture array
    int f_canopy_shade;    // Index of vegetation canopy shade layer in float texture array
    int f_rain;            // Index of rain precipitation rate layer in float texture array

    // Atomic storage layer indices
    int a_atomic_liquid;    // Index of liquid volume layer in atomic texture array
    int a_atomic_ice;       // Index of ice volume layer in atomic texture array
    int a_atomic_geothermal;// Index of natural geothermal heat layer in atomic texture array
    int a_spell_geothermal; // Index of player-created geothermal source layer in atomic texture array
    int a_grasses;          // Index of grass biomass layer in atomic texture array
    int a_shrubs;           // Index of shrub biomass layer in atomic texture array
    int a_trees_canopy;     // Index of tree canopy biomass layer in atomic texture array

    float atomic_multiplier;       // Scale factor converting physical float units to fixed-point uint
    float flora_atomic_multiplier; // Scale factor converting vegetation biomass to fixed-point uint
    float heat_transfer_rate;      // Vertical conductive heat exchange coefficient
    float thermal_diffusion_rate;  // Horizontal thermal diffusion rate
    float latent_heat_capacity;    // Thermal energy consumed/released per unit phase change
    float thermal_ice_influence;   // Ice thickness required for complete thermal insulation of water
    float solar_heating_rate;      // Rate of ground/water surface warming from absorbed solar insolation
    float geothermal_heating_rate; // Rate of ground warming from crustal geothermal heat flux
    float ground_to_air_convection;// Sensible heat convection rate from ground to surface air
    float emissivity;              // Stefan-Boltzmann surface thermal emissivity [0, 1]
    float stefan_scale;            // Scaled Stefan-Boltzmann constant
    float T_space;                 // Deep space radiative background sink temperature in Kelvin
} params;

// Minimum thermal precision cutoff to avoid subnormal floating-point drift and wasted compute
const float MINIMUM_EP = 0.01;
const float PI = 3.14159265359;

// Number of sub-steps for horizontal thermal diffusion to guarantee numerical CFL stability
const int THERMAL_SUBSTEPS = 4;

// Fraction of incident solar radiation absorbed directly by the atmospheric column
const float AIR_SOLAR_ABSORPTION = 0.40;

// Atmospheric radiative cooling factor relative to blackbody ground radiation
const float AIR_RADIATION_FRACTION = 0.70;

// Latent heat of condensation released into the column per unit of falling precipitation
const float RAIN_LATENT_HEAT = 8.0;

// Baseline longwave thermal radiation retention by the dry atmosphere
const float GREENHOUSE_BASE = 0.40;

// Additional greenhouse radiation trapping coefficient proportional to atmospheric humidity
const float GREENHOUSE_HUMIDITY_FACTOR = 0.40;

// Fraction of greenhouse-absorbed ground thermal radiation reradiated back downward to warm the air
const float BACK_RADIATION_FACTOR = 0.30;

// Maximum cloud solar reflectance (cloud albedo saturates with increasing moisture)
const float CLOUD_ALBEDO_MAX  = 0.35;
const float CLOUD_ALBEDO_RATE = 4.0;

// Relative volumetric thermal heat capacities: ground has high thermal inertia, thin air has low inertia
const float HEAT_CAPACITY_GROUND = 50.0;
const float HEAT_CAPACITY_AIR    = 1.0;

// === BRANCHLESS SPHERICAL COORDINATE WRAPPING ===
// Re-maps coordinates that step over texture edges into valid spherical grid positions.
// Horizontally, coordinates wrap seamlessly across 360° longitude.
// Vertically, overstepping a pole crosses into the antipodal longitude (offset by +W/2)
// and reflects latitude, preventing seam artifacts without branching.
ivec2 polar_wrap(ivec2 pos, ivec2 size, out float sign_flip) {
    int W = size.x;
    int H = size.y;
    int H2 = 2 * H; // Full great circle circumference (360° latitude loop)
    
    // Map Y into periodic coordinate space [0, 2H - 1]
    int y_mod = ((pos.y % H2) + H2) % H2;
    
    // Flag whether the coordinate passed over the pole onto the antipodal hemisphere
    int back = y_mod / H; 
    
    // Mirror Y back into primary grid range [0, H-1]
    int y_final = (1 - back) * y_mod + back * (H2 - 1 - y_mod);
    
    // Shift X by 180° longitude (+W/2) when traversing over a pole, then wrap to [0, W-1]
    int x_final = ((pos.x + back * (W / 2)) % W + W) % W;
    
    // Set vector inversion factor: +1.0 on front hemisphere, -1.0 across polar crossover
    sign_flip = 1.0 - 2.0 * float(back);
    
    return ivec2(x_final, y_final);
}

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(read_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Latitude and meridian convergence cosine factor
    float norm_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * PI;
    float cos_lat = max(cos(latitude), 0.05);

    // Distance to nearest pole for polar damping
    float dist_from_pole = min(float(id.y) + 0.5, float(size.y - 1 - id.y) + 0.5);
    float polar_dampen = smoothstep(0.0, 10.0, dist_from_pole);

    // Neighbor coordinates and values (shared between diffusion and polar smoothing)
    ivec2 n_id, s_id, e_id, w_id;
    float n_gt, s_gt, e_gt, w_gt;
    float n_at, s_at, e_at, w_at;

    // 1. Fetch current cell state from the read snapshot texture
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

    // 2. Solar and geothermal radiative heating
    // Total geothermal heat sums natural geological baseline and player-invoked thermal sources
    uint geo_uint = imageLoad(atomic_tex, ivec3(id, params.a_atomic_geothermal)).r;
    uint spell_geo_uint = imageLoad(atomic_tex, ivec3(id, params.a_spell_geothermal)).r;
    float geothermal = (float(geo_uint) + float(spell_geo_uint)) / params.atomic_multiplier;

    // Solar attenuation: clouds reflect a fraction of sunlight back into space, and canopy foliage intercepts light
    float cloud_albedo = CLOUD_ALBEDO_MAX * (1.0 - exp(-humidity * CLOUD_ALBEDO_RATE));
    float shade_attenuation = clamp(1.0 - canopy_shade, 0.05, 1.0);
    float effective_sunlight = sunlight * (1.0 - cloud_albedo) * shade_attenuation;

    // Sunlight and geothermal flux warm the ground; sunlight also warms the air column directly
    ground_temp += (effective_sunlight * params.solar_heating_rate + geothermal * params.geothermal_heating_rate) * params.deltaTime;
    air_temp += effective_sunlight * params.solar_heating_rate * AIR_SOLAR_ABSORPTION * params.deltaTime;

    // Radiative balance: compute space sink temperature to the 4th power and greenhouse trapping ratio
    float T_space4 = params.T_space * params.T_space * params.T_space * params.T_space;
    float greenhouse = clamp(GREENHOUSE_BASE + humidity * GREENHOUSE_HUMIDITY_FACTOR, 0.0, 0.95);

    // Stefan-Boltzmann longwave emission from ground surface:
    // P_rad = ε * σ * (T_ground^4 - T_space^4) * dt.
    // Greenhouse gases absorb part of this radiation, reradiating it downward to warm overlying air.
    {
        float T_kelvin = ground_temp + 273.15;
        float T4 = T_kelvin * T_kelvin * T_kelvin * T_kelvin;
        float total_rad = params.emissivity * params.stefan_scale * (T4 - T_space4) * params.deltaTime;

        float rad_to_space = total_rad * (1.0 - greenhouse);
        float rad_to_air   = total_rad * greenhouse * BACK_RADIATION_FACTOR;

        ground_temp -= rad_to_space + rad_to_air;
        air_temp    += rad_to_air;
    }

    // Atmospheric column emission to space: air radiates upward, partially trapped by its own greenhouse moisture
    {
        float T_air_K = air_temp + 273.15;
        float T_air4 = T_air_K * T_air_K * T_air_K * T_air_K;
        float air_rad_loss = params.emissivity * params.stefan_scale * (T_air4 - T_space4)
                           * AIR_RADIATION_FRACTION * (1.0 - greenhouse * 0.5) * params.deltaTime;
        air_temp -= air_rad_loss;
    }

    // Latent heat release from falling precipitation: water vapor condensing into rain releases heat
    float rain = imageLoad(read_tex, ivec3(id, params.f_rain)).r;
    air_temp += rain * RAIN_LATENT_HEAT * params.deltaTime;

    // 3. Read neighbor temperatures with spherical coordinate wrapping
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

    // 4. Multi-substep horizontal thermal diffusion across ground and atmosphere
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

    // 5. Vertical sensible heat convection and thermal capacity weighting:
    // Ground has high volumetric heat capacity (C = 50.0), air has low capacity (C = 1.0).
    // Convective flux transfers heat toward thermal equilibrium.
    float has_water = step(0.001, water_mass);
    
    // Plant biomass creates an insulating boundary layer that slows heat exchange
    float insulation_factor_bio = 1.0 / (1.0 + total_local_biomass * 0.5);
    float effective_heat_transfer = params.heat_transfer_rate * insulation_factor_bio;

    float local_transfer = 1.0 - exp(-effective_heat_transfer * params.deltaTime);

    // Water bodies have immense thermal inertia and dominate local thermal equilibrium
    float target_temp_water = (ground_temp * 0.1 + air_temp * 0.1 + water_temp * 0.8);

    // Convective heat flux between ground and air
    float g2a = params.ground_to_air_convection;
    float heat_flux = g2a * (ground_temp - air_temp) * local_transfer;

    // Ground temperature changes slowly; thin air temperature adjusts quickly
    float gt_land = ground_temp - heat_flux / HEAT_CAPACITY_GROUND;
    float at_land = air_temp    + heat_flux / HEAT_CAPACITY_AIR;

    float wt_water = mix(water_temp, target_temp_water, local_transfer);
    float gt_water = mix(ground_temp, target_temp_water, local_transfer);
    float at_water = mix(air_temp, target_temp_water, local_transfer);

    water_temp = mix(water_temp, wt_water, has_water);
    ground_temp = mix(gt_land, gt_water, has_water);
    air_temp = mix(at_land, at_water, has_water);

    // 6. Latent heat and phase changes between liquid water and ice sheets:
    // Growing ice sheets insulate underlying water, attenuating further freezing.
    float insulation_factor = clamp(1.0 - (ice / max(params.thermal_ice_influence, 0.001)), 0.0, 1.0);

    float is_melting = step(0.0, water_temp) * step(0.001, ice);
    float is_freezing = step(0.0, -water_temp) * step(0.001, liquid);

    float desired_melt = (max(0.0, water_temp) / params.latent_heat_capacity) * params.deltaTime;
    float desired_freeze = (max(0.0, -water_temp) / params.latent_heat_capacity) * insulation_factor * params.deltaTime;

    float melt_mass = min(ice, desired_melt) * is_melting;
    float freeze_mass = min(liquid, desired_freeze) * is_freezing;

    // 7. Synchronize phase changes in the atomic volume grid
    uint atomic_melt = uint(melt_mass * params.atomic_multiplier);
    uint atomic_freeze = uint(freeze_mass * params.atomic_multiplier);
    
    float final_melt = 0.0;
    float final_freeze = 0.0;
    
    if (atomic_melt > 0) {
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

    // Update sensible water temperature based on latent heat absorption or release
    water_temp += (final_freeze - final_melt) * params.latent_heat_capacity;
    
    // Clamp temperature to prevent overshoots past the 0°C melting/freezing threshold
    water_temp = mix(water_temp, max(water_temp, 0.0), is_melting);
    water_temp = mix(water_temp, min(water_temp, 0.0), is_freezing);

    // Enthalpy phase-locking: coexisting ice and liquid remain clamped to 0.0°C
    float is_locked = step(0.01, new_ice) * step(0.01, new_liquid);
    water_temp = mix(water_temp, 0.0, is_locked);

    // Polar blending: ensure scalar fields remain smooth across the polar coordinates
    if (dist_from_pole < 5.0) {
        float ew_mix = 0.5 * params.deltaTime;
        ground_temp = mix(ground_temp, (e_gt + w_gt) * 0.5, ew_mix); 
        air_temp = mix(air_temp, (e_at + w_at) * 0.5, ew_mix);
        water_temp = mix(water_temp, (imageLoad(read_tex, ivec3(e_id, params.f_water_temp)).r + imageLoad(read_tex, ivec3(w_id, params.f_water_temp)).r) * 0.5, ew_mix);
    }

    // 8. Store updated temperature and water depth layers in the float texture array
    imageStore(write_tex, ivec3(id, params.f_ground_temp), vec4(ground_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_water_temp), vec4(water_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_air_temp), vec4(air_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_liquid_height), vec4(new_liquid, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_ice_height), vec4(new_ice, 0.0, 0.0, 0.0));
}

