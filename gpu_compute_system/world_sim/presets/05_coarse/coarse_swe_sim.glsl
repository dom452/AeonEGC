#[compute]
#version 450

// =============================================================================
// COARSE SWE ATMOSPHERE SIMULATION
// Compute pass solving coupled 2-layer shallow water equations on a 64x64 coarse planetary grid.
// Physical units: Column heights h (dimensionless, reference 0.5 per layer, 1.0 total),
//                wind velocities u, v in grid cells per second, temperature in °C.
// Bindings: Reads previous coarse states from coarse_read_tex (Set 0, Binding 7);
//           Writes updated coarse dynamic fields to coarse_write_tex (Set 0, Binding 6).
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

    // Coarse layer indices (9-layer layout)
    int c_h_upper;      // Index of upper-layer column height layer (Stratosphere)
    int c_wind_upper_x; // Index of upper-layer eastward velocity layer (Jet stream u1)
    int c_wind_upper_y; // Index of upper-layer southward velocity layer (Jet stream v1)
    int c_h_lower;      // Index of lower-layer column height layer (Troposphere)
    int c_wind_lower_x; // Index of lower-layer eastward velocity layer (Surface wind u2)
    int c_wind_lower_y; // Index of lower-layer southward velocity layer (Surface wind v2)
    int c_air_temp;     // Index of downsampled air temperature layer
    int c_terrain;      // Index of downsampled mean terrain elevation layer
    int c_roughness;    // Index of sub-grid topographic roughness layer

    float swe_gravity;           // Planetary effective gravitational acceleration (e.g., 5.0)
    float coriolis_strength;     // Planetary rotation rate governing Coriolis deflection
    float swe_thermal_alpha;     // Thermal expansion column forcing coefficient
    float swe_global_mean_temp;  // Reference planetary equilibrium air temperature
    float swe_wind_friction;     // Linear atmospheric drag coefficient
    float swe_relax_strength;    // Non-linear boundary relaxation preventing runaway mass accumulation
    float orographic_drag_coeff; // Surface drag multiplier per unit of sub-grid topographic roughness
    float density_ratio;         // Density ratio of upper layer to lower layer (rho1 / rho2)
} params;

const float MINIMUM_EP = 0.0001;
const float PI = 3.14159265359;
const float MIN_COLUMN_HEIGHT = 0.05;
const float H_REF_LAYER = 0.5; // Equilibrium resting column height per layer
const float RELAX_THRESHOLD = 0.30;
const float NUMERICAL_DIFFUSION = 0.25; // Rusanov numerical dissipation scaling

// Handles cell-centered polar boundary crossover wrapping:
// Crossing over a pole reflects latitude, shifts longitude by 180°, and inverts vector direction
ivec2 polar_wrap(ivec2 pos, ivec2 size, out float sign_flip) {
    int W = size.x;
    int H = size.y;
    sign_flip = 1.0;
    if (pos.y < 0) {
        pos.y = -pos.y - 1;
        pos.x = (pos.x + W / 2) % W;
        sign_flip = -1.0;
    } else if (pos.y >= H) {
        pos.y = 2 * H - 1 - pos.y;
        pos.x = (pos.x + W / 2) % W;
        sign_flip = -1.0;
    }
    pos.x = (pos.x % W + W) % W;
    return pos;
}

