#[compute]
#version 450

// =============================================================================
// THERMODYNAMICS GENERATOR
// Compute pass that bootstraps planetary atmospheric circulation, thermal equilibrium, and humidity.
// Physical units: Temperatures in °C, wind velocities in grid cells per iteration,
//                water and ice heights in hectometers (1.0 = 100 meters), humidity proxy [0, ...].
// Bindings: Reads/modifies heat, wind, humidity, and water state in write_tex (Set 0, Binding 0);
//           Updates liquid and ice volumes in atomic_tex (Set 0, Binding 2);
//           Reads geothermal heat from atomic_tex (Set 0, Binding 2).
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
    // Water layer indices (WATER group)
    int f_liquid_height;
    int f_ice_height;
    int f_water_temp;

    // Atmospheric layer indices (ATMOSPHERE group)
    int f_wind_x;
    int f_wind_y;
    int f_air_temp;
    int f_humidity;

    // Landscape layer indices (LANDSCAPE group)
    int f_bedrock_height;
    int f_slope_x;
    int f_slope_y;
    int f_ground_temp;

    // Energy layer indices (ENERGY group)
    int f_sunlight;

    // Atomic storage layer indices
    int a_atomic_liquid;
    int a_atomic_ice;
    int a_atomic_geothermal;

    float atomic_multiplier;      // Scale factor converting physical float units to fixed-point uint
    float heat_transfer_rate;   // Conductive heat exchange rate between thermal reservoirs
    float evaporation_rate;       // Water-to-humidity evaporation transfer coefficient
    vec2 planet_rotation_vector;  // Planetary rotational axis orientation
    float coriolis_strength;      // Coriolis deflection acceleration magnitude
    float wind_friction;          // Baseline surface air drag coefficient
    float thermal_ice_influence;  // Ice thickness scale governing thermal insulation of underlying water
    
    // External equilibrium forcing constants
    float solar_heat_scale;      // Solar radiative heating coefficient
    float geothermal_heat_scale; // Geothermal conductive warming coefficient
    float lapse_rate;            // Elevation lapse rate cooling factor
} params;

// Approximates atmospheric surface barometric pressure in millibars (mb):
// Warmer and more humid air is less dense and creates lower surface pressure,
// generating pressure gradients that drive wind flow.
float get_pressure(float air_temp, float humidity) {
    float base_pressure = 1013.0; // Standard sea-level pressure in mb
    float temp_effect = air_temp * 1.5; 
    float hum_effect = humidity * 5.0; 
    return base_pressure - temp_effect - hum_effect;
}

// CFL safety cap limiting maximum air parcel transfer per cardinal neighbor
const float cfl_cap = 0.25;

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

