#[compute]
#version 450

// =============================================================================
// ICE FREEZING GENERATOR
// Post-processing pass that simulates the phase change of liquid water into ice in sub-zero climates.
// Physical units: Water and ice depths in hectometers (1.0 = 100 meters depth), temperatures in °C.
// Bindings: Reads air and ground temperatures from write_tex (Set 0, Binding 0);
//           Modifies liquid height and ice height in write_tex (Set 0, Binding 0);
//           Updates liquid volume and ice volume in atomic_tex (Set 0, Binding 2).
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
    int f_water_ice_height;
    int f_air_temp;
    int f_ground_temp;

    int a_atomic_liquid; // Index of liquid water volume layer in atomic texture array
    int a_atomic_ice;    // Index of ice volume layer in atomic texture array

    float total_freeze_temp;  // Temperature at which maximum freezing rate occurs (e.g., -40.0 °C)
    float total_freeze_curve; // Non-linear exponent modeling thermal insulation of growing ice sheets (e.g., 0.58)
    float max_ice_thickness;  // Maximum thermodynamic ice sheet thickness cap in hectometers (e.g., 5.0 = 500m)
    float atomic_multiplier;  // Scale factor converting physical float units to fixed-point uint (e.g., 100.0)
} params; 

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 size = imageSize(write_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    // Read surface atmospheric temperature and ground temperature in °C
    float air_temp = imageLoad(write_tex, ivec3(id.xy, params.f_air_temp)).r;
    float ground_temp = imageLoad(write_tex, ivec3(id.xy, params.f_ground_temp)).r;
    
    // Average air and ground temperatures to find boundary interface temperature
    float avg_temp = (air_temp + ground_temp) * 0.5;

    // Check whether the interface temperature is below the 0°C freezing point
    float is_freezing = 1.0 - step(0.0, avg_temp);
    
    // Calculate freezing intensity proportional to sub-zero temperature depression,
    // applying the insulation power curve so additional ice accretion slows as the ice sheet thickens
    float freeze_intensity = clamp(avg_temp / params.total_freeze_temp, 0.0, 1.0);
    freeze_intensity = pow(freeze_intensity, params.total_freeze_curve);
    
    // Invalidate freezing intensity if above freezing temperature
    freeze_intensity *= is_freezing;

    if (freeze_intensity > 0.0) {
        // Sample current standing surface water depth in hectometers
        float liquid_water = imageLoad(write_tex, ivec3(id.xy, params.f_water_liquid_height)).r;
        
        if (liquid_water > 0.0) {
            // Determine the equilibrium ice depth demanded by the local temperature
            float desired_ice = freeze_intensity * params.max_ice_thickness;
            
            // Limit conversion so we never freeze more liquid water than currently exists in the column
            float ice_to_form = min(desired_ice, liquid_water);
            
            // Deduct frozen volume from surface liquid water depth in the float cache
            imageStore(write_tex, ivec3(id.xy, params.f_water_liquid_height), vec4(liquid_water - ice_to_form, 0.0, 0.0, 0.0));
            
            // Synchronize liquid subtraction in the atomic grid with underflow protection
            uint current_atomic_liquid = imageLoad(atomic_tex, ivec3(id.xy, params.a_atomic_liquid)).r;
            uint ice_uint = uint(ice_to_form * params.atomic_multiplier);
            uint new_liquid_uint = current_atomic_liquid > ice_uint ? current_atomic_liquid - ice_uint : 0;
            imageStore(atomic_tex, ivec3(id.xy, params.a_atomic_liquid), uvec4(new_liquid_uint, 0, 0, 0));
            
            // Add newly frozen water mass to the atomic ice volume grid
            imageAtomicAdd(atomic_tex, ivec3(id.xy, params.a_atomic_ice), ice_uint);
            
            // Add frozen depth to the ice thickness layer in the float cache
            float current_ice_float = imageLoad(write_tex, ivec3(id.xy, params.f_water_ice_height)).r;
            imageStore(write_tex, ivec3(id.xy, params.f_water_ice_height), vec4(current_ice_float + ice_to_form, 0.0, 0.0, 0.0));
        }
    }
}

