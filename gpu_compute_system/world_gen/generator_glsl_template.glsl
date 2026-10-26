#[compute]
#version 450

// Group size of 8x8 threads. This means each workgroup will process an 8x8 block of pixels in the output texture.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
// === UNIFIED GENERATOR UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f) | 1: Fine Float Read (r16f)    | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)     | 4: SSBO Read (std430)        | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f)| 7: Coarse Float Read (r32f) | 15: Custom Noise Read (r32f)
layout(r16f, set = 0, binding = 0) restrict uniform image2DArray write_tex;
layout(r16f, set = 0, binding = 1) restrict readonly uniform image2DArray read_tex;
layout(r32ui, set = 0, binding = 2) uniform uimage2DArray atomic_tex;

// Uncomment SSBO bindings if your generator targets SSBOs:
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

// Binding 15: Dedicated Custom Noise Textures Read (from CustomImage resources)
layout(r32f, set = 0, binding = 15) restrict readonly uniform image2DArray custom_tex;

layout(push_constant) uniform Params {
	float dummy_delete_me; // Placeholder to ensure the push constant block is not empty in this EXAMPLE causing an annoying error in Godot. Remove this line when adding your own push constants.

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
	// 2. ATOMIC GRID (imageAtomicAdd / imageStore)
	// id.z = params.write_layer_0_[atomicLayerName];
	// imageStore(atomic_tex, id, uvec4(10, 0, 0, 0)); // During generation, standard imageStore is usually safe for atomics.
	//
	// 3. SSBO (Array Access)
	// uint idx = params.write_offset_[ssboLayerName] + local_index;
	// ssbo_write.data[idx].biomass = 1.0;
}
