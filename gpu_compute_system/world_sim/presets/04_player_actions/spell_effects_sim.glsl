#[compute]
#version 450

// =============================================================================
// SPELL EFFECTS SIMULATION
// Compute pass that mirrors active player spell presences into continuous physical simulation source fields.
// Physical units: Physical source magnitude scaled by atomic multiplier.
// Bindings: Reads spell presence bitmask from atomic_tex (Set 0, Binding 2);
//           Reads spell definitions from SpellBook SSBO (Set 0, Binding 10);
//           Writes continuous source magnitude to dedicated atomic layer in atomic_tex (Set 0, Binding 2).
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

// Binding 10: SpellBook SSBO
// Read-only structured buffer uploaded from CPU containing spell parameters.
// Struct members must adhere to std430 32-byte alignment with explicit padding fields.
struct SpellDefinition {
    uint  spell_id;    // Offset 0: bit index of the spell (0..31)
    uint  effect_type; // Offset 4: effect enumeration type (0 = Geothermal source)
    float magnitude;   // Offset 8: source flux intensity
    float radius;      // Offset 12: area-of-effect radius in grid cells
    float duration;    // Offset 16: lifetime in seconds (-1.0 for permanent until dispelled)
    uint  _pad0;       // Offset 20: explicit padding field
    uint  _pad1;       // Offset 24: explicit padding field
    uint  _pad2;       // Offset 28: explicit padding field
}; // Total stride = 32 bytes
layout(std430, set = 0, binding = 10) restrict readonly buffer SpellBook {
    SpellDefinition spells[];
} spellbook;

// Effect type enumerations matching PlayerSpell configuration
const uint EFFECT_GEOTHERMAL_SOURCE = 0u;
const uint SPELL_BIT_GEOTHERMAL     = 1u; // Bitmask for geothermal spell slot (1u << 0)

layout(push_constant) uniform Params {
    float deltaTime; // Time step duration in seconds

    // Atomic storage layer indices
    int a_action_key;       // Index of action key bitmask layer in atomic texture array
    int a_spell_geothermal; // Index of spell geothermal source layer in atomic texture array

    float atomic_multiplier; // Scale factor converting physical float units to fixed-point uint
} params;

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Read active spell presence bitmask for this cell
    uint mask = imageLoad(atomic_tex, ivec3(id, params.a_action_key)).r;

    // Mirror geothermal spell presence: when the bit is set, write the configured flux magnitude;
    // when dispelled or absent, write zero to clear the source
    uint has_geo = uint((mask & SPELL_BIT_GEOTHERMAL) != 0u);
    SpellDefinition sp = spellbook.spells[0];
    uint is_geo_effect = uint(sp.effect_type == EFFECT_GEOTHERMAL_SOURCE);
    uint geo_magnitude = uint(max(sp.magnitude, 0.0) * params.atomic_multiplier) * is_geo_effect;

    uint write_value = has_geo * geo_magnitude;
    imageStore(atomic_tex, ivec3(id, params.a_spell_geothermal), uvec4(write_value, 0u, 0u, 0u));
}
