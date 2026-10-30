#[compute]
#version 450

// =============================================================================
// SWE ATMOSPHERE SIMULATION
// Compute pass that simulates fine-grid atmospheric wind steering, humidity transport, and precipitation.
// Physical units: Wind velocities u, v in grid cells per second, column height h (dimensionless, reference 1.0),
//                humidity [0, 1], precipitation rates in display units.
// Bindings: Reads fine climate and topography from read_tex (Set 0, Binding 1);
//           Reads coarse dynamic states from coarse_read_tex (Set 0, Binding 7);
//           Writes fine wind, humidity, precipitation, and pressure to write_tex (Set 0, Binding 0);
//           Updates liquid water and snow volumes in atomic_tex (Set 0, Binding 2).
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
    int f_wind_x;   // Index of eastward wind velocity layer in float texture array
    int f_wind_y;   // Index of southward wind velocity layer in float texture array
    int f_air_temp; // Index of air temperature layer in float texture array (read-only)
    int f_humidity; // Index of atmospheric humidity layer in float texture array
    int f_rain;     // Index of rain precipitation display layer in float texture array
    int f_snow;     // Index of snow precipitation display layer in float texture array
    int f_pressure; // Index of atmospheric column height layer in float texture array

    // Read layer indices (read from read_tex)
    int f_bedrock_height;  // Index of bedrock elevation layer in float texture array
    int f_sediment_height; // Index of sediment depth layer in float texture array
    int f_water_temp;      // Index of water temperature layer in float texture array

    // Atomic storage layer indices
    int a_liquid_volume; // Index of liquid volume layer in atomic texture array
    int a_ice_volume;    // Index of ice volume layer in atomic texture array
    int a_grasses;       // Index of grass biomass layer in atomic texture array
    int a_shrubs;        // Index of shrub biomass layer in atomic texture array
    int a_trees_canopy;  // Index of tree canopy biomass layer in atomic texture array

    // Coarse dynamics layer indices (sampled from coarse_read_tex)
    int c_h_upper;      // Index of coarse upper-layer column height layer
    int c_h_lower;      // Index of coarse lower-layer column height layer
    int c_wind_lower_x; // Index of coarse lower-layer eastward wind velocity layer
    int c_wind_lower_y; // Index of coarse lower-layer southward wind velocity layer
    int c_terrain;      // Index of coarse terrain elevation layer

    float atomic_multiplier;        // Scale factor converting physical float units to fixed-point uint
    float flora_atomic_multiplier;  // Scale factor converting vegetation biomass to fixed-point uint
    float coriolis_strength;        // Coriolis deflection acceleration magnitude
    float wind_advection_scale;     // Semi-Lagrangian humidity advection velocity scaling
    float evaporation_rate;         // Surface liquid water to atmospheric vapor evaporation rate
    float precipitation_rate;       // Atmospheric condensation and precipitation rate
    float latent_heat_vaporization; // Thermal energy exchange per unit of phase transition
} params;

const float MINIMUM_EP = 0.001;
const float PI = 3.14159265359;

// Minimum column height floor to prevent division-by-zero or velocity explosions when h approaches zero
const float MIN_COLUMN_HEIGHT = 0.1;

// Coupling coefficients between water-cycle mass exchange and barometric column height
const float EVAP_PRESSURE_SCALE = 0.0;
const float PRECIP_PRESSURE_SCALE = 0.0;

// Evaporation and atmospheric moisture holding capacity constants
const float HUMIDITY_CAPACITY_BASE = 0.08;
const float HUMIDITY_CAPACITY_TEMP_SCALE = 0.035;
const float WIND_VENTILATION_FACTOR = 0.5;
const float MAX_WIND_VENTILATION = 5.0;
const float TRANSPIRATION_BOOST_FACTOR = 0.5;
const float TRANSPIRATION_BIOMASS_MAX = 5.0;

// Maximum fraction of cell humidity transferred across a boundary in a single time step
const float HUMIDITY_ADVECTION_MAX = 0.25;

// Adiabatic lapse cooling and convective updraft cloud condensation factors
const float LAPSE_RATE = 0.15;
const float UPDRAFT_COOLING_FACTOR = 0.5;

// Display visualizer smoothing and decay constants
const float PRECIP_DISPLAY_AMPLIFIER = 50.0;
const float PRECIP_DISPLAY_LERP_RATE = 5.0;

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

