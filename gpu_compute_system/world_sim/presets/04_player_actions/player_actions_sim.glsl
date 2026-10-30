#[compute]
#version 450

// =============================================================================
// PLAYER ACTIONS SIMULATION
// Compute pass that routes discrete player click actions and spell invocations to the world grid.
// Physical units: Bitmask encoding of spell placement/dispel, unit feedback counters.
// Bindings: Writes spell presence bitmasks and click feedback counters to atomic_tex (Set 0, Binding 2).
// =============================================================================

// Explicit 8x8 workgroup size matching the simulation runner dispatch geometry
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

    // Atomic storage layer indices
    int a_action_key; // Index of action key bitmask layer in atomic texture array
    int a_feedback;   // Index of click feedback counter layer in atomic texture array

    // Player action payload:
    // Transmitted from CPU on click events; ActionKey resets to 0 when no action occurs
    ivec2 cell;         // Discrete grid coordinate clicked by the player
    vec2  uv;           // Continuous normalized UV coordinate under the cursor [0, 1]
    int   action_key;   // Bit pattern representing the action: (1u << slot) for placement,
                        // target bit for dispel, or 0xFFFFFFFF to clear all spells.
    float action_value; // Spell cost / intent: positive values place spells; negative values dispel
} params;

void main() {
    // Determine 2D coordinate for this compute thread within the world grid
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(write_tex).xy;
    if (id.x >= size.x || id.y >= size.y) return;

    // Evaluate single-cell targeting: only the clicked coordinate executes the action
    ivec2 cell = params.cell;
    uint is_target  = uint(id.x == cell.x) * uint(id.y == cell.y);

    // Reinterpret int32 to uint32 to preserve high bits (e.g., slot 31 or wipe-all 0xFFFFFFFF)
    uint action_bits = uint(params.action_key);
    uint has_action = uint(action_bits != 0u);
    uint do_place   = is_target * has_action * uint(params.action_value >= 0.0);
    uint do_wipe    = is_target * has_action * uint(params.action_value <  0.0);

    // 1. ACTION_KEY: bitmask encoding active spells on each cell
    // - Placement uses imageAtomicOr to set the spell's bit idempotently
    // - Removal uses imageAtomicAnd with inverted bitmask to clear the targeted spell bit
    imageAtomicOr(atomic_tex, ivec3(id, params.a_action_key), action_bits & do_place);
    imageAtomicAnd(atomic_tex, ivec3(id, params.a_action_key), ~(action_bits & do_wipe));

    // 2. FEEDBACK: monotonic click counter incremented on the target cell for audio/visual response
    uint feedback_amount = is_target * has_action * 1u;
    imageAtomicAdd(atomic_tex, ivec3(id, params.a_feedback), feedback_amount);
}
