#[compute]
#version 450

// =============================================================================
// HYDRAULIC FLOW SIMULATION
// Compute pass that simulates surface water gravity flow, tidal sloshing, and nutrient/salinity transport.
// Physical units: Water and ice depths in hectometers (1.0 = 100 meters),
//                flow velocities in grid cells per second, salinity and nutrients in concentration units.
// Bindings: Reads fluid and landscape states from read_tex (Set 0, Binding 1);
//           Writes liquid height, velocities, divergence, and turbulence to write_tex (Set 0, Binding 0);
//           Updates liquid volume, soil nutrients, and salinity in atomic_tex (Set 0, Binding 2).
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

    // Output and read layer indices (float texture array)
    int f_liquid_height;   // Index of liquid water depth layer in float texture array
    int f_ice_height;      // Index of ice thickness layer in float texture array
    int f_net_velocity_x;  // Index of horizontal water velocity layer in float texture array
    int f_net_velocity_y;  // Index of vertical water velocity layer in float texture array
    int f_divergence;      // Index of fluid divergence diagnostic layer in float texture array
    int f_turbulence;      // Index of fluid turbulence diagnostic layer in float texture array
    int f_bedrock_height;  // Index of bedrock elevation layer in float texture array
    int f_sediment_height; // Index of sediment depth layer in float texture array
    int f_tidal_force;     // Index of solar tidal force layer in float texture array

    // Atomic storage layer indices
    int a_liquid_volume;    // Index of liquid volume layer in atomic texture array
    int a_ice_volume;       // Index of ice volume layer in atomic texture array
    int a_artesian_sources; // Index of artesian water spring layer in atomic texture array
    int a_salinity;         // Index of salinity layer in atomic texture array
    int a_soil_nutrients;   // Index of soil nutrients layer in atomic texture array
    int a_grasses;          // Index of grass biomass layer in atomic texture array
    int a_shrubs;           // Index of shrub biomass layer in atomic texture array
    int a_trees_canopy;     // Index of tree canopy biomass layer in atomic texture array

    float atomic_multiplier;       // Scale factor converting physical float units to fixed-point uint
    float flora_atomic_multiplier; // Scale factor converting vegetation biomass to fixed-point uint
    float max_flow_rate;           // Maximum volumetric water flow velocity scaling factor
    float artesian_flow_rate;      // Rate of subterranean artesian spring discharge into surface water
    float nutrient_erosion_rate;   // Rate of soil nutrient detachment and transport by moving runoff
    float tidal_amplitude;         // Surface water displacement amplitude induced by solar tidal gravity
} params;

// Minimum precision cutoff for 16-bit float stability
const float MINIMUM_EP = 0.001;
const float PI = 3.14159265359;

// Dynamic precision epsilon preventing asymmetric rounding drift between neighboring cells
float get_r16f_epsilon(float value) {
    float safe_val = max(value, MINIMUM_EP);
    return max(exp2(floor(log2(safe_val)) - 10.0), MINIMUM_EP);
}

