#[compute]
#version 450

// Group size of 8x8 threads. This means each workgroup will process an 8x8 block of pixels in the output texture.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// === UNIFIED SIMULATION UNIFORM BINDINGS ===
// 0: Fine Float Write (r16f) | 1: Fine Float Read (r16f) | 2: Atomic RW (r32ui)
// 3: SSBO Write (std430)     | 4: SSBO Read (std430)     | 5: Atomic Visual (r16f)
// 6: Coarse Float Write (r32f)| 7: Coarse Float Read (r32f)
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
	float deltaTime; 

	int write_layer_0_SMOKETEST_U;
	int write_layer_1_SMOKETEST_V;
	
	int read_layer_0_SMOKETEST_U;
	int read_layer_1_SMOKETEST_V;
	
	float timeMsec;

} params; 

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(write_tex);
	if (id.x >= size.x || id.y >= size.y) return;

	// Calculate base UV coordinates (0.0 to 1.0)
	vec2 uv = vec2(id.xy) / vec2(size.xy);
	
	// params.timeMsec is actually in seconds already (converted in PushC_TimeMsec.gd)
	float time_sec = params.timeMsec;
	
	// Apply a sine wave over time to create a clear back-and-forth sweeping motion
	vec2 flowing_uv;
	flowing_uv.x = fract(uv.x + sin(time_sec * 2.0) * 0.5);
	flowing_uv.y = fract(uv.y + cos(time_sec * 2.0) * 0.5);

	id.z = params.write_layer_0_SMOKETEST_U;
	imageStore(write_tex, id, vec4(flowing_uv.x, 0.0, 0.0, 0.0));
	id.z = params.write_layer_1_SMOKETEST_V;
	imageStore(write_tex, id, vec4(flowing_uv.y, 0.0, 0.0, 0.0));
}
