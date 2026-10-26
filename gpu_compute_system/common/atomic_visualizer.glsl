#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// === BINDINGS ===
// Binding 2: Atomic Grid Read (r32ui)
// Binding 5: Atomic Visual Texture Write (r16f)
layout(r32ui, set = 0, binding = 2) restrict readonly uniform uimage2DArray atomic_tex;
layout(r16f, set = 0, binding = 5) restrict writeonly uniform image2DArray atomic_vis_tex;

layout(push_constant) uniform Params {
    float deltaTime;              // Offset 0: Auto-injected by LayerSimulator; requires a dummy float push constant in LayerGenerator.
    float atomic_multiplier;      // Offset 4: Standard atomic multiplier (e.g. 100.0 from WorldConfig)
    float flora_atomic_multiplier;// Offset 8: Flora atomic multiplier (e.g. 1000000.0 from WorldConfig)
    int flora_layer_start;        // Offset 12: First flora atomic layer index
    int flora_layer_end;          // Offset 16: Last flora atomic layer index
    int action_key_layer;         // Offset 20: ACTION_KEY bitmask layer index (-1 = disabled)
    int biome_type_layer;         // Offset 24: BIOME_TYPE packed-texel layer index (-1 = disabled)
} params;

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    ivec3 size = imageSize(atomic_tex);
    if (id.x >= size.x || id.y >= size.y) return;

    for (int z = 0; z < size.z; z++) {
        uint raw_val = imageLoad(atomic_tex, ivec3(id, z)).r;

        // ACTION_KEY bitmask layers store presence bits, not magnitudes — dividing by a
        // multiplier would produce garbage. Debug convention (spell POC): ANY presence
        // bit renders at FULL brightness — one placed spell should be an unmistakable
        // white cell, not a 1/32-grey sliver.
        if (z == params.action_key_layer) {
            float bits = float(raw_val != 0u);
            imageStore(atomic_vis_tex, ivec3(id, z), vec4(bits, 0.0, 0.0, 0.0));
            continue;
        }

        // BIOME_TYPE is a packed categorical texel (low byte = biome ID, upper
        // 24 bits = attribution), never a multiplier-scaled quantity. Raw
        // pass-through decode: biome byte / 255.0 — no multiplier division, no
        // [0,1] safety clamp (a valid ID is already <= 255) (plan §7.3).
        if (z == params.biome_type_layer) {
            float biome_id = float(raw_val & 0xFFu) / 255.0;
            imageStore(atomic_vis_tex, ivec3(id, z), vec4(biome_id, 0.0, 0.0, 0.0));
            continue;
        }

        float mult = params.atomic_multiplier;
        if (params.flora_layer_start >= 0 && z >= params.flora_layer_start && z <= params.flora_layer_end) {
            mult = params.flora_atomic_multiplier;
        }
        if (mult <= 0.0) {
            mult = 1.0;
        }

        float norm_val = float(raw_val) / mult;
        norm_val = clamp(norm_val, 0.0, 1.0); // Safety clamp to prevent 10,000.0x values
        imageStore(atomic_vis_tex, ivec3(id, z), vec4(norm_val, 0.0, 0.0, 0.0));
    }
}