// === BRANCHLESS SPHERICAL COORDINATE WRAPPING ===
// Re-maps coordinates that step over texture edges into valid spherical grid positions.
// Horizontally, coordinates wrap seamlessly across 360° longitude.
// Vertically, overstepping a pole crosses into the antipodal longitude (offset by +W/2)
// and reflects latitude, preventing seam artifacts without branching.
ivec2 polar_wrap(ivec2 pos, ivec2 size, out float sign_flip) {
    int W = size.x;
    int H = size.y;
    int H2 = 2 * H;
    
    int y_mod = ((pos.y % H2) + H2) % H2;
    int back = y_mod / H; 
    int y_final = (1 - back) * y_mod + back * (H2 - 1 - y_mod);
    int x_final = ((pos.x + back * (W / 2)) % W + W) % W;
    
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

    // 1. Prefetch local terrain, water, and biomass state from read snapshot and atomic grid
    float bedrock = imageLoad(read_tex, ivec3(id, params.f_bedrock_height)).r;
    float sediment = imageLoad(read_tex, ivec3(id, params.f_sediment_height)).r;
    float tidal_force = imageLoad(read_tex, ivec3(id, params.f_tidal_force)).r;

    uint u_liquid = imageLoad(atomic_tex, ivec3(id, params.a_liquid_volume)).r;
    uint u_ice = imageLoad(atomic_tex, ivec3(id, params.a_ice_volume)).r;
    uint u_artesian = imageLoad(atomic_tex, ivec3(id, params.a_artesian_sources)).r;
    uint u_salinity = imageLoad(atomic_tex, ivec3(id, params.a_salinity)).r;
    uint u_nutrients = imageLoad(atomic_tex, ivec3(id, params.a_soil_nutrients)).r;
    uint u_grasses = imageLoad(atomic_tex, ivec3(id, params.a_grasses)).r;
    uint u_shrubs = imageLoad(atomic_tex, ivec3(id, params.a_shrubs)).r;
    uint u_trees = imageLoad(atomic_tex, ivec3(id, params.a_trees_canopy)).r;

    float liquid_mass = float(u_liquid) / params.atomic_multiplier;
    float ice_mass = float(u_ice) / params.atomic_multiplier;
    float artesian_val = float(u_artesian) / params.atomic_multiplier;
    float salinity_mass = float(u_salinity) / params.atomic_multiplier;
    float nutrients_mass = float(u_nutrients) / params.atomic_multiplier;
    float total_local_biomass = (float(u_grasses) + float(u_shrubs) + float(u_trees)) / params.flora_atomic_multiplier;

    // 2. Compute effective surface height including solar tidal gravitational perturbation
    float self_height = bedrock + sediment + liquid_mass + ice_mass - (tidal_force * params.tidal_amplitude);

    // Sample neighbor surface elevations (North, South, East, West)
    float s_flip;
    ivec2 n_id = polar_wrap(id + ivec2(0, -1), size, s_flip);
    ivec2 s_id = polar_wrap(id + ivec2(0,  1), size, s_flip);
    ivec2 e_id = polar_wrap(id + ivec2(1,  0), size, s_flip);
    ivec2 w_id = polar_wrap(id + ivec2(-1,  0), size, s_flip);

    float n_b = imageLoad(read_tex, ivec3(n_id, params.f_bedrock_height)).r;
    float n_s = imageLoad(read_tex, ivec3(n_id, params.f_sediment_height)).r;
    float n_l = imageLoad(read_tex, ivec3(n_id, params.f_liquid_height)).r;
    float n_i = imageLoad(read_tex, ivec3(n_id, params.f_ice_height)).r;
    float n_tf = imageLoad(read_tex, ivec3(n_id, params.f_tidal_force)).r;
    float n_height = n_b + n_s + n_l + n_i - (n_tf * params.tidal_amplitude);

    float s_b = imageLoad(read_tex, ivec3(s_id, params.f_bedrock_height)).r;
    float s_s = imageLoad(read_tex, ivec3(s_id, params.f_sediment_height)).r;
    float s_l = imageLoad(read_tex, ivec3(s_id, params.f_liquid_height)).r;
    float s_i = imageLoad(read_tex, ivec3(s_id, params.f_ice_height)).r;
    float s_tf = imageLoad(read_tex, ivec3(s_id, params.f_tidal_force)).r;
    float s_height = s_b + s_s + s_l + s_i - (s_tf * params.tidal_amplitude);

    float e_b = imageLoad(read_tex, ivec3(e_id, params.f_bedrock_height)).r;
    float e_s = imageLoad(read_tex, ivec3(e_id, params.f_sediment_height)).r;
    float e_l = imageLoad(read_tex, ivec3(e_id, params.f_liquid_height)).r;
    float e_i = imageLoad(read_tex, ivec3(e_id, params.f_ice_height)).r;
    float e_tf = imageLoad(read_tex, ivec3(e_id, params.f_tidal_force)).r;
    float e_height = e_b + e_s + e_l + e_i - (e_tf * params.tidal_amplitude);

    float w_b = imageLoad(read_tex, ivec3(w_id, params.f_bedrock_height)).r;
    float w_s = imageLoad(read_tex, ivec3(w_id, params.f_sediment_height)).r;
    float w_l = imageLoad(read_tex, ivec3(w_id, params.f_liquid_height)).r;
    float w_i = imageLoad(read_tex, ivec3(w_id, params.f_ice_height)).r;
    float w_tf = imageLoad(read_tex, ivec3(w_id, params.f_tidal_force)).r;
    float w_height = w_b + w_s + w_l + w_i - (w_tf * params.tidal_amplitude);

    // 3. Outflow & Inflow Calculations:
    // Vegetation canopy and root biomass retard overland runoff velocity via friction drag
    float friction_factor = 2.0;
    float friction_mod = 1.0 / (1.0 + (total_local_biomass * friction_factor));

    float flow_rate_dt = params.max_flow_rate * params.deltaTime;
    float inflow_dt_scale = 0.25 * params.deltaTime;

    // Downhill hydraulic head drops to each cardinal neighbor
    float d_n = max(0.0, self_height - n_height) * friction_mod;
    float d_s = max(0.0, self_height - s_height) * friction_mod;
    float d_e = max(0.0, self_height - e_height) * cos_lat * friction_mod;
    float d_w = max(0.0, self_height - w_height) * cos_lat * friction_mod;
    float total_out_delta = d_n + d_s + d_e + d_w;

    // Restrict total outflow so the cell cannot lose more than half its volume or exceed CFL limits
    float max_outflow = min(liquid_mass * 0.5, flow_rate_dt);
    float total_outflow = (total_out_delta > MINIMUM_EP && liquid_mass > MINIMUM_EP) 
        ? min(max_outflow, total_out_delta * inflow_dt_scale) 
        : 0.0;

    // Quantize outflow to machine precision epsilon to avoid microscopic asymmetric rounding
    float ep_self = get_r16f_epsilon(liquid_mass);
    total_outflow = floor(total_outflow / ep_self) * ep_self;

    // Partition outflow proportionally across downhill directions
    float ratio_n = (total_out_delta > 0.0) ? (d_n / total_out_delta) : 0.0;
    float ratio_s = (total_out_delta > 0.0) ? (d_s / total_out_delta) : 0.0;
    float ratio_e = (total_out_delta > 0.0) ? (d_e / total_out_delta) : 0.0;
    float ratio_w = (total_out_delta > 0.0) ? (d_w / total_out_delta) : 0.0;

    float water_out_n = total_outflow * ratio_n;
    float water_out_s = total_outflow * ratio_s;
    float water_out_e = total_outflow * ratio_e;
    float water_out_w = total_outflow * ratio_w;
    float water_leaving = water_out_n + water_out_s + water_out_e + water_out_w;

    // Compute inflow arriving from uphill neighbors
    float water_in_n = 0.0;
    if (n_height > self_height && n_l > MINIMUM_EP) {
        float n_d_s = max(0.0, n_height - self_height);
        float n_out = min(n_l * 0.5, flow_rate_dt);
        water_in_n = min(n_out, n_d_s * inflow_dt_scale);
    }
    float water_in_s = 0.0;
    if (s_height > self_height && s_l > MINIMUM_EP) {
        float s_d_n = max(0.0, s_height - self_height);
        float s_out = min(s_l * 0.5, flow_rate_dt);
        water_in_s = min(s_out, s_d_n * inflow_dt_scale);
    }
    float water_in_e = 0.0;
    if (e_height > self_height && e_l > MINIMUM_EP) {
        float e_d_w = max(0.0, e_height - self_height) * cos_lat;
        float e_out = min(e_l * 0.5, flow_rate_dt);
        water_in_e = min(e_out, e_d_w * inflow_dt_scale);
    }
    float water_in_w = 0.0;
    if (w_height > self_height && w_l > MINIMUM_EP) {
        float w_d_e = max(0.0, w_height - self_height) * cos_lat;
        float w_out = min(w_l * 0.5, flow_rate_dt);
        water_in_w = min(w_out, w_d_e * inflow_dt_scale);
    }

    float water_entering = water_in_n + water_in_s + water_in_e + water_in_w;

    // Compute velocity, divergence, and turbulence diagnostics
    vec2 net_velocity = vec2(water_in_w - water_out_w - (water_in_e - water_out_e), water_in_n - water_out_n - (water_in_s - water_out_s));
    float divergence = water_entering - water_leaving;
    float turbulence = length(net_velocity);

    // 4. Nutrient erosion, salinity transport, and subterranean artesian spring recharge
    float flow_fraction = (liquid_mass > MINIMUM_EP) ? min(1.0, water_leaving / liquid_mass) : 0.0;
    float erosion_resistance = 1.0 / (1.0 + total_local_biomass);
    float nutrients_leaving = nutrients_mass * flow_fraction * params.nutrient_erosion_rate * erosion_resistance;
    float salinity_leaving = salinity_mass * flow_fraction;

    float nutrients_entering = water_entering * 0.1 * params.nutrient_erosion_rate;
    float salinity_entering = water_entering * 0.05;

    float artesian_injection = artesian_val * params.artesian_flow_rate * params.deltaTime;

    // 5. Compute net balances and apply atomic grid transactions
    float net_liquid = divergence + artesian_injection;
    float net_nutrients = nutrients_entering - nutrients_leaving;
    float net_salinity = salinity_entering - salinity_leaving;

    int d_liquid = int(round(net_liquid * params.atomic_multiplier));
    int d_nutrients = int(round(net_nutrients * params.atomic_multiplier));
    int d_salinity = int(round(net_salinity * params.atomic_multiplier));

    // Underflow-guarded atomic updates for liquid volume
    if (d_liquid < 0) {
        uint sub_val = uint(-d_liquid);
        sub_val = min(sub_val, u_liquid);
        if (sub_val > 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_liquid_volume), uint(-int(sub_val)));
    } else if (d_liquid > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_liquid_volume), uint(d_liquid));
    }

    // Underflow-guarded atomic updates for soil nutrients
    if (d_nutrients < 0) {
        uint sub_val = uint(-d_nutrients);
        sub_val = min(sub_val, u_nutrients);
        if (sub_val > 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_soil_nutrients), uint(-int(sub_val)));
    } else if (d_nutrients > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_soil_nutrients), uint(d_nutrients));
    }

    // Underflow-guarded atomic updates for salinity
    if (d_salinity < 0) {
        uint sub_val = uint(-d_salinity);
        sub_val = min(sub_val, u_salinity);
        if (sub_val > 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_salinity), uint(-int(sub_val)));
    } else if (d_salinity > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_salinity), uint(d_salinity));
    }

    // 6. Write updated fluid states and diagnostics to the float texture array
    float new_liquid_height = max(0.0, liquid_mass + float(d_liquid) / params.atomic_multiplier);
    float new_ice_height = ice_mass;

    imageStore(write_tex, ivec3(id, params.f_liquid_height), vec4(new_liquid_height, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_ice_height), vec4(new_ice_height, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_net_velocity_x), vec4(net_velocity.x, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_net_velocity_y), vec4(net_velocity.y, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_divergence), vec4(divergence, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_turbulence), vec4(turbulence, 0.0, 0.0, 0.0));
}
