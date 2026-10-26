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
    // 1. Delta Time (Offset 0)
    float deltaTime;

    // 2. Explicit Layer Indices
    int f_liquid_height;      // WATER layer 0 (WATER_LIQUID_HEIGHT)
    int f_ice_height;         // WATER layer 1 (WATER_ICE_HEIGHT)
    int f_net_velocity_x;     // WATER layer 2 (NET_VELOCITY.X)
    int f_net_velocity_y;     // WATER layer 3 (NET_VELOCITY.Y)
    int f_divergence;         // WATER layer 4 (DIVERGENCE)
    int f_turbulence;         // WATER layer 5 (TURBULENCE)
    int f_bedrock_height;     // LANDSCAPE layer 0 (BEDROCK_HEIGHT)
    int f_sediment_height;    // LANDSCAPE layer 3 (SEDIMENT_HEIGHT)
    int f_tidal_force;        // ENERGY layer 1 (TIDAL_FORCE)

    int a_liquid_volume;      // WATER atomic layer 0 (LIQUID_VOLUME)
    int a_ice_volume;         // WATER atomic layer 1 (ICE_VOLUME)
    int a_artesian_sources;   // WATER atomic layer 2 (ARTESIAN_SOURCES)
    int a_salinity;           // WATER atomic layer 3 (SALINITY)
    int a_soil_nutrients;     // LANDSCAPE atomic layer 1 (SOIL_NUTRIENTS)
    int a_grasses;            // FLORA atomic layer 0 (GRASSES)
    int a_shrubs;             // FLORA atomic layer 1 (SHRUBS)
    int a_trees_canopy;       // FLORA atomic layer 2 (TREES_CANOPY)

    // 3. User / WorldConfig Constants
    float atomic_multiplier;       // e.g. 100.0
    float flora_atomic_multiplier; // e.g. 1000000.0
    float max_flow_rate;           // e.g. 1.0
    float artesian_flow_rate;      // e.g. 0.01
    float nutrient_erosion_rate;   // e.g. 0.05
    float tidal_amplitude;         // e.g. 0.05
} params;

const float MINIMUM_EP = 0.001;
const float PI = 3.14159265359;

float get_r16f_epsilon(float value) {
    float safe_val = max(value, MINIMUM_EP);
    return max(exp2(floor(log2(safe_val)) - 10.0), MINIMUM_EP);
}

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
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(read_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Latitude mapping
    // Model B (cell-centered): poles reside on outer texture boundary edges (y = -0.5, y = size.y - 0.5)
    float norm_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * PI;
    float cos_lat = max(cos(latitude), 0.05);

    // 1. Memory Prefetch
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

    // 2. Surface Height & Neighborhood
    float self_height = bedrock + sediment + liquid_mass + ice_mass - (tidal_force * params.tidal_amplitude);

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

    // 3. Outflow & Inflow Calculations
    float friction_factor = 2.0;
    float friction_mod = 1.0 / (1.0 + (total_local_biomass * friction_factor));

    // [Fix #2] Cache repeated composite
    float flow_rate_dt = params.max_flow_rate * params.deltaTime;
    float inflow_dt_scale = 0.25 * params.deltaTime;

    float d_n = max(0.0, self_height - n_height) * friction_mod;
    float d_s = max(0.0, self_height - s_height) * friction_mod;
    float d_e = max(0.0, self_height - e_height) * cos_lat * friction_mod;
    float d_w = max(0.0, self_height - w_height) * cos_lat * friction_mod;
    float total_out_delta = d_n + d_s + d_e + d_w;

    float max_outflow = min(liquid_mass * 0.5, flow_rate_dt);
    float total_outflow = (total_out_delta > MINIMUM_EP && liquid_mass > MINIMUM_EP) 
        ? min(max_outflow, total_out_delta * inflow_dt_scale) 
        : 0.0;

    float ep_self = get_r16f_epsilon(liquid_mass);
    total_outflow = floor(total_outflow / ep_self) * ep_self;

    float ratio_n = (total_out_delta > 0.0) ? (d_n / total_out_delta) : 0.0;
    float ratio_s = (total_out_delta > 0.0) ? (d_s / total_out_delta) : 0.0;
    float ratio_e = (total_out_delta > 0.0) ? (d_e / total_out_delta) : 0.0;
    float ratio_w = (total_out_delta > 0.0) ? (d_w / total_out_delta) : 0.0;

    float water_out_n = total_outflow * ratio_n;
    float water_out_s = total_outflow * ratio_s;
    float water_out_e = total_outflow * ratio_e;
    float water_out_w = total_outflow * ratio_w;
    float water_leaving = water_out_n + water_out_s + water_out_e + water_out_w;

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

    vec2 net_velocity = vec2(water_in_w - water_out_w - (water_in_e - water_out_e), water_in_n - water_out_n - (water_in_s - water_out_s));
    float divergence = water_entering - water_leaving;
    float turbulence = length(net_velocity);

    // 4. Nutrient/Salinity Erosion & Artesian Injection
    float flow_fraction = (liquid_mass > MINIMUM_EP) ? min(1.0, water_leaving / liquid_mass) : 0.0;
    float erosion_resistance = 1.0 / (1.0 + total_local_biomass);
    float nutrients_leaving = nutrients_mass * flow_fraction * params.nutrient_erosion_rate * erosion_resistance;
    float salinity_leaving = salinity_mass * flow_fraction;

    // [Fix #1] Use cached water_entering instead of re-summing inflows
    float nutrients_entering = water_entering * 0.1 * params.nutrient_erosion_rate;
    float salinity_entering = water_entering * 0.05;

    float artesian_injection = artesian_val * params.artesian_flow_rate * params.deltaTime;

    // 5. Atomic Grid Transactions
    // [Fix #5] Reuse divergence instead of recomputing water_entering - water_leaving
    float net_liquid = divergence + artesian_injection;
    float net_nutrients = nutrients_entering - nutrients_leaving;
    float net_salinity = salinity_entering - salinity_leaving;

    int d_liquid = int(round(net_liquid * params.atomic_multiplier));
    int d_nutrients = int(round(net_nutrients * params.atomic_multiplier));
    int d_salinity = int(round(net_salinity * params.atomic_multiplier));

    if (d_liquid < 0) {
        uint sub_val = uint(-d_liquid);
        sub_val = min(sub_val, u_liquid);
        if (sub_val > 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_liquid_volume), uint(-int(sub_val)));
    } else if (d_liquid > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_liquid_volume), uint(d_liquid));
    }

    if (d_nutrients < 0) {
        uint sub_val = uint(-d_nutrients);
        sub_val = min(sub_val, u_nutrients);
        if (sub_val > 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_soil_nutrients), uint(-int(sub_val)));
    } else if (d_nutrients > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_soil_nutrients), uint(d_nutrients));
    }

    if (d_salinity < 0) {
        uint sub_val = uint(-d_salinity);
        sub_val = min(sub_val, u_salinity);
        if (sub_val > 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_salinity), uint(-int(sub_val)));
    } else if (d_salinity > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_salinity), uint(d_salinity));
    }

    // 6. Write Float Grid Outputs
    float new_liquid_height = max(0.0, liquid_mass + float(d_liquid) / params.atomic_multiplier);
    float new_ice_height = ice_mass;

    imageStore(write_tex, ivec3(id, params.f_liquid_height), vec4(new_liquid_height, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_ice_height), vec4(new_ice_height, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_net_velocity_x), vec4(net_velocity.x, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_net_velocity_y), vec4(net_velocity.y, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_divergence), vec4(divergence, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_turbulence), vec4(turbulence, 0.0, 0.0, 0.0));
}