// Samples coarse wind vector components with spherical polar wrapping and directional sign flip
vec2 load_coarse_wind_tap(ivec2 pos, ivec2 size, int u_layer, int v_layer) {
    float flip = 1.0;
    if (pos.y < 0) {
        pos.y = -pos.y - 1;
        pos.x = (pos.x + size.x / 2) % size.x;
        flip = -1.0;
    } else if (pos.y >= size.y) {
        pos.y = 2 * size.y - 1 - pos.y;
        pos.x = (pos.x + size.x / 2) % size.x;
        flip = -1.0;
    }
    pos.x = (pos.x % size.x + size.x) % size.x;
    float u = imageLoad(coarse_read_tex, ivec3(pos, u_layer)).r * flip;
    float v = imageLoad(coarse_read_tex, ivec3(pos, v_layer)).r * flip;
    return vec2(u, v);
}

// Bilinearly filters coarse wind vector at fine cell UV coordinates
vec2 sample_coarse_wind(vec2 fine_uv, ivec2 coarse_size, int u_layer, int v_layer) {
    vec2 coarse_fpos = fine_uv * vec2(coarse_size) - 0.5;
    ivec2 c0 = ivec2(floor(coarse_fpos));
    vec2 frac = coarse_fpos - vec2(c0);

    vec2 v00 = load_coarse_wind_tap(c0 + ivec2(0, 0), coarse_size, u_layer, v_layer);
    vec2 v10 = load_coarse_wind_tap(c0 + ivec2(1, 0), coarse_size, u_layer, v_layer);
    vec2 v01 = load_coarse_wind_tap(c0 + ivec2(0, 1), coarse_size, u_layer, v_layer);
    vec2 v11 = load_coarse_wind_tap(c0 + ivec2(1, 1), coarse_size, u_layer, v_layer);

    return mix(mix(v00, v10, frac.x), mix(v01, v11, frac.x), frac.y);
}

// Samples coarse scalar values with spherical polar wrapping
float load_coarse_scalar_tap(ivec2 pos, ivec2 size, int layer) {
    if (pos.y < 0) {
        pos.y = -pos.y - 1;
        pos.x = (pos.x + size.x / 2) % size.x;
    } else if (pos.y >= size.y) {
        pos.y = 2 * size.y - 1 - pos.y;
        pos.x = (pos.x + size.x / 2) % size.x;
    }
    pos.x = (pos.x % size.x + size.x) % size.x;
    return imageLoad(coarse_read_tex, ivec3(pos, layer)).r;
}

