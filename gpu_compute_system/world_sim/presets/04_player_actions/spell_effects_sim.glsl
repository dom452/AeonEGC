#[compute]
#version 450

// ==========================================
// SPELL EFFECTS — SOURCE MANAGER
// ==========================================
// The presence -> source mirror for placed spells. Dispatches after
// player_actions_sim each frame:
//   1. Reads the ACTION_KEY bitmask (PLAYER_ACTIONS, atomic grid) for this cell.
//   2. For each effect bit it owns (currently bit 0 = GEOTHERMAL_SOURCE), looks the
//      spell definition up in the SpellBook SSBO (binding 10, read-only) and writes
//      magnitude * atomic_multiplier into the spell's dedicated atomic sub-layer.
//   3. If the bit is NOT set, zeroes the sub-layer.
//
// The dedicated SPELL_GEOTHERMAL sub-layer (never written by WorldGen) makes the mirror
// safe: zeroing it cannot destroy the natural GEOTHERMAL baseline, and dispel works for
// free — the cleared bit simply stops refreshing the source, zeroing it next frame.
// Thermodynamics sums natural + spell geothermal (see thermodynamics_sim.glsl).
// ==========================================

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

// Binding 10: SpellBook (uses_spellbook = true, PLAYER_ACTIONS domain)
// Read-only at runtime. CPU uploads from PlayerSpell resources at load (SpellbookManager).
// NOTE (std430): the 32-byte stride only holds because _pad1/_pad2 are DECLARED —
// an all-scalar struct alone would have natural std430 stride 24 (std140 rounds to 16,
// std430 does not). Keep in sync with Helpers.SPELL_DEFINITION_BYTE_SIZE.
struct SpellDefinition {
    uint  spell_id;      // offset 0  — bit index (0..31)
    uint  effect_type;   // offset 4  — PlayerSpell.EffectType (GEOTHERMAL_SOURCE = 0)
    float magnitude;     // offset 8  — float units of the target layer
    float radius;        // offset 12 — area-of-effect in cells (POC: single cell)
    float duration;      // offset 16 — -1.0 = permanent; >0 = decays (future)
    uint  _pad0;         // offset 20 — reserved
    uint  _pad1;         // offset 24 — explicit padding (std430 stride is 24 without it)
    uint  _pad2;         // offset 28 — explicit padding
}; // 32 bytes → array stride 32
layout(std430, set = 0, binding = 10) restrict readonly buffer SpellBook {
    SpellDefinition spells[];
} spellbook;

// Effect types this pass mirrors into dedicated atomic sub-layers. Must match
// PlayerSpell.EffectType in player_spell.gd.
const uint EFFECT_GEOTHERMAL_SOURCE = 0u;
const uint SPELL_BIT_GEOTHERMAL     = 1u;   // 1u << action_key 0 (bit index == SSBO index)

// === PUSH CONSTANTS ===
// Order MUST match the push_constants_resources array in spell_effects_sim.tres.
//   float deltaTime            @ offset 0   (LayerSimulator injects at 0)
//   int   a_action_key         @ offset 4   -- PLAYER_ACTIONS atomic sub-layer 0
//   int   a_spell_geothermal   @ offset 8   -- PLAYER_ACTIONS atomic sub-layer 3
//   float atomic_multiplier    @ offset 12  -- WorldConfig.atomic_multiplier
// Total: 16 bytes (already a 16-byte multiple; under the 128-byte Vulkan limit).
layout(push_constant) uniform Params {
    float deltaTime;

    // --- AUTO-INJECTED LAYER INDICES ---
    int a_action_key;        // PLAYER_ACTIONS atomic sub-layer 0 (ACTION_KEY bitmask)
    int a_spell_geothermal;  // PLAYER_ACTIONS atomic sub-layer 3 (SPELL_GEOTHERMAL)

    // --- USER CONSTANTS ---
    float atomic_multiplier; // uint -> float conversion for ENERGY/PLAYER_ACTIONS grids
} params;

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    uint mask = imageLoad(atomic_tex, ivec3(id, params.a_action_key)).r;

    // Geothermal vent (bit 0): presence -> source mirror. While the bit is set the
    // source magnitude is refreshed every frame from the spellbook; when the bit is
    // cleared (dispel or never placed) the sub-layer is zeroed. Writing 0 to this
    // spell-exclusive layer is always safe — it never holds natural geothermal.
    uint has_geo = uint((mask & SPELL_BIT_GEOTHERMAL) != 0u);
    SpellDefinition sp = spellbook.spells[0];
    uint is_geo_effect = uint(sp.effect_type == EFFECT_GEOTHERMAL_SOURCE);
    uint geo_magnitude = uint(max(sp.magnitude, 0.0) * params.atomic_multiplier) * is_geo_effect;

    uint write_value = has_geo * geo_magnitude;
    imageStore(atomic_tex, ivec3(id, params.a_spell_geothermal), uvec4(write_value, 0u, 0u, 0u));
}
