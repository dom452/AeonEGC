#[compute]
#version 450

// Group size of 8x8 threads. This means each workgroup will process an 8x8 block of pixels in the output texture.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
// === UNIFIED SIMULATION UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f) | 1: Fine Float Read (r16f) | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)     | 4: SSBO Read (std430)     | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f)| 7: Coarse Float Read (r32f)
layout(r16f, set = 0, binding = 0) restrict uniform image2DArray write_tex;
layout(r16f, set = 0, binding = 1) restrict readonly uniform image2DArray read_tex;
layout(r32ui, set = 0, binding = 2) uniform uimage2DArray atomic_tex;

// Uncomment SSBO bindings if your simulation layer uses them:
/*
struct PopulationCluster {
	// ... (see helpers.gd for exact std430 byte-layout) ...
};
layout(std430, set = 0, binding = 3) restrict writeonly buffer SSBOWrite { PopulationCluster data[]; } ssbo_write;
layout(std430, set = 0, binding = 4) restrict readonly buffer SSBORead { PopulationCluster data[]; } ssbo_read;
*/

layout(r16f, set = 0, binding = 5) restrict writeonly uniform image2DArray atomic_vis_tex;
layout(r32f, set = 0, binding = 6) restrict uniform image2DArray coarse_write_tex;
layout(r32f, set = 0, binding = 7) restrict readonly uniform image2DArray coarse_read_tex;

// === AUXILIARY SSBO BINDINGS (opt-in via LayerSimulator @export flags) ===
// Uncomment the blocks your layer needs. The binding numbers are fixed.
// Enable the matching flag on the LayerSimulator resource in the inspector.
//
/*
// Binding 8: RETIRED. Former EventBuffer decommissioned; bindings 8/9 are FREE
// for future auxiliary SSBOs. Biome causation travels in the BIOME_TYPE texel's
// 24-bit attribution snapshot, which the CPU reads via periodic snapshot diffing.
//
// Historical contract, kept for reference (matches EVENT_DATA_BYTE_SIZE):
// struct EventData { uint source_id; uint packed_data; vec2 world_pos; };
// layout(std430, set = 0, binding = 8) restrict buffer EventBuffer {
//     uint event_count; uint _header_pad[3]; EventData events[]; } event_buffer;
*/
/*
// Binding 10: SpellBook (uses_spellbook = true, PLAYER_ACTIONS domain)
// Read-only at runtime. CPU uploads from PlayerSpell resources at load.
// NOTE (std430): std430 does NOT round struct strides up to 16 (that is the std140
// rule — GLSL 4.50 §4.4.1). An all-scalar struct has natural alignment 4 → array
// stride 24, NOT 32. SPELL_DEFINITION_BYTE_SIZE (32) only holds if _pad1/_pad2 are
// DECLARED, following the same standard as PopulationCluster (explicit padding,
// GLSL and Helpers.gd describe one real layout).
struct SpellDefinition {
    uint  spell_id;      // offset 0  — bit index (0..31)
    uint  effect_type;   // offset 4  — enum (HEAT_SOURCE, COLD_SOURCE, FERTILITY, ...)
    float magnitude;     // offset 8  — e.g. heat injected per second
    float radius;        // offset 12 — area-of-effect in cells
    float duration;      // offset 16 — -1.0 = permanent; >0 = decays
    uint  _pad0;         // offset 20 — reserved
    uint  _pad1;         // offset 24 — explicit padding (std430 stride is 24 without it)
    uint  _pad2;         // offset 28 — explicit padding
}; // 32 bytes → array stride 32 (matches SPELL_DEFINITION_BYTE_SIZE)
layout(std430, set = 0, binding = 10) restrict readonly buffer SpellBook {
    SpellDefinition spells[];
} spellbook;
*/
/*
// Binding 11: ArchetypeLimits (uses_archetype_limits = true, FAUNA domain)
// Read-only at runtime. CPU uploads from FaunaArchetype resources at load.
// struct SpeciesArchetype { ... };  // layout TBD — see helpers.gd SPECIES_ARCHETYPE_BYTE_SIZE
// layout(std430, set = 0, binding = 11) restrict readonly buffer ArchetypeLimits {
//     SpeciesArchetype archetypes[];
// } archetype_limits;
*/
/*
// Binding 12: ImpactCurrency (uses_impact_currency = true)
// GPU writes via atomicAdd; CPU reads async and swaps.
// Double-buffered ping-pong: the CPU extracts the ACTIVE half, swaps immediately
// via GpuWorldState.swap_impact_currency(), then zeroes the extracted half in the
// callback; GPU atomicAdds always land in the active half, so no add is destroyed
// by the CPU reset window. Agents aggregate per-workgroup via `shared` memory and
// issue ONE atomicAdd per workgroup (never per-thread).
// (never per-thread).
layout(std430, set = 0, binding = 12) restrict buffer ImpactCurrency {
    uint total_currency;       // offset 0 — atomicAdd target
    uint events_this_cycle;    // offset 4
} impact_currency;
*/

layout(push_constant) uniform Params {
	float deltaTime; 

	// PUSH CONSTANTS
	// Explicit push constant values (including layer indices) defined in push_constants_resources in your Godot Resource.
	// Add PushConstant_SimLayer, PushConstant_SimLayer_Atomic, etc. to pass layer indices to GLSL.
	// variant my_custom_param;
	
} params; 

void main() {
	// get the global invocation ID and check if it's within the bounds of the texture
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	// inject write layer into id before writing. 
	// id.z = params.write_layer_0_[layerName];
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y || id.z >= size.z) return;

	// do this per read layer as needed. 
	// float val = imageLoad(read_tex, ivec3(id.xy, read_idz_[layername])).r;

	// DO WORK HERE

	// EXAMPLES OF WRITING TO DIFFERENT LAYERS:
	// 1. FLOAT GRID (imageStore)
	// id.z = params.write_layer_0_[layerName];
	imageStore(write_tex, id, vec4(0.5, 0.0, 0.0, 0.0));
	// 
	// 2. ATOMIC GRID (imageAtomicAdd)
	// id.z = params.write_layer_0_[atomicLayerName];
	// imageAtomicAdd(atomic_tex, id, 10);
	//
	// 3. SSBO (Array Access)
	// uint idx = params.write_offset_[ssboLayerName] + local_index;
	// ssbo_write.data[idx].biomass = 1.0;
}