// Bilinearly filters coarse scalar fields at fine cell UV coordinates
float sample_coarse_scalar(vec2 fine_uv, ivec2 coarse_size, int layer) {
    vec2 coarse_fpos = fine_uv * vec2(coarse_size) - 0.5;
    ivec2 c0 = ivec2(floor(coarse_fpos));
    vec2 frac = coarse_fpos - vec2(c0);

    float s00 = load_coarse_scalar_tap(c0 + ivec2(0, 0), coarse_size, layer);
    float s10 = load_coarse_scalar_tap(c0 + ivec2(1, 0), coarse_size, layer);
    float s01 = load_coarse_scalar_tap(c0 + ivec2(0, 1), coarse_size, layer);
    float s11 = load_coarse_scalar_tap(c0 + ivec2(1, 1), coarse_size, layer);

    return mix(mix(s00, s10, frac.x), mix(s01, s11, frac.x), frac.y);
}

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(read_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Latitude and meridian convergence metric
    float norm_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * PI;
    float cos_lat = max(cos(latitude), 0.15);
    float inv_cos = 1.0 / cos_lat;

    // 1. Fetch current cell state from read snapshot (Frame N-1)
    float bedrock = imageLoad(read_tex, ivec3(id, params.f_bedrock_height)).r;
    float sediment = imageLoad(read_tex, ivec3(id, params.f_sediment_height)).r;
    float b = bedrock + sediment;
    float terrain_height = b;
    float air_temp = imageLoad(read_tex, ivec3(id, params.f_air_temp)).r;
    float humidity = imageLoad(read_tex, ivec3(id, params.f_humidity)).r;
    float water_temp = imageLoad(read_tex, ivec3(id, params.f_water_temp)).r;

    uint u_liquid = imageLoad(atomic_tex, ivec3(id, params.a_liquid_volume)).r;
    float liquid_mass = float(u_liquid) / params.atomic_multiplier;

    uint u_grasses = imageLoad(atomic_tex, ivec3(id, params.a_grasses)).r;
    uint u_shrubs = imageLoad(atomic_tex, ivec3(id, params.a_shrubs)).r;
    uint u_trees = imageLoad(atomic_tex, ivec3(id, params.a_trees_canopy)).r;
    float total_local_biomass = (float(u_grasses) + float(u_shrubs) + float(u_trees)) / params.flora_atomic_multiplier;

    // 2. Sample coarse global circulation state
    ivec2 coarse_size = imageSize(coarse_read_tex).xy;
    vec2 fine_uv = (vec2(id) + 0.5) / vec2(size);

    vec2 u_coarse = sample_coarse_wind(fine_uv, coarse_size, params.c_wind_lower_x, params.c_wind_lower_y);
    float h_upper = sample_coarse_scalar(fine_uv, coarse_size, params.c_h_upper);
    float h_lower = sample_coarse_scalar(fine_uv, coarse_size, params.c_h_lower);
    float h_coarse = h_upper + h_lower;
    float b_coarse = sample_coarse_scalar(fine_uv, coarse_size, params.c_terrain);

    // 3. Pre-compute neighbor coordinates for elevation gradients and advection
    float n_flip, s_flip, e_flip, w_flip;
    ivec2 n_id = polar_wrap(id + ivec2(0, -1), size, n_flip);
    ivec2 s_id = polar_wrap(id + ivec2(0,  1), size, s_flip);
    ivec2 e_id = polar_wrap(id + ivec2(1,  0), size, e_flip);
    ivec2 w_id = polar_wrap(id + ivec2(-1, 0), size, w_flip);

    float bN = imageLoad(read_tex, ivec3(n_id, params.f_bedrock_height)).r + imageLoad(read_tex, ivec3(n_id, params.f_sediment_height)).r;
    float bS = imageLoad(read_tex, ivec3(s_id, params.f_bedrock_height)).r + imageLoad(read_tex, ivec3(s_id, params.f_sediment_height)).r;
    float bE = imageLoad(read_tex, ivec3(e_id, params.f_bedrock_height)).r + imageLoad(read_tex, ivec3(e_id, params.f_sediment_height)).r;
    float bW = imageLoad(read_tex, ivec3(w_id, params.f_bedrock_height)).r + imageLoad(read_tex, ivec3(w_id, params.f_sediment_height)).r;

    // 4. Fine terrain wind steering:
    // Winds deflect around steep topographic barriers, channel through mountain passes,
    // and accelerate over elevated ridgelines
    vec2 grad_b = vec2(0.5 * (bE - bW) * inv_cos, 0.5 * (bS - bN));
    float grad_len = length(grad_b);
    vec2 n_hat = (grad_len > 0.001) ? (grad_b / grad_len) : vec2(0.0);
    vec2 t_hat = vec2(-n_hat.y, n_hat.x);

    float w_up = dot(u_coarse, n_hat);
    const float ALPHA_DEFLECT = 0.5;
    const float BETA_CHANNEL = 0.3;
    vec2 u_steered = u_coarse - ALPHA_DEFLECT * max(0.0, w_up) * n_hat + BETA_CHANNEL * dot(u_coarse, t_hat) * t_hat;

    // Ridge speedup: winds accelerate over peaks elevated above the regional coarse terrain average
    const float H_SCALE = 10.0;
    float ridge_factor = 1.0 + clamp((b - b_coarse) / H_SCALE, 0.0, 0.4);
    vec2 u_fine = u_steered * ridge_factor;

    float final_u = clamp(u_fine.x, -2.0, 2.0);
    float final_v = clamp(u_fine.y, -2.0, 2.0);
    if (isnan(final_u) || isinf(final_u)) final_u = 0.0;
    if (isnan(final_v) || isinf(final_v)) final_v = 0.0;
    float wind_speed = length(vec2(final_u, final_v));

    // Local column height reflecting topographic displacement
    float wh = max(MIN_COLUMN_HEIGHT, h_coarse - (b - b_coarse) * 0.001);

    // 5. Read neighbor winds, pressures, and humidities for divergence and transport
    float uN = imageLoad(read_tex, ivec3(n_id, params.f_wind_x)).r * n_flip;
    float vN = imageLoad(read_tex, ivec3(n_id, params.f_wind_y)).r * n_flip;
    float uS = imageLoad(read_tex, ivec3(s_id, params.f_wind_x)).r * s_flip;
    float vS = imageLoad(read_tex, ivec3(s_id, params.f_wind_y)).r * s_flip;
    float uE = imageLoad(read_tex, ivec3(e_id, params.f_wind_x)).r * e_flip;
    float vE = imageLoad(read_tex, ivec3(e_id, params.f_wind_y)).r * e_flip;
    float uW = imageLoad(read_tex, ivec3(w_id, params.f_wind_x)).r * w_flip;
    float vW = imageLoad(read_tex, ivec3(w_id, params.f_wind_y)).r * w_flip;

    float hN = imageLoad(read_tex, ivec3(n_id, params.f_pressure)).r;
    float hS = imageLoad(read_tex, ivec3(s_id, params.f_pressure)).r;
    float hE = imageLoad(read_tex, ivec3(e_id, params.f_pressure)).r;
    float hW = imageLoad(read_tex, ivec3(w_id, params.f_pressure)).r;

    float hN_hum = imageLoad(read_tex, ivec3(n_id, params.f_humidity)).r;
    float hS_hum = imageLoad(read_tex, ivec3(s_id, params.f_humidity)).r;
    float hE_hum = imageLoad(read_tex, ivec3(e_id, params.f_humidity)).r;
    float hW_hum = imageLoad(read_tex, ivec3(w_id, params.f_humidity)).r;

    float huN = uN * hN, hvN = vN * hN;
    float huS = uS * hS, hvS = vS * hS;
    float huE = uE * hE, hvE = vE * hE;
    float huW = uW * hW, hvW = vW * hW;

    // 6. Semi-Lagrangian humidity advection:
    // Uses Michaelis-Menten saturation curves so flow scales smoothly with wind speed without hard clamp kinks
    float k_adv = params.wind_advection_scale * params.deltaTime;
    vec2 self_adv = abs(vec2(final_u, final_v)) * k_adv;
    vec2 self_flow = self_adv / (1.0 + self_adv / HUMIDITY_ADVECTION_MAX);
    float humidity_out_n = (final_v < 0.0) ? self_flow.y : 0.0;
    float humidity_out_s = (final_v > 0.0) ? self_flow.y : 0.0;
    float humidity_out_w = (final_u < 0.0) ? self_flow.x : 0.0;
    float humidity_out_e = (final_u > 0.0) ? self_flow.x : 0.0;

    float air_leaving = humidity_out_n + humidity_out_s + humidity_out_w + humidity_out_e;
    float air_retained = max(0.0, 1.0 - air_leaving);

    float adv_n = (vN > 0.0) ?  vN * k_adv : 0.0;
    float adv_s = (vS < 0.0) ? -vS * k_adv : 0.0;
    float adv_w = (uW > 0.0) ?  uW * k_adv : 0.0;
    float adv_e = (uE < 0.0) ? -uE * k_adv : 0.0;
    float humidity_in_n = adv_n / (1.0 + adv_n / HUMIDITY_ADVECTION_MAX);
    float humidity_in_s = adv_s / (1.0 + adv_s / HUMIDITY_ADVECTION_MAX);
    float humidity_in_w = adv_w / (1.0 + adv_w / HUMIDITY_ADVECTION_MAX);
    float humidity_in_e = adv_e / (1.0 + adv_e / HUMIDITY_ADVECTION_MAX);

    float total_humidity_in = (humidity_in_n * hN_hum) + (humidity_in_s * hS_hum) + (humidity_in_w * hW_hum) + (humidity_in_e * hE_hum);
    float total_air_weight = air_retained + humidity_in_n + humidity_in_s + humidity_in_w + humidity_in_e;
    humidity = (air_retained * humidity + total_humidity_in) / max(total_air_weight, 0.0001);
    humidity = mix(humidity, 0.0, step(humidity, MINIMUM_EP));

    // 7. Surface evaporation and plant transpiration:
    // Warmer surfaces evaporate faster; wind ventilation accelerates vapor transport into the air
    float evap_surface_temp = mix(air_temp, water_temp, step(MINIMUM_EP, liquid_mass));
    float evap_capacity = clamp(HUMIDITY_CAPACITY_BASE + HUMIDITY_CAPACITY_TEMP_SCALE * max(0.0, evap_surface_temp), 0.05, 1.0);

    float wind_vent_term = wind_speed * WIND_VENTILATION_FACTOR;
    float wind_ventilation = 1.0 + wind_vent_term / (1.0 + wind_vent_term / MAX_WIND_VENTILATION);
    float evap_potential = max(0.0, evap_capacity - humidity) * params.evaporation_rate * wind_ventilation * params.deltaTime;

    float biomass_sat = total_local_biomass / (1.0 + total_local_biomass / TRANSPIRATION_BIOMASS_MAX);
    float transpiration_boost = 1.0 + biomass_sat * TRANSPIRATION_BOOST_FACTOR;
    float evap_amount = (liquid_mass > MINIMUM_EP) ? min(liquid_mass, evap_potential * transpiration_boost) : 0.0;

    humidity += evap_amount;
    water_temp -= (liquid_mass > MINIMUM_EP) ? (evap_amount / (liquid_mass + 0.1)) * params.latent_heat_vaporization : 0.0;

    wh += evap_amount * EVAP_PRESSURE_SCALE;

    // 8. Orographic cooling and condensation (Precipitation):
    // Air parcels cool adiabatically when pushed up mountains or into convective updrafts
    float effective_air_temp = air_temp - terrain_height * LAPSE_RATE;
    float max_humidity_capacity = clamp(HUMIDITY_CAPACITY_BASE + HUMIDITY_CAPACITY_TEMP_SCALE * max(0.0, effective_air_temp), 0.03, 1.0);

    // Updraft cooling calculated from horizontal wind convergence (-div(hu))
    float div_hu = (huE - huW) * inv_cos + (hvS - hvN);
    float updraft_cooling = max(0.0, -div_hu / max(wh, MINIMUM_EP)) * UPDRAFT_COOLING_FACTOR;
    max_humidity_capacity = clamp(max_humidity_capacity - updraft_cooling, 0.03, 1.0);

    // Condense excess moisture that exceeds atmospheric holding capacity into precipitation
    float excess_humidity = max(0.0, humidity - max_humidity_capacity);
    float precip_amount = min(humidity, excess_humidity * params.precipitation_rate * params.deltaTime);

    humidity -= precip_amount;
    air_temp += precip_amount * params.latent_heat_vaporization;

    wh -= precip_amount * PRECIP_PRESSURE_SCALE;
    wh = max(wh, MIN_COLUMN_HEIGHT);

    // Partition precipitation into rain (temperatures >= 0°C) and snow (temperatures < 0°C)
    float is_rain = step(0.0, air_temp);
    float rain_amount = precip_amount * is_rain;
    float snow_amount = precip_amount * (1.0 - is_rain);

    // Smooth visual precipitation display overlays
    float precip_rate_per_sec = (params.deltaTime > 0.0) ? (precip_amount / params.deltaTime) : 0.0;
    float target_rain = clamp(precip_rate_per_sec * PRECIP_DISPLAY_AMPLIFIER, 0.0, 1.0) * is_rain;
    float target_snow = clamp(precip_rate_per_sec * PRECIP_DISPLAY_AMPLIFIER, 0.0, 1.0) * (1.0 - is_rain);
    float old_rain = imageLoad(read_tex, ivec3(id, params.f_rain)).r;
    float old_snow = imageLoad(read_tex, ivec3(id, params.f_snow)).r;
    float lerp_k = clamp(PRECIP_DISPLAY_LERP_RATE * params.deltaTime, 0.0, 1.0);
    float rain_display = mix(old_rain, target_rain, lerp_k);
    float snow_display = mix(old_snow, target_snow, lerp_k);

    // 9. Atomic volume transactions (evaporation deduction, rain and snow accumulation)
    float net_liquid_change = rain_amount - evap_amount;
    int d_liquid = int(round(net_liquid_change * params.atomic_multiplier));
    int d_snow = int(round(snow_amount * params.atomic_multiplier));

    if (d_liquid < 0) {
        uint sub_val = uint(-d_liquid);
        sub_val = min(sub_val, u_liquid);
        if (sub_val > 0) imageAtomicAdd(atomic_tex, ivec3(id, params.a_liquid_volume), uint(-int(sub_val)));
    } else if (d_liquid > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_liquid_volume), uint(d_liquid));
    }
    if (d_snow > 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_ice_volume), uint(d_snow));
    }

    // 10. Store output atmospheric states in the float texture array
    imageStore(write_tex, ivec3(id, params.f_wind_x), vec4(final_u, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_wind_y), vec4(final_v, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_humidity), vec4(clamp(humidity, 0.0, 1.0), 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_rain), vec4(clamp(rain_display, 0.0, 1.0), 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_snow), vec4(clamp(snow_display, 0.0, 1.0), 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_pressure), vec4(wh, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_water_temp), vec4(clamp(water_temp, -50.0, 60.0), 0.0, 0.0, 0.0));
}
