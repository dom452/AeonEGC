#[compute]
#version 450

// =============================================================================
// WATER FLOW GENERATOR
// Compute pass that simulates pre-simulation gravitational hydraulic flow, pooling oceans and rivers.
// Physical units: Liquid and surface heights in hectometers (1.0 = 100 meters),
//                flow velocities in grid cells per iteration, temperature in °C.
// Bindings: Reads/modifies liquid height, velocities, divergence, turbulence, and temperature
//           in write_tex (Set 0, Binding 0);
//           Synchronizes liquid volume and salinity in atomic_tex (Set 0, Binding 2).
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
    int f_water_liquid_height;
    int f_net_velocity_x;
    int f_net_velocity_y;
    int f_divergence;
    int f_turbulence;
    int f_water_temp;
    
    int f_bedrock_height;
    int f_sediment_height;

    float max_flow_rate;     // Maximum volumetric fluid transfer rate scaling factor
    int a_liquid_volume;     // Index of liquid volume layer in atomic texture array
    int a_salinity;          // Index of salinity layer in atomic texture array
    float atomic_multiplier; // Scale factor converting physical float units to fixed-point uint
} params;

// Courant-Friedrichs-Lewy (CFL) stability cap: restricts maximum flow fraction to 0.25 per cardinal
// neighbor, preventing a cell from evacuating more fluid than it holds in a single step
const float cfl_cap = 0.25;

// Minimum epsilon threshold to maintain 16-bit half-precision float numeric stability
const float MINIMUM_EP = 0.0001;

// Grid offset vectors for the 4 cardinal directions (North, South, East, West)
const ivec2 NEIGHBOR_OFFSETS[4] = ivec2[](
    ivec2(0, -1), // 0: North
    ivec2(0,  1), // 1: South
    ivec2(1,  0), // 2: East
    ivec2(-1, 0)  // 3: West
);

// Computes the dynamic machine epsilon for a given 16-bit float magnitude.
// Quantizing flow to this step prevents asymmetric rounding drift between adjacent cells.
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

// Samples bedrock, sediment, and liquid water to return total hydraulic surface elevation
float get_surface_height(ivec2 pos, ivec2 size) {
    float unused_sign;
    ivec2 wrapped_pos = polar_wrap(pos, size, unused_sign);
    float land_h = imageLoad(write_tex, ivec3(wrapped_pos, params.f_bedrock_height)).r;
    float sediment_h = imageLoad(write_tex, ivec3(wrapped_pos, params.f_sediment_height)).r;
    float water_h = imageLoad(write_tex, ivec3(wrapped_pos, params.f_water_liquid_height)).r;
    return land_h + sediment_h + water_h;
}

