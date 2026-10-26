#[compute]
#version 450

// CRITICAL: this declaration was accidentally dropped during the bitmask rewrite and
// the shader silently compiled with an implicit local size of (1,1,1). The roster's
// 64x64 dispatch then spawned only 4096 threads covering the top-left 64x64 cells —
// clicks elsewhere never matched is_target and the write silently vanished, while
// unguarded debug probes (writes addressed by params.cell) kept working. Symptom:
// "clicks register but no atomic writes appear". ALWAYS declare local_size to match
// LayerSimulator.workgroup_size (8x8) so workgroup-count math covers the full grid.
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

// === PUSH CONSTANTS ===
// Order MUST match the push_constants_resources array in player_actions_sim.tres.
// deltaTime is always injected at offset 0 by LayerSimulator, then the array
// follows in order. The resulting 16-byte-aligned layout (validated against
// LayerSimulator.cache_push_constants_layout) is:
//   float deltaTime      @ offset 0   (4 bytes)
//   int   a_action_key   @ offset 4   (4 bytes)  -- PushConstant_SimLayer_Atomic (ACTION_KEY)
//   int   a_feedback     @ offset 8   (4 bytes)  -- PushConstant_SimLayer_Atomic (FEEDBACK)
//   ivec2 cell           @ offset 16  (8 bytes)  -- PushConstant_PlayerAction (Cell)  [padded 12->16]
//   vec2  uv             @ offset 24  (8 bytes)  -- PushConstant_PlayerAction (UV)
//   int   action_key     @ offset 32  (4 bytes)  -- PushConstant_PlayerAction (ActionKey)
//   float action_value   @ offset 36  (4 bytes)  -- PushConstant_PlayerAction (ActionValue)
// Total: 48 bytes (padded from 40 to a 16-byte multiple; under the 128-byte Vulkan limit).
layout(push_constant) uniform Params {
    float deltaTime;

    // --- AUTO-INJECTED LAYER INDICES ---
    int a_action_key;   // PLAYER_ACTIONS atomic sub-layer 0 (ACTION_KEY)
    int a_feedback;     // PLAYER_ACTIONS atomic sub-layer 2 (FEEDBACK)

    // --- PLAYER ACTION PAYLOAD (relayed by PushConstant_PlayerAction) ---
    // Cached for exactly ONE dispatch frame after a click, then ActionKey reverts
    // to 0 ("no action") on subsequent frames. See push_constant_player_action.gd.
    ivec2 cell;         // PlayerAction.Cell        - clicked discrete grid cell
    vec2  uv;           // PlayerAction.UV          - equirectangular [0,1]^2 UV under cursor
    int   action_key;   // PlayerAction.ActionKey   - action bit pattern: 1u << slot for
                        //                           placement, the target's bit for selective
                        //                           dispel, or 0xFFFFFFFF (wipe all). The wire
                        //                           is int32 (encode_s32), so high-bit patterns
                        //                           (slot 31, wipe-all) arrive NEGATIVE —
                        //                           reinterpreted as uint below.
    float action_value; // PlayerAction.ActionValue - spell cost; sign carries place (>=0)
                        //                           vs. wipe (<0); magnitude is the cost
} params;

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Player action is a discrete single-cell event relayed from the CPU each frame.
    // Each thread targets its OWN cell, complying with the "Gather/Scatter, NEVER Push"
    // rule. The bit pattern on the wire is derived by PlayerSpell.get_action_bit_pattern()
    // (1u << slot_index) so 0 unambiguously means "no click this frame".

    ivec2 cell = params.cell;
    uint is_target  = uint(id.x == cell.x) * uint(id.y == cell.y);
    // int32 -> uint32 reinterpret: slot 31 (0x80000000) and wipe-all (0xFFFFFFFF)
    // are negative int32 on the wire and must not be clamped or zeroed.
    uint action_bits = uint(params.action_key);
    uint has_action = uint(action_bits != 0u);
    uint do_place   = is_target * has_action * uint(params.action_value >= 0.0);
    uint do_wipe    = is_target * has_action * uint(params.action_value <  0.0);

    // 1. ACTION_KEY — bitmask of spells present on the cell (presence-only; magnitude
    //    lives in the SpellBook SSBO, binding 10). Branchless place/wipe:
    //    - place:  imageAtomicOr(bits)  — idempotent; re-clicking never mutates identity
    //      (the reason atomicAdd was rejected: 100 + 100 = 200 could decode as a
    //      different spell).
    //    - wipe:   imageAtomicAnd(~bits) — selective dispel clears the target's bit;
    //      a wipe-all tool sends 0xFFFFFFFF and clears every bit at once.
    //    Non-target cells are never written: the bitmask persists untouched across frames.
    //    (The AND mask is ~(bits & do_wipe): wiping cells get ~bits, all others get
    //    ~0 = 0xFFFFFFFF, a preserve-everything no-op — never a bare zero.)
    imageAtomicOr(atomic_tex, ivec3(id, params.a_action_key), action_bits & do_place);
    imageAtomicAnd(atomic_tex, ivec3(id, params.a_action_key), ~(action_bits & do_wipe));

    // 2. FEEDBACK — atomicAdd +1 at the clicked cell (persistent accumulating click
    //    counter). atomicAdd is correct here because FEEDBACK is a monotonic counter,
    //    not an identity: accumulating across clicks is the desired behaviour. This
    //    also makes the write path VISIBLE in the atomic visualizer (binding 5).
    uint feedback_amount = is_target * has_action * 1u;
    imageAtomicAdd(atomic_tex, ivec3(id, params.a_feedback), feedback_amount);
}