// Rusanov approximate Riemann solver for shallow water conservation laws:
// Computes numerical interface flux between left (L) and right (R) states
void rusanov_flux(float hL, float huL, float hvL,
                  float hR, float huR, float hvR,
                  float g, float diff_scale, out float Fh, out float Fhu, out float Fhv) {
    float hL_safe = max(hL, 0.0);
    float hR_safe = max(hR, 0.0);

    float uL = (hL_safe > MINIMUM_EP) ? huL / hL_safe : 0.0;
    float uR = (hR_safe > MINIMUM_EP) ? huR / hR_safe : 0.0;

    // Local wave speed estimates (advection velocity + acoustic gravity wave speed)
    float cL = abs(uL) + sqrt(g * hL_safe);
    float cR = abs(uR) + sqrt(g * hR_safe);
    float cmax = max(cL, cR);

    // Left interface physical fluxes
    float FL_h  = huL;
    float FL_hu = huL * uL + 0.5 * g * hL_safe * hL_safe;
    float FL_hv = (hL_safe > MINIMUM_EP) ? huL * hvL / hL_safe : 0.0;

    // Right interface physical fluxes
    float FR_h  = huR;
    float FR_hu = huR * uR + 0.5 * g * hR_safe * hR_safe;
    float FR_hv = (hR_safe > MINIMUM_EP) ? huR * hvR / hR_safe : 0.0;

    // Rusanov numerical flux combining centered average and upwind dissipation
    Fh  = 0.5 * (FL_h  + FR_h)  - 0.5 * cmax * (hR  - hL)   * diff_scale;
    Fhu = 0.5 * (FL_hu + FR_hu) - 0.5 * cmax * (huR - huL) * diff_scale;
    Fhv = 0.5 * (FL_hv + FR_hv) - 0.5 * cmax * (hvR - hvL) * diff_scale;
}

// Audusse hydrostatic reconstruction at cell boundaries:
// Balances pressure gradient force with topographic source terms to maintain exact equilibrium at rest
void hydrostatic_reconstruct(
    float hL, float bL, float huL, float hvL,
    float hR, float bR, float huR, float hvR,
    out float hLs, out float huLs, out float hvLs,
    out float hRs, out float huRs, out float hvRs)
{
    float bstar = max(bL, bR);
    float etaL = hL + bL;
    float etaR = hR + bR;
    hLs = max(0.0, etaL - bstar);
    hRs = max(0.0, etaR - bstar);

    float uL = (hL > MINIMUM_EP) ? huL / hL : 0.0;
    float vL = (hL > MINIMUM_EP) ? hvL / hL : 0.0;
    float uR = (hR > MINIMUM_EP) ? huR / hR : 0.0;
    float vR = (hR > MINIMUM_EP) ? hvR / hR : 0.0;

    huLs = (hLs > MINIMUM_EP) ? uL * hLs : 0.0;
    hvLs = (hLs > MINIMUM_EP) ? vL * hLs : 0.0;
    huRs = (hRs > MINIMUM_EP) ? uR * hRs : 0.0;
    hvRs = (hRs > MINIMUM_EP) ? vR * hRs : 0.0;
}

// Audusse topography source term corrections ensuring well-balanced scheme
float audusse_source_left(float h, float hs, float g) {
    return 0.5 * g * (hs * hs - h * h);
}

float audusse_source_right(float h, float hs, float g) {
    return 0.5 * g * (h * h - hs * hs);
}