// Computes the outward hydraulic head gradient and outflow scaling factor for a neighboring cell
void get_cell_outflow(ivec2 cell_id, ivec2 size, float flow_factor, float cell_surf, float cell_water, out vec4 out_deltas, out float out_k) {
    // Determine latitude cosine factor to scale east-west flow along converging meridians
    float norm_y = (float(cell_id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * 3.14159265359;
    float cos_lat = max(cos(latitude), 0.05);

    // Sample hydraulic surface heights of the 4 cardinal neighbors
    float n_surf = get_surface_height(cell_id + ivec2(0, -1), size);
    float s_surf = get_surface_height(cell_id + ivec2(0,  1), size);
    float e_surf = get_surface_height(cell_id + ivec2(1,  0), size);
    float w_surf = get_surface_height(cell_id + ivec2(-1, 0), size);

    // Compute downhill hydraulic head drop in each direction (positive if cell is higher than neighbor)
    out_deltas = vec4(
        max(0.0, cell_surf - n_surf),           // North
        max(0.0, cell_surf - s_surf),           // South
        max(0.0, cell_surf - e_surf) * cos_lat, // East (scaled by meridian convergence)
        max(0.0, cell_surf - w_surf) * cos_lat  // West (scaled by meridian convergence)
    );

    // Calculate total desired outflow across all four directions
    float total_delta = out_deltas.x + out_deltas.y + out_deltas.z + out_deltas.w;
    float desired_total = total_delta * flow_factor;

    // Outflow restriction factor k: scales down outflow proportionally if desired outflow exceeds cell volume
    out_k = min(1.0, cell_water / (desired_total + 1e-8));
}

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;

    if (id.x >= size.x || id.y >= size.y) return;

    // Determine latitude cosine to account for cell surface area compression near the poles
    float norm_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * 3.14159265359;
    float cos_lat = max(cos(latitude), 0.05);

    // Compute effective flow velocity factor capped by CFL stability limit
    float flow_factor = params.max_flow_rate * cfl_cap;

    // Read local cell water volume from atomic storage (authoritative volume truth)
    float self_water = float(imageLoad(atomic_tex, ivec3(id, params.a_liquid_volume)).r) / params.atomic_multiplier;
    float self_temp = imageLoad(write_tex, ivec3(id, params.f_water_temp)).r;
    float self_land = imageLoad(write_tex, ivec3(id, params.f_bedrock_height)).r + imageLoad(write_tex, ivec3(id, params.f_sediment_height)).r;
    float self_surf = self_water + self_land;

    // Read neighbor state (liquid height, temperature, and total surface elevation)
    float n_sign, s_sign, e_sign, w_sign;
    ivec2 n_id = polar_wrap(id + ivec2(0, -1), size, n_sign);
    float n_water = imageLoad(write_tex, ivec3(n_id, params.f_water_liquid_height)).r;
    float n_temp = imageLoad(write_tex, ivec3(n_id, params.f_water_temp)).r;
    float n_surf = n_water + imageLoad(write_tex, ivec3(n_id, params.f_bedrock_height)).r + imageLoad(write_tex, ivec3(n_id, params.f_sediment_height)).r;

    ivec2 s_id = polar_wrap(id + ivec2(0,  1), size, s_sign);
    float s_water = imageLoad(write_tex, ivec3(s_id, params.f_water_liquid_height)).r;
    float s_temp = imageLoad(write_tex, ivec3(s_id, params.f_water_temp)).r;
    float s_surf = s_water + imageLoad(write_tex, ivec3(s_id, params.f_bedrock_height)).r + imageLoad(write_tex, ivec3(s_id, params.f_sediment_height)).r;

    ivec2 e_id = polar_wrap(id + ivec2(1,  0), size, e_sign);
    float e_water = imageLoad(write_tex, ivec3(e_id, params.f_water_liquid_height)).r;
    float e_temp = imageLoad(write_tex, ivec3(e_id, params.f_water_temp)).r;
    float e_surf = e_water + imageLoad(write_tex, ivec3(e_id, params.f_bedrock_height)).r + imageLoad(write_tex, ivec3(e_id, params.f_sediment_height)).r;

    ivec2 w_id = polar_wrap(id + ivec2(-1,  0), size, w_sign);
    float w_water = imageLoad(write_tex, ivec3(w_id, params.f_water_liquid_height)).r;
    float w_temp = imageLoad(write_tex, ivec3(w_id, params.f_water_temp)).r;
    float w_surf = w_water + imageLoad(write_tex, ivec3(w_id, params.f_bedrock_height)).r + imageLoad(write_tex, ivec3(w_id, params.f_sediment_height)).r;

    // Determine conservative epsilon precision bounds between this cell and each neighbor
    float my_eps = get_r16f_epsilon(self_water);
    vec4 eps_nsew = vec4(
        max(my_eps, get_r16f_epsilon(n_water)),
        max(my_eps, get_r16f_epsilon(s_water)),
        max(my_eps, get_r16f_epsilon(e_water)),
        max(my_eps, get_r16f_epsilon(w_water))
    );

    // 1. COMPUTE OUTFLOW (Water draining from this cell to downhill neighbors)
    vec4 my_deltas = vec4(
        max(0.0, self_surf - n_surf),
        max(0.0, self_surf - s_surf),
        max(0.0, self_surf - e_surf) * cos_lat,
        max(0.0, self_surf - w_surf) * cos_lat
    );

    // Restrict outflow so the cell cannot lose more water than its total volume
    float my_total_delta = my_deltas.x + my_deltas.y + my_deltas.z + my_deltas.w;
    float my_k = min(1.0, self_water / (my_total_delta * flow_factor + 1e-8));

    // Quantize flow magnitudes to discrete precision bounds to preserve conservative balance
    vec4 flow_nsew = min(my_deltas * flow_factor * my_k, my_deltas * cfl_cap);
    flow_nsew = floor(flow_nsew / eps_nsew) * eps_nsew;

    float water_leaving_self = flow_nsew.x + flow_nsew.y + flow_nsew.z + flow_nsew.w;

    // Track residual thermal mass for temperature advection calculation
    float thermal_mass = max(0.0, self_water - water_leaving_self) * self_temp;

    // 2. COMPUTE INFLOW (Water flowing into this cell from uphill neighbors)
    float accumulated_water = 0.0;

    // North Neighbor: transfers its southward flow component to us
    {
        vec4 nb_deltas; float nb_k;
        get_cell_outflow(n_id, size, flow_factor, n_surf, n_water, nb_deltas, nb_k);
        float amount = min(nb_deltas.y * flow_factor * nb_k, nb_deltas.y * cfl_cap);
        float actual_flow = floor(amount / eps_nsew.x) * eps_nsew.x;
        float dist = min(float(n_id.y), float(size.y - 1 - n_id.y));
        actual_flow *= smoothstep(0.0, 10.0, dist);
        accumulated_water += actual_flow;
        thermal_mass += actual_flow * n_temp;
    }

    // South Neighbor: transfers its northward flow component to us
    {
        vec4 nb_deltas; float nb_k;
        get_cell_outflow(s_id, size, flow_factor, s_surf, s_water, nb_deltas, nb_k);
        float amount = min(nb_deltas.x * flow_factor * nb_k, nb_deltas.x * cfl_cap);
        float actual_flow = floor(amount / eps_nsew.y) * eps_nsew.y;
        float dist = min(float(s_id.y), float(size.y - 1 - s_id.y));
        actual_flow *= smoothstep(0.0, 10.0, dist);
        accumulated_water += actual_flow;
        thermal_mass += actual_flow * s_temp;
    }

    // East Neighbor: transfers its westward flow component to us
    {
        vec4 nb_deltas; float nb_k;
        get_cell_outflow(e_id, size, flow_factor, e_surf, e_water, nb_deltas, nb_k);
        float amount = min(nb_deltas.w * flow_factor * nb_k, nb_deltas.w * cfl_cap);
        float actual_flow = floor(amount / eps_nsew.z) * eps_nsew.z;
        float dist = min(float(e_id.y), float(size.y - 1 - e_id.y));
        actual_flow *= smoothstep(0.0, 10.0, dist);
        accumulated_water += actual_flow;
        thermal_mass += actual_flow * e_temp;
    }

    // West Neighbor: transfers its eastward flow component to us
    {
        vec4 nb_deltas; float nb_k;
        get_cell_outflow(w_id, size, flow_factor, w_surf, w_water, nb_deltas, nb_k);
        float amount = min(nb_deltas.z * flow_factor * nb_k, nb_deltas.z * cfl_cap);
        float actual_flow = floor(amount / eps_nsew.w) * eps_nsew.w;
        float dist = min(float(w_id.y), float(size.y - 1 - w_id.y));
        actual_flow *= smoothstep(0.0, 10.0, dist);
        accumulated_water += actual_flow;
        thermal_mass += actual_flow * w_temp;
    }

    // 3. APPLY NET WATER BALANCE AND ADVECTION
    float final_water = self_water + accumulated_water - water_leaving_self;
    float final_temp = final_water > 0.0 ? (thermal_mass / final_water) : 0.0;

    // Compute velocity and diagnostic metrics:
    // net_flow: directional vector of liquid momentum (East minus West, South minus North)
    // divergence: net liquid loss (>0) or gain (<0) per cell
    // turbulence: total volume in motion across cell boundaries
    vec2 net_flow = vec2(flow_nsew.z - flow_nsew.w, flow_nsew.y - flow_nsew.x);
    float divergence = water_leaving_self - accumulated_water; 
    float turbulence = water_leaving_self + accumulated_water;

    // Synchronize net fluid transfer into the atomic volume grid
    int atomic_delta = int(round((accumulated_water - water_leaving_self) * params.atomic_multiplier));
    if (atomic_delta != 0) {
        imageAtomicAdd(atomic_tex, ivec3(id, params.a_liquid_volume), uint(atomic_delta));
    }

    // Store updated water height, velocities, and diagnostics in the float texture array
    imageStore(write_tex, ivec3(id, params.f_water_liquid_height), vec4(max(0.0, final_water), 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_net_velocity_x), vec4(net_flow.x, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_net_velocity_y), vec4(net_flow.y, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_divergence), vec4(divergence, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_turbulence), vec4(turbulence, 0.0, 0.0, 0.0));
    imageStore(write_tex, ivec3(id, params.f_water_temp), vec4(final_temp, 0.0, 0.0, 0.0));

    // Bootstrap ocean salinity: Submerged marine cells receive standard oceanic salinity
    // (0.875 equivalent to ~35 ppt), whereas dry land remains at 0.
    const float MARINE_SALINITY = 0.875;
    uint salinity_val = uint(MARINE_SALINITY * params.atomic_multiplier);
    imageStore(atomic_tex, ivec3(id, params.a_salinity), uvec4(step(0.0, final_water) * salinity_val, 0u, 0u, 0u));
}


