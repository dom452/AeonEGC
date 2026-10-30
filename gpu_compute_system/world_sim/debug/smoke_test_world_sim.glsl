#[compute]
#version 450

// =============================================================================
// SMOKE TEST WORLD SIMULATION
// Diagnostic compute pass that renders animated sweeping UV test patterns for pipeline verification.
// Physical units: Normalized UV coordinates [0.0, 1.0].
// Bindings: Writes animated gradient coordinates to write_tex (Set 0, Binding 0).
// =============================================================================

// Workgroup size of 8x8 threads matching simulation dispatch layout
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// === UNIFIED SIMULATION UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f)   | 1: Fine Float Read (r16f)    | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)       | 4: SSBO Read (std430)        | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f) | 7: Coarse Float Read (r32f)
layout(r16f, set = 0, binding = 0) restrict writeonly uniform image2DArray write_tex;
layout(r16f, set = 0, binding = 1) restrict readonly uniform image2DArray read_tex;
layout(r32ui, set = 0, binding = 2) uniform uimage2DArray atomic_tex;
layout(r16f, set = 0, binding = 5) restrict writeonly uniform image2DArray atomic_vis_tex;
layout(r32f, set = 0, binding = 6) restrict uniform image2DArray coarse_write_tex;
layout(r32f, set = 0, binding = 7) restrict readonly uniform image2DArray coarse_read_tex;

layout(std430, set = 0, binding = 4) restrict readonly buffer SSBORead {
	uint data[];
} ssbo_read;

layout(push_constant) uniform Params {
	float deltaTime; // Time step duration in seconds

	int write_layer_0_SMOKETEST_U; // Index of first diagnostic output layer in float texture array
	int write_layer_1_SMOKETEST_V; // Index of second diagnostic output layer in float texture array
	
	int read_layer_0_SMOKETEST_U;  // Index of first diagnostic input layer in float texture array
	int read_layer_1_SMOKETEST_V;  // Index of second diagnostic input layer in float texture array
	
	float timeMsec; // Elapsed time in seconds

} params; 

void main() {
	// Determine 2D coordinate for this compute thread within the world grid
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Calculate normalized UV coordinates [0.0, 1.0] across the grid
	vec2 uv = vec2(id.xy) / vec2(size.xy);
	
	// Elapsed time in seconds
	float time_sec = params.timeMsec;
	
	// Modulate UV coordinates with sinusoidal oscillations to generate an animated diagnostic wave pattern
	vec2 flowing_uv;
	flowing_uv.x = fract(uv.x + sin(time_sec * 2.0) * 0.5);
	flowing_uv.y = fract(uv.y + cos(time_sec * 2.0) * 0.5);

	// Store test waves into the designated output diagnostic layers
	id.z = params.write_layer_0_SMOKETEST_U;
	imageStore(write_tex, id, vec4(flowing_uv.x, 0.0, 0.0, 0.0));
	id.z = params.write_layer_1_SMOKETEST_V;
	imageStore(write_tex, id, vec4(flowing_uv.y, 0.0, 0.0, 0.0));
}