void main() {
    // Determine 2D coordinate for this compute thread within the coarse world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(coarse_write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Compute cell-centered latitude and spherical meridian convergence metric
    float norm_y = (float(id.y) + 0.5) / float(size.y);
    float latitude = (0.5 - norm_y) * PI;
    float cos_lat = max(cos(latitude), 0.15);
    float inv_cos = 1.0 / cos_lat;

    // 1. Fetch current cell state from coarse_read_tex (Frame N-1)
    // Upper Layer (1): Stratospheric jet stream
    float wh1 = max(imageLoad(coarse_read_tex, ivec3(id, params.c_h_upper)).r, 0.0);
    float u1  = imageLoad(coarse_read_tex, ivec3(id, params.c_wind_upper_x)).r;
    float v1  = imageLoad(coarse_read_tex, ivec3(id, params.c_wind_upper_y)).r;
    float whu1 = u1 * wh1;
    float whv1 = v1 * wh1;

    // Lower Layer (2): Tropospheric surface circulation
    float wh2 = max(imageLoad(coarse_read_tex, ivec3(id, params.c_h_lower)).r, 0.0);
    float u2  = imageLoad(coarse_read_tex, ivec3(id, params.c_wind_lower_x)).r;
    float v2  = imageLoad(coarse_read_tex, ivec3(id, params.c_wind_lower_y)).r;
    float whu2 = u2 * wh2;
    float whv2 = v2 * wh2;

    // Terrain elevation and temperature
    float b = imageLoad(coarse_read_tex, ivec3(id, params.c_terrain)).r;
    float air_temp = imageLoad(coarse_read_tex, ivec3(id, params.c_air_temp)).r;
    float roughness = imageLoad(coarse_read_tex, ivec3(id, params.c_roughness)).r;

    // Dynamic bed elevations:
    // Lower layer rests on physical terrain b
    float b2 = b;
    // Upper layer rides on top of lower layer column: dynamic interface b1 = h2 + b
    float b1 = wh2 + b;

    // 2. Sample 4 cardinal neighbors with polar boundary wrapping
    float n_flip, s_flip, e_flip, w_flip;
    ivec2 n_id = polar_wrap(id + ivec2(0, -1), size, n_flip);
    ivec2 s_id = polar_wrap(id + ivec2(0,  1), size, s_flip);
    ivec2 e_id = polar_wrap(id + ivec2(1,  0), size, e_flip);
    ivec2 w_id = polar_wrap(id + ivec2(-1, 0), size, w_flip);

    // Neighbor terrain
    float bN = imageLoad(coarse_read_tex, ivec3(n_id, params.c_terrain)).r;
    float bS = imageLoad(coarse_read_tex, ivec3(s_id, params.c_terrain)).r;
    float bE = imageLoad(coarse_read_tex, ivec3(e_id, params.c_terrain)).r;
    float bW = imageLoad(coarse_read_tex, ivec3(w_id, params.c_terrain)).r;

    // Neighbor Upper Layer (1) state
    float h1N = max(imageLoad(coarse_read_tex, ivec3(n_id, params.c_h_upper)).r, 0.0);
    float h1S = max(imageLoad(coarse_read_tex, ivec3(s_id, params.c_h_upper)).r, 0.0);
    float h1E = max(imageLoad(coarse_read_tex, ivec3(e_id, params.c_h_upper)).r, 0.0);
    float h1W = max(imageLoad(coarse_read_tex, ivec3(w_id, params.c_h_upper)).r, 0.0);

    float u1N = imageLoad(coarse_read_tex, ivec3(n_id, params.c_wind_upper_x)).r * n_flip;
    float v1N = imageLoad(coarse_read_tex, ivec3(n_id, params.c_wind_upper_y)).r * n_flip;
    float u1S = imageLoad(coarse_read_tex, ivec3(s_id, params.c_wind_upper_x)).r * s_flip;
    float v1S = imageLoad(coarse_read_tex, ivec3(s_id, params.c_wind_upper_y)).r * s_flip;
    float u1E = imageLoad(coarse_read_tex, ivec3(e_id, params.c_wind_upper_x)).r * e_flip;
    float v1E = imageLoad(coarse_read_tex, ivec3(e_id, params.c_wind_upper_y)).r * e_flip;
    float u1W = imageLoad(coarse_read_tex, ivec3(w_id, params.c_wind_upper_x)).r * w_flip;
    float v1W = imageLoad(coarse_read_tex, ivec3(w_id, params.c_wind_upper_y)).r * w_flip;

    float hu1N = u1N * h1N, hv1N = v1N * h1N;
    float hu1S = u1S * h1S, hv1S = v1S * h1S;
    float hu1E = u1E * h1E, hv1E = v1E * h1E;
    float hu1W = u1W * h1W, hv1W = v1W * h1W;

    // Neighbor Lower Layer (2) state
    float h2N = max(imageLoad(coarse_read_tex, ivec3(n_id, params.c_h_lower)).r, 0.0);
    float h2S = max(imageLoad(coarse_read_tex, ivec3(s_id, params.c_h_lower)).r, 0.0);
    float h2E = max(imageLoad(coarse_read_tex, ivec3(e_id, params.c_h_lower)).r, 0.0);
    float h2W = max(imageLoad(coarse_read_tex, ivec3(w_id, params.c_h_lower)).r, 0.0);

    float u2N = imageLoad(coarse_read_tex, ivec3(n_id, params.c_wind_lower_x)).r * n_flip;
    float v2N = imageLoad(coarse_read_tex, ivec3(n_id, params.c_wind_lower_y)).r * n_flip;
    float u2S = imageLoad(coarse_read_tex, ivec3(s_id, params.c_wind_lower_x)).r * s_flip;
    float v2S = imageLoad(coarse_read_tex, ivec3(s_id, params.c_wind_lower_y)).r * s_flip;
    float u2E = imageLoad(coarse_read_tex, ivec3(e_id, params.c_wind_lower_x)).r * e_flip;
    float v2E = imageLoad(coarse_read_tex, ivec3(e_id, params.c_wind_lower_y)).r * e_flip;
    float u2W = imageLoad(coarse_read_tex, ivec3(w_id, params.c_wind_lower_x)).r * w_flip;
    float v2W = imageLoad(coarse_read_tex, ivec3(w_id, params.c_wind_lower_y)).r * w_flip;

    float hu2N = u2N * h2N, hv2N = v2N * h2N;
    float hu2S = u2S * h2S, hv2S = v2S * h2S;
    float hu2E = u2E * h2E, hv2E = v2E * h2E;
    float hu2W = u2W * h2W, hv2W = v2W * h2W;

    // Dynamic bed elevations for Upper Layer: b1 = h2 + b
    float b1N = h2N + bN;
    float b1S = h2S + bS;
    float b1E = h2E + bE;
    float b1W = h2W + bW;

    float g = params.swe_gravity;
    float r = clamp(params.density_ratio, 0.1, 0.95);

    // 3. Compute interface fluxes and source terms for Upper Layer (Stratosphere)
    float hLs_E1, huLs_E1, hvLs_E1, hRs_E1, huRs_E1, hvRs_E1;
    hydrostatic_reconstruct(wh1, b1, whu1, whv1, h1E, b1E, hu1E, hv1E,
                            hLs_E1, huLs_E1, hvLs_E1, hRs_E1, huRs_E1, hvRs_E1);
    float FE_h1, FE_hu1, FE_hv1;
    rusanov_flux(hLs_E1, huLs_E1, hvLs_E1, hRs_E1, huRs_E1, hvRs_E1, g, NUMERICAL_DIFFUSION, FE_h1, FE_hu1, FE_hv1);
    float S_E1 = audusse_source_left(wh1, hLs_E1, g);

    float hLs_W1, huLs_W1, hvLs_W1, hRs_W1, huRs_W1, hvRs_W1;
    hydrostatic_reconstruct(h1W, b1W, hu1W, hv1W, wh1, b1, whu1, whv1,
                            hLs_W1, huLs_W1, hvLs_W1, hRs_W1, huRs_W1, hvRs_W1);
    float FW_h1, FW_hu1, FW_hv1;
    rusanov_flux(hLs_W1, huLs_W1, hvLs_W1, hRs_W1, huRs_W1, hvRs_W1, g, NUMERICAL_DIFFUSION, FW_h1, FW_hu1, FW_hv1);
    float S_W1 = audusse_source_right(wh1, hRs_W1, g);

    float hLs_N1, hvLs_N1, huLs_N1, hRs_N1, hvRs_N1, huRs_N1;
    hydrostatic_reconstruct(h1N, b1N, hv1N, hu1N, wh1, b1, whv1, whu1,
                            hLs_N1, hvLs_N1, huLs_N1, hRs_N1, hvRs_N1, huRs_N1);
    float GN_h1, GN_hv1, GN_hu1;
    rusanov_flux(hLs_N1, hvLs_N1, huLs_N1, hRs_N1, hvRs_N1, huRs_N1, g, NUMERICAL_DIFFUSION, GN_h1, GN_hv1, GN_hu1);
    float S_N1 = audusse_source_right(wh1, hRs_N1, g);

    float hLs_S1, hvLs_S1, huLs_S1, hRs_S1, hvRs_S1, huRs_S1;
    hydrostatic_reconstruct(wh1, b1, whv1, whu1, h1S, b1S, hv1S, hu1S,
                            hLs_S1, hvLs_S1, huLs_S1, hRs_S1, hvRs_S1, huRs_S1);
    float GS_h1, GS_hv1, GS_hu1;
    rusanov_flux(hLs_S1, hvLs_S1, huLs_S1, hRs_S1, hvRs_S1, huRs_S1, g, NUMERICAL_DIFFUSION, GS_h1, GS_hv1, GS_hu1);
    float S_S1 = audusse_source_left(wh1, hLs_S1, g);

    // 4. Compute interface fluxes and source terms for Lower Layer (Troposphere)
    float hLs_E2, huLs_E2, hvLs_E2, hRs_E2, huRs_E2, hvRs_E2;
    hydrostatic_reconstruct(wh2, b, whu2, whv2, h2E, bE, hu2E, hv2E,
                            hLs_E2, huLs_E2, hvLs_E2, hRs_E2, huRs_E2, hvRs_E2);
    float FE_h2, FE_hu2, FE_hv2;
    rusanov_flux(hLs_E2, huLs_E2, hvLs_E2, hRs_E2, huRs_E2, hvRs_E2, g, NUMERICAL_DIFFUSION, FE_h2, FE_hu2, FE_hv2);
    float S_E2 = audusse_source_left(wh2, hLs_E2, g);

    float hLs_W2, huLs_W2, hvLs_W2, hRs_W2, huRs_W2, hvRs_W2;
    hydrostatic_reconstruct(h2W, bW, hu2W, hv2W, wh2, b, whu2, whv2,
                            hLs_W2, huLs_W2, hvLs_W2, hRs_W2, huRs_W2, hvRs_W2);
    float FW_h2, FW_hu2, FW_hv2;
    rusanov_flux(hLs_W2, huLs_W2, hvLs_W2, hRs_W2, huRs_W2, hvRs_W2, g, NUMERICAL_DIFFUSION, FW_h2, FW_hu2, FW_hv2);
    float S_W2 = audusse_source_right(wh2, hRs_W2, g);

    float hLs_N2, hvLs_N2, huLs_N2, hRs_N2, hvRs_N2, huRs_N2;
    hydrostatic_reconstruct(h2N, bN, hv2N, hu2N, wh2, b, whv2, whu2,
                            hLs_N2, hvLs_N2, huLs_N2, hRs_N2, hvRs_N2, huRs_N2);
    float GN_h2, GN_hv2, GN_hu2;
    rusanov_flux(hLs_N2, hvLs_N2, huLs_N2, hRs_N2, hvRs_N2, huRs_N2, g, NUMERICAL_DIFFUSION, GN_h2, GN_hv2, GN_hu2);
    float S_N2 = audusse_source_right(wh2, hRs_N2, g);

    float hLs_S2, hvLs_S2, huLs_S2, hRs_S2, hvRs_S2, huRs_S2;
    hydrostatic_reconstruct(wh2, b, whv2, whu2, h2S, bS, hv2S, hu2S,
                            hLs_S2, hvLs_S2, huLs_S2, hRs_S2, hvRs_S2, huRs_S2);
    float GS_h2, GS_hv2, GS_hu2;
    rusanov_flux(hLs_S2, hvLs_S2, huLs_S2, hRs_S2, hvRs_S2, huRs_S2, g, NUMERICAL_DIFFUSION, GS_h2, GS_hv2, GS_hu2);
    float S_S2 = audusse_source_left(wh2, hLs_S2, g);

    // 5. Integrate time derivatives
    float dt = params.deltaTime;

    // Flux divergence updates for Upper Layer
    float dh1  = -( (FE_h1  - FW_h1)  * inv_cos + (GS_h1  - GN_h1)  ) * dt;
    float dhu1 = -( (FE_hu1 - FW_hu1) * inv_cos + (GS_hu1 - GN_hu1) ) * dt + (S_E1 + S_W1) * inv_cos * dt;
    float dhv1 = -( (FE_hv1 - FW_hv1) * inv_cos + (GS_hv1 - GN_hv1) ) * dt + (S_N1 + S_S1) * dt;

    // Flux divergence updates for Lower Layer
    float dh2  = -( (FE_h2  - FW_h2)  * inv_cos + (GS_h2  - GN_h2)  ) * dt;
    float dhu2 = -( (FE_hu2 - FW_hu2) * inv_cos + (GS_hu2 - GN_hu2) ) * dt + (S_E2 + S_W2) * inv_cos * dt;
    float dhv2 = -( (FE_hv2 - FW_hv2) * inv_cos + (GS_hv2 - GN_hv2) ) * dt + (S_N2 + S_S2) * dt;

    // Baroclinic pressure coupling: upper layer pressure gradient exerts force onto the lower layer
    // P_upper_on_lower = -g * (rho_upper/rho_lower) * h2 * grad(h1)
    float grad_h1_x = 0.5 * (h1E - h1W) * inv_cos;
    float grad_h1_y = 0.5 * (h1S - h1N);
    dhu2 += -g * r * wh2 * grad_h1_x * dt;
    dhv2 += -g * r * wh2 * grad_h1_y * dt;

    // Thermal expansion forcing: warm surface air expands the lower atmospheric column
    dh2 += params.swe_thermal_alpha * (air_temp - params.swe_global_mean_temp) * dt;

    // Non-linear boundary relaxation preventing mass runaway
    float h1_dev = wh1 - H_REF_LAYER;
    float excess1 = max(0.0, abs(h1_dev) - RELAX_THRESHOLD);
    dh1 -= sign(h1_dev) * params.swe_relax_strength * excess1 * excess1 * dt;

    float h2_dev = wh2 - H_REF_LAYER;
    float excess2 = max(0.0, abs(h2_dev) - RELAX_THRESHOLD);
    dh2 -= sign(h2_dev) * params.swe_relax_strength * excess2 * excess2 * dt;

    // Apply momentum updates
    whu1 += dhu1;
    whv1 += dhv1;
    whu2 += dhu2;
    whv2 += dhv2;

    // Enforce positive column height floors
    float h1_new = wh1 + dh1;
    if (h1_new < MIN_COLUMN_HEIGHT) {
        float scale1 = (wh1 > MINIMUM_EP) ? MIN_COLUMN_HEIGHT / wh1 : 0.0;
        whu1 *= scale1;
        whv1 *= scale1;
        wh1 = MIN_COLUMN_HEIGHT;
    } else {
        wh1 = h1_new;
    }

    float h2_new = wh2 + dh2;
    if (h2_new < MIN_COLUMN_HEIGHT) {
        float scale2 = (wh2 > MINIMUM_EP) ? MIN_COLUMN_HEIGHT / wh2 : 0.0;
        whu2 *= scale2;
        whv2 *= scale2;
        wh2 = MIN_COLUMN_HEIGHT;
    } else {
        wh2 = h2_new;
    }

    // 6. Semi-implicit Coriolis rotation matrix (conserves rotational energy)
    float f_coriolis = sin(latitude) * params.coriolis_strength;
    float fdt = f_coriolis * dt;
    float cos_f = cos(fdt);
    float sin_f = sin(fdt);

    float u1_star = (wh1 > MINIMUM_EP) ? whu1 / wh1 : 0.0;
    float v1_star = (wh1 > MINIMUM_EP) ? whv1 / wh1 : 0.0;
    whu1 = (cos_f * u1_star - sin_f * v1_star) * wh1;
    whv1 = (sin_f * u1_star + cos_f * v1_star) * wh1;

    float u2_star = (wh2 > MINIMUM_EP) ? whu2 / wh2 : 0.0;
    float v2_star = (wh2 > MINIMUM_EP) ? whv2 / wh2 : 0.0;
    whu2 = (cos_f * u2_star - sin_f * v2_star) * wh2;
    whv2 = (sin_f * u2_star + cos_f * v2_star) * wh2;

    // 7. Atmospheric friction and orographic boundary-layer drag:
    // Upper stratosphere experiences low laminar drag; lower troposphere suffers terrain roughness drag
    float fric1 = exp(-params.swe_wind_friction * 0.25 * dt);
    whu1 *= fric1;
    whv1 *= fric1;

    float eff_fric2 = params.swe_wind_friction + params.orographic_drag_coeff * roughness;
    float fric2 = exp(-eff_fric2 * dt);
    whu2 *= fric2;
    whv2 *= fric2;

    // 8. Baroclinic hyperbolicity guard & vertical shear mixing:
    // Mitigates Kelvin-Helmholtz shear instability when velocity difference exceeds internal wave speed
    float g_prime = g * (1.0 - r);
    float c_int = sqrt(max(0.0, g_prime * (wh1 * wh2) / max(wh1 + wh2, MINIMUM_EP)));
    vec2 cur_u1 = vec2(whu1 / wh1, whv1 / wh1);
    vec2 cur_u2 = vec2(whu2 / wh2, whv2 / wh2);
    vec2 du = cur_u1 - cur_u2;
    float shear = length(du);
    float max_allowed_shear = 2.0 * c_int;
    if (shear > max_allowed_shear && shear > MINIMUM_EP) {
        float mix_k = clamp((shear - max_allowed_shear) / shear, 0.0, 0.5) * 0.5;
        whu1 -= mix_k * du.x * wh1;
        whv1 -= mix_k * du.y * wh1;
        whu2 += mix_k * du.x * wh2;
        whv2 += mix_k * du.y * wh2;
    }

    // 9. Velocity sanitary bounds
    float final_u1 = (wh1 > MINIMUM_EP) ? whu1 / wh1 : 0.0;
    float final_v1 = (wh1 > MINIMUM_EP) ? whv1 / wh1 : 0.0;
    float speed1 = length(vec2(final_u1, final_v1));
    const float MAX_UPPER_SPEED = 3.5;
    if (speed1 > MAX_UPPER_SPEED && speed1 > MINIMUM_EP) {
        float clamp_ratio1 = MAX_UPPER_SPEED / speed1;
        final_u1 *= clamp_ratio1;
        final_v1 *= clamp_ratio1;
    }

    float final_u2 = (wh2 > MINIMUM_EP) ? whu2 / wh2 : 0.0;
    float final_v2 = (wh2 > MINIMUM_EP) ? whv2 / wh2 : 0.0;
    float speed2 = length(vec2(final_u2, final_v2));
    const float MAX_LOWER_SPEED = 2.0;
    if (speed2 > MAX_LOWER_SPEED && speed2 > MINIMUM_EP) {
        float clamp_ratio2 = MAX_LOWER_SPEED / speed2;
        final_u2 *= clamp_ratio2;
        final_v2 *= clamp_ratio2;
    }

    if (isnan(final_u1) || isinf(final_u1)) final_u1 = 0.0;
    if (isnan(final_v1) || isinf(final_v1)) final_v1 = 0.0;
    if (isnan(wh1) || isinf(wh1)) wh1 = H_REF_LAYER;

    if (isnan(final_u2) || isinf(final_u2)) final_u2 = 0.0;
    if (isnan(final_v2) || isinf(final_v2)) final_v2 = 0.0;
    if (isnan(wh2) || isinf(wh2)) wh2 = H_REF_LAYER;

    // 10. Store integrated states in the coarse write texture array
    imageStore(coarse_write_tex, ivec3(id, params.c_h_upper), vec4(wh1, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(id, params.c_wind_upper_x), vec4(final_u1, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(id, params.c_wind_upper_y), vec4(final_v1, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(id, params.c_h_lower), vec4(wh2, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(id, params.c_wind_lower_x), vec4(final_u2, 0.0, 0.0, 0.0));
    imageStore(coarse_write_tex, ivec3(id, params.c_wind_lower_y), vec4(final_v2, 0.0, 0.0, 0.0));
}