// Computes outward wind mass flux across cardinal boundaries for an atmospheric cell
void get_cell_wind_outflow(ivec2 cell_id, ivec2 size, out vec4 out_flow) {
    float c_wind_x = imageLoad(write_tex, ivec3(cell_id, params.f_wind_x)).r;
    float c_wind_y = imageLoad(write_tex, ivec3(cell_id, params.f_wind_y)).r;

    // Scale east-west boundary flow along converging meridians
    float norm_y = (float(cell_id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * 3.14159265359;
    float cos_lat = max(cos(latitude), 0.05);
    
    // Vector components of outflow: X=North, Y=South, Z=East, W=West
    out_flow = vec4(
        max(-c_wind_y, 0.0),          // Northward velocity exiting North edge
        max(c_wind_y, 0.0),           // Southward velocity exiting South edge
        max(c_wind_x, 0.0) * cos_lat, // Eastward velocity exiting East edge
        max(-c_wind_x, 0.0) * cos_lat // Westward velocity exiting West edge
    );
    
    // Restrict outflow fraction to adhere to the CFL condition
    out_flow *= cfl_cap;
    float total = out_flow.x + out_flow.y + out_flow.z + out_flow.w;
    float k = min(1.0, 1.0 / (total + 1e-8));
    out_flow *= k;
}

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Compute latitude and meridian convergence cosine factor
    float norm_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * 3.14159265359;
    float cos_lat = max(cos(latitude), 0.05);

    // Read current state variables for the cell
    float liquid = imageLoad(write_tex, ivec3(id, params.f_liquid_height)).r;
    float ice = imageLoad(write_tex, ivec3(id, params.f_ice_height)).r;
    float water_temp = imageLoad(write_tex, ivec3(id, params.f_water_temp)).r;
    float air_temp = imageLoad(write_tex, ivec3(id, params.f_air_temp)).r;
    float ground_temp = imageLoad(write_tex, ivec3(id, params.f_ground_temp)).r;
    float humidity = imageLoad(write_tex, ivec3(id, params.f_humidity)).r;

    float dt = 1.0; // Integration step
    float water_mass = liquid + ice;

    // 0. THERMODYNAMIC FORCING: Continuously push ground temperature toward radiative-geothermal equilibrium
    float sunlight = imageLoad(write_tex, ivec3(id, params.f_sunlight)).r;
    uint geo_uint = imageLoad(atomic_tex, ivec3(id, params.a_atomic_geothermal)).r;
    float geothermal = float(geo_uint) / params.atomic_multiplier;
    
    float base_ground_heat = (sunlight * params.solar_heat_scale) + (geothermal * params.geothermal_heat_scale);
    float altitude = imageLoad(write_tex, ivec3(id, params.f_bedrock_height)).r;
    float expected_temp = base_ground_heat - ((altitude / 200.0) * params.lapse_rate);
    
    // Inject forcing into ground temperature
    float forcing_rate = 0.05 * dt; 
    ground_temp = mix(ground_temp, expected_temp, forcing_rate);

    // 1. CONDUCTIVE HEAT TRANSFER: Balance thermal energy across ground, water, and overlying atmosphere
    float has_water = step(0.001, water_mass);
    
    // Compute temperature differences between reservoirs
    float gw_diff = ground_temp - water_temp; // Ground to water
    float wa_diff = water_temp - air_temp;    // Water to air
    float ga_diff = ground_temp - air_temp;   // Ground to air (dry land)

    // Temperatures if water is present
    float wt_water = water_temp + (gw_diff * params.heat_transfer_rate - wa_diff * params.heat_transfer_rate) * dt;
    float gt_water = ground_temp - gw_diff * params.heat_transfer_rate * dt;
    float at_water = air_temp + wa_diff * params.heat_transfer_rate * dt;

    // Temperatures if dry land (direct ground-to-air exchange)
    float gt_land = ground_temp - ga_diff * params.heat_transfer_rate * dt;
    float at_land = air_temp + ga_diff * params.heat_transfer_rate * dt;

    // Select wet vs dry branch results without GPU branch divergence
    water_temp = mix(water_temp, wt_water, has_water);
    ground_temp = mix(gt_land, gt_water, has_water);
    air_temp = mix(at_land, at_water, has_water);

    // 2. LATENT HEAT & PHASE CHANGE: Simulate ice melting and water freezing
    float latent_heat_capacity = 10.0;
    float is_melting = step(0.0, water_temp) * step(0.001, ice);
    float is_freezing = step(0.0, -water_temp) * step(0.001, liquid);
    
    // Ice provides thermal insulation to underlying water as thickness increases
    float insulation_factor = clamp(1.0 - (ice / params.thermal_ice_influence), 0.0, 1.0);
    
    // Calculate mass converted during phase change based on available thermal energy
    float melt_mass = min(ice, max(0.0, water_temp) / latent_heat_capacity) * is_melting;
    float freeze_mass = min(liquid, (max(0.0, -water_temp) / latent_heat_capacity) * insulation_factor) * is_freezing;

    // Apply phase mass exchange and update water column temperature by latent heat absorption/release
    ice += freeze_mass - melt_mass;
    liquid += melt_mass - freeze_mass;
    water_temp += (freeze_mass - melt_mass) * latent_heat_capacity;

    // 3. PHASE-LOCKING: When ice and liquid coexist in thermal equilibrium, temperature clamps to 0°C
    float is_locked = step(0.001, ice) * step(0.001, liquid);
    water_temp = mix(water_temp, 0.0, is_locked);

    // Fetch neighbor atmospheric states (North, South, West, East) with spherical wrapping
    ivec2 size_xy = imageSize(write_tex).xy;
    float n_sign, s_sign, w_sign, e_sign;
    ivec2 n_id = polar_wrap(id + ivec2(0, -1), size_xy, n_sign);
    ivec2 s_id = polar_wrap(id + ivec2(0,  1), size_xy, s_sign);
    ivec2 w_id = polar_wrap(id + ivec2(-1,  0), size_xy, w_sign);
    ivec2 e_id = polar_wrap(id + ivec2(1,  0), size_xy, e_sign);

    float n_temp = imageLoad(write_tex, ivec3(n_id, params.f_air_temp)).r;
    float n_hum = imageLoad(write_tex, ivec3(n_id, params.f_humidity)).r;
    vec2 n_wind = vec2(imageLoad(write_tex, ivec3(n_id, params.f_wind_x)).r,
                       imageLoad(write_tex, ivec3(n_id, params.f_wind_y)).r) * n_sign;

    float s_temp = imageLoad(write_tex, ivec3(s_id, params.f_air_temp)).r;
    float s_hum = imageLoad(write_tex, ivec3(s_id, params.f_humidity)).r;
    vec2 s_wind = vec2(imageLoad(write_tex, ivec3(s_id, params.f_wind_x)).r,
                       imageLoad(write_tex, ivec3(s_id, params.f_wind_y)).r) * s_sign;

    float w_temp = imageLoad(write_tex, ivec3(w_id, params.f_air_temp)).r;
    float w_hum = imageLoad(write_tex, ivec3(w_id, params.f_humidity)).r;
    float w_gt = imageLoad(write_tex, ivec3(w_id, params.f_ground_temp)).r;
    vec2 w_wind = vec2(imageLoad(write_tex, ivec3(w_id, params.f_wind_x)).r,
                       imageLoad(write_tex, ivec3(w_id, params.f_wind_y)).r) * w_sign;

    float e_temp = imageLoad(write_tex, ivec3(e_id, params.f_air_temp)).r;
    float e_hum = imageLoad(write_tex, ivec3(e_id, params.f_humidity)).r;
    float e_gt = imageLoad(write_tex, ivec3(e_id, params.f_ground_temp)).r;
    vec2 e_wind = vec2(imageLoad(write_tex, ivec3(e_id, params.f_wind_x)).r,
                       imageLoad(write_tex, ivec3(e_id, params.f_wind_y)).r) * e_sign;

    // 4. ATMOSPHERIC ADVECTION: Transport air temperature, humidity, and momentum via wind flow
    float wind_x = imageLoad(write_tex, ivec3(id, params.f_wind_x)).r;
    float wind_y = imageLoad(write_tex, ivec3(id, params.f_wind_y)).r;
    
    vec4 my_outflow;
    get_cell_wind_outflow(id, size_xy, my_outflow);
    float eps = 0.001;
    my_outflow = floor(my_outflow / eps) * eps;
    
    // Polar dampening suppresses kinetic wind acceleration directly over the poles
    float dist_from_pole = min(float(id.y), float(size.y - 1 - id.y));
    float polar_dampen = smoothstep(0.0, 10.0, dist_from_pole);
    my_outflow *= polar_dampen;

    float air_leaving = my_outflow.x + my_outflow.y + my_outflow.z + my_outflow.w;
    float retained_air = max(0.0, 1.0 - air_leaving);
    
    // Track conserved parcels of thermal energy, moisture, and wind momentum
    float thermal_mass = retained_air * air_temp;
    float humidity_mass = retained_air * humidity;
    vec2 retained_wind = retained_air * vec2(wind_x, wind_y);
    
    float accumulated_air = 0.0;
    
    // Inflow from North neighbor (Southward flow entering our top boundary)
    {
        vec4 nb_out; get_cell_wind_outflow(n_id, size_xy, nb_out);
        float flow = floor(nb_out.y / eps) * eps;
        accumulated_air += flow;
        thermal_mass += flow * n_temp;
        humidity_mass += flow * n_hum;
        retained_wind += flow * n_wind;
    }
    // Inflow from South neighbor (Northward flow entering our bottom boundary)
    {
        vec4 nb_out; get_cell_wind_outflow(s_id, size_xy, nb_out);
        float flow = floor(nb_out.x / eps) * eps;
        accumulated_air += flow;
        thermal_mass += flow * s_temp;
        humidity_mass += flow * s_hum;
        retained_wind += flow * s_wind;
    }
    // Inflow from East neighbor (Westward flow entering our right boundary)
    {
        vec4 nb_out; get_cell_wind_outflow(e_id, size_xy, nb_out);
        float flow = floor(nb_out.w / eps) * eps;
        accumulated_air += flow;
        thermal_mass += flow * e_temp;
        humidity_mass += flow * e_hum;
        retained_wind += flow * e_wind;
    }
    // Inflow from West neighbor (Eastward flow entering our left boundary)
    {
        vec4 nb_out; get_cell_wind_outflow(w_id, size_xy, nb_out);
        float flow = floor(nb_out.z / eps) * eps;
        accumulated_air += flow;
        thermal_mass += flow * w_temp;
        humidity_mass += flow * w_hum;
        retained_wind += flow * w_wind;
    }
    
    float final_air = retained_air + accumulated_air;
    float has_final_air = step(0.0001, final_air);
    
    // Compute normalized advected values for temperature, humidity, and wind momentum
    air_temp = mix(air_temp, thermal_mass / max(final_air, 0.0001), has_final_air);
    humidity = mix(humidity, humidity_mass / max(final_air, 0.0001), has_final_air);
    wind_x = mix(wind_x, retained_wind.x / max(final_air, 0.0001), has_final_air);
    wind_y = mix(wind_y, retained_wind.y / max(final_air, 0.0001), has_final_air);

    // 5. EVAPORATION: Warm air holds more moisture; wind accelerates surface evaporation
    float max_humidity = max(0.0, air_temp * 0.05 + 1.0);
    float can_evap = step(0.001, liquid) * step(humidity, max_humidity);
    float wind_speed = length(vec2(wind_x, wind_y));
    float wind_factor = 1.0 + wind_speed * 0.5; 
    float evap = min(liquid, (max_humidity - humidity) * params.evaporation_rate * wind_factor * dt) * can_evap;
    
    // Transfer evaporated water to air moisture and deduct evaporative cooling heat from water
    liquid -= evap;
    humidity += evap;
    water_temp -= evap * 5.0; 

    // 6. PRESSURE GRADIENT FORCE (PGF) & CORIOLIS ACCELERATION
    float p_w = get_pressure(w_temp, w_hum);
    float p_e = get_pressure(e_temp, e_hum);
    float p_n = get_pressure(n_temp, n_hum);
    float p_s = get_pressure(s_temp, s_hum);
    
    // Compute PGF: air accelerates from high pressure to low pressure
    float pgf_x = ((p_w - p_e) / cos_lat) * 1.5 * dt; 
    float pgf_y = (p_n - p_s) * 1.5 * dt; 
    
    // Apply polar dampening to avoid divergent acceleration at coordinate singularities
    pgf_x *= polar_dampen;
    pgf_y *= polar_dampen;

    // Apply Pressure Gradient acceleration to wind vector
    wind_x += pgf_x;
    wind_y += pgf_y;

    // Apply Coriolis deflection using exact 2D rotation matrix to conserve kinetic energy:
    // Winds curve right in the northern hemisphere and left in the southern hemisphere
    float f = 2.0 * params.coriolis_strength * sin(latitude);
    float alpha = f * dt;
    float cos_a = cos(alpha);
    float sin_a = sin(alpha);
    
    float new_wind_x = wind_x * cos_a + wind_y * sin_a;
    float new_wind_y = -wind_x * sin_a + wind_y * cos_a;
    wind_x = new_wind_x;
    wind_y = new_wind_y;

    // Apply surface roughness drag: steep mountain slopes generate higher friction than smooth ocean surfaces
    float slope_x = imageLoad(write_tex, ivec3(id, params.f_slope_x)).r;
    float slope_y = imageLoad(write_tex, ivec3(id, params.f_slope_y)).r;
    float slope_mag = length(vec2(slope_x, slope_y));
    
    // Increase friction over steep topography (limited floor of 0.5)
    float mountain_drag = clamp(params.wind_friction - (slope_mag * 0.2), 0.5, params.wind_friction);
    
    // Smooth water and ice surfaces exert less drag (friction multiplier ~ 0.99)
    float is_smooth = step(0.1, liquid + ice);
    float friction_mult = mix(mountain_drag, 0.99, is_smooth); 
    
    wind_x *= friction_mult;
    wind_y *= friction_mult;

    // Polar blending: smoothly homogenize scalar values at extreme polar latitudes
    if (dist_from_pole < 5.0) {
        float ew_mix = 0.5 * dt;
        ground_temp = mix(ground_temp, (e_gt + w_gt) * 0.5, ew_mix);
        air_temp = mix(air_temp, (e_temp + w_temp) * 0.5, ew_mix);
        humidity = mix(humidity, (e_hum + w_hum) * 0.5, ew_mix);
    }

    // Write updated wind velocities back to float texture array
    imageStore(write_tex, ivec3(id, params.f_wind_x), vec4(wind_x, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_wind_y), vec4(wind_y, 0.0, 0.0, 0.0));

    // Write updated temperatures, humidity, and water heights back to float texture array
    imageStore(write_tex, ivec3(id, params.f_water_temp), vec4(water_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_ground_temp), vec4(ground_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_air_temp), vec4(air_temp, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_humidity), vec4(humidity, 0.0, 0.0, 0.0));

    imageStore(write_tex, ivec3(id, params.f_liquid_height), vec4(liquid, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_ice_height), vec4(ice, 0.0, 0.0, 0.0));

    // Synchronize liquid water and ice mass into atomic storage
    imageStore(atomic_tex, ivec3(id, params.a_atomic_liquid), uvec4(uint(liquid * params.atomic_multiplier), 0, 0, 0));
    imageStore(atomic_tex, ivec3(id, params.a_atomic_ice), uvec4(uint(ice * params.atomic_multiplier), 0, 0, 0));
}

