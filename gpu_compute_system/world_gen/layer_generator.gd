extends Resource
## Configures and manages a single compute shader pass in the world generation pipeline,
## compiling SPIR-V shaders, binding input/output textures, and packing push constants.
class_name LayerGenerator

## The simulation system category (e.g. TOPOGRAPHY_GENERATION, FLUID_DYNAMICS) this pass belongs to.
@export var system_name : Helpers.system_names
## Toggle allowing designers to disable this specific generation pass for debugging.
@export var is_enabled : bool = true
## When true, computes workgroups for a 64x64 coarse resolution grid instead of the 512x512 fine grid.
@export var is_coarse : bool = false
## The compiled SPIR-V compute shader file executed on the GPU.
@export var shader_resource : RDShaderFile
## Ordered list of push constants passed to the shader (must fit within 128 bytes total).
@export var push_constants_resources : Array[Push_Constant]:
	set(val):
		push_constants_resources = val
		if val.size() > 32:
			push_warning("Push constant array length exceeds 32. This may lead to 128-byte limit issues on some hardware.")
## Number of times to iteratively dispatch this compute pass during world generation.
@export var repeat_times : int = 1
## Optional procedural noise images baked and passed to the shader as input textures on Binding 15.
@export var custom_images : Array[CustomImage]
## GPU texture array RID holding the custom images passed on Binding 15.
var custom_textures : RID
## Texture uniform descriptor mapping `custom_textures` to Set 0 Binding 15.
var custom_tex_uniform : RDUniform

## Array of unique write layer indices modified by this generation pass.
var write_layer_indices : PackedInt32Array

## Reference to the low-level RenderingDevice API.
var rd : RenderingDevice
## GPU shader resource RID created from the compiled SPIR-V code.
var shader : RID
## Uniform set RID binding all input/output textures and buffers to Set 0.
var uniform_set : RID
## GPU compute pipeline RID linking the compiled shader.
var pipeline : RID

## Number of threads per workgroup along each axis (8x8 = 64 threads per GPU workgroup).
var workgroup_size : float = 8.0

## Number of workgroups to dispatch horizontally across the grid (`width / 8`).
var w : int
## Number of workgroups to dispatch vertically across the grid (`height / 8`).
var h : int

## Pre-allocated byte buffer packing all push constants with std430 alignment rules.
var _cached_push_constants_buffer : PackedByteArray

## Lookup table mapping each Push_Constant resource to its starting byte offset in `_cached_push_constants_buffer`.
var _push_constant_offsets : Dictionary


## Prepares workgroup dispatch dimensions, compiles custom noise images, builds the shader pipeline, and caches push constants.
func initialise_layer_generator(render_device : RenderingDevice) -> void:
	rd = render_device
	# Determine grid resolution (64x64 for coarse dynamics, 512x512 for fine terrain/water).
	var width : int = GameStateManager.world_config.world_width
	var height : int = GameStateManager.world_config.world_height
	if is_coarse:
		width = int(width / 8.0)
		height = int(height / 8.0)
	# Divide resolution by 8x8 thread group size to determine how many workgroups to launch across the grid.
	w = ceil(float(width) / workgroup_size)
	h = ceil(float(height) / workgroup_size)
	for ci : CustomImage in custom_images:
		ci.set_image_params(width, height)
		
	# Build noise textures, compile shader, create compute pipeline, and bind Set 0 uniforms.
	setup_custom_image_textures()
	setup_custom_texture_uniforms()
	prepare_shader()
	prepare_pipeline()
	prepare_uniform_set()
	cache_push_constants_layout()


## Builds the unified list of Set 0 uniform descriptors (Bindings 0-7, 15) available to world generation shaders.
func _get_target_uniforms() -> Array[RDUniform]:
	var ws : GpuWorldState = GameStateManager.current_world_state
	# Include standard fine float read/write textures and the atomic integer grid.
	var uniforms : Array[RDUniform] = [
		ws.float_write_uniforms[0],
		ws.float_read_uniforms[0],
		ws.atomic_uniform
	]
	# Include SSBO population clusters if active.
	if ws.ssbo_write_uniforms.size() > 0:
		uniforms.append(ws.ssbo_write_uniforms[0])
		uniforms.append(ws.ssbo_read_uniforms[0])
	# Include normalized atomic visualization texture.
	if ws.atomic_visual_uniform != null:
		uniforms.append(ws.atomic_visual_uniform)
	# Include coarse dynamics read/write textures.
	if ws.coarse_write_uniforms.size() > 0:
		uniforms.append(ws.coarse_write_uniforms[0])
		uniforms.append(ws.coarse_read_uniforms[0])
	# Include custom procedural noise textures at Binding 15.
	if custom_tex_uniform != null:
		uniforms.append(custom_tex_uniform)
	return uniforms


## Pre-calculates std430 byte offsets and alignment padding for all push constants, ensuring total size <= 128 bytes.
func cache_push_constants_layout() -> void:
	var current_size : int = 0
	
	# Compute byte strides and required padding: 4 bytes for scalars, 8 for vec2, 16 for vec3/vec4.
	for push_const : Push_Constant in push_constants_resources:
		if not push_const:
			continue
			
		if push_const.type == TYPE_NIL:
			var val : Variant = push_const.get_value()
			push_const.type = typeof(val) as Variant.Type

		var remainder : int = 0
		match push_const.type:
			TYPE_INT, TYPE_FLOAT:
				_push_constant_offsets[push_const] = current_size
				current_size += 4
			TYPE_VECTOR2, TYPE_VECTOR2I:
				remainder = current_size % 8
				if remainder > 0:
					current_size += (8 - remainder)
				_push_constant_offsets[push_const] = current_size
				current_size += 8
			TYPE_VECTOR3, TYPE_VECTOR3I:
				remainder = current_size % 16
				if remainder > 0:
					current_size += (16 - remainder)
				_push_constant_offsets[push_const] = current_size
				current_size += 16
				
	# Align final buffer size to a multiple of 16 bytes as required by Vulkan push constant limits.
	var final_remainder : int = current_size % 16
	if final_remainder > 0:
		current_size += (16 - final_remainder)
		
	if current_size > 128:
		push_error("Push constants buffer size exceeds 128-byte limit! GPU crash imminent. Aborting caching.")
		return
		
	# Allocate the persistent cached byte buffer.
	_cached_push_constants_buffer.resize(current_size)


## Compiles the SPIR-V shader binary into a GPU shader resource.
func prepare_shader() -> void:
	# Extract SPIR-V bytecodes and upload to RenderingDevice.
	var spirv : RDShaderSPIRV = shader_resource.get_spirv()
	if not spirv:
		push_error(shader_resource.resource_name + " failed to compile.")
	shader = rd.shader_create_from_spirv(spirv)


## Creates the GPU compute pipeline linking the compiled shader.
func prepare_pipeline() -> void:
	pipeline = rd.compute_pipeline_create(shader)


## Bakes custom procedural noise images into a 2D texture array on the GPU.
func setup_custom_image_textures() -> void:
	var tx_format : RDTextureFormat = RDTextureFormat.new()
	tx_format.texture_type = rd.TEXTURE_TYPE_2D_ARRAY
	
	# Godot Texture2DArrayRD requires at least 2 layers in the array format even if only 1 image is provided.
	tx_format.array_layers = maxi(2, custom_images.size())
	var width : int = GameStateManager.world_config.world_width
	var height : int = GameStateManager.world_config.world_height
	if is_coarse:
		width = int(GameStateManager.world_config.world_width / 8.0)
		height = int(GameStateManager.world_config.world_height / 8.0)
	tx_format.width = width
	tx_format.height = height
	tx_format.format = rd.DATA_FORMAT_R32_SFLOAT
	tx_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	
	# Generate raw byte data for each custom image slice.
	var image_data_array : Array[PackedByteArray] = []
	var empty_layer : PackedByteArray = PackedByteArray()
	empty_layer.resize(tx_format.width * tx_format.height * 4)
	empty_layer.fill(0)
	
	if custom_images.is_empty():
		image_data_array.append(empty_layer)
		image_data_array.append(empty_layer)
	else:
		for ci : CustomImage in custom_images:
			var img : Image = ci.get_image()
			if img:
				if img.get_format() != Image.FORMAT_RF:
					img.convert(Image.FORMAT_RF)
				image_data_array.append(img.get_data())
			else:
				image_data_array.append(empty_layer)
		while image_data_array.size() < 2:
			image_data_array.append(empty_layer)
	
	var view : RDTextureView = RDTextureView.new()
	custom_textures = rd.texture_create(tx_format, view, image_data_array)


## Creates the RDUniform descriptor mapping `custom_textures` to Set 0 Binding 15.
func setup_custom_texture_uniforms() -> void:
	custom_tex_uniform = RDUniform.new()
	custom_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	custom_tex_uniform.binding = 15
	custom_tex_uniform.add_id(custom_textures)
	return


## Binds all required texture and buffer uniforms to descriptor Set 0 on the GPU.
func prepare_uniform_set() -> void:
	var uniforms : Array[RDUniform] = _get_target_uniforms()
	uniform_set = rd.uniform_set_create(
		uniforms, 
		shader, 
		0
	)
	return


## Submits `count` iterative dispatches of this compute shader into the GPU command list.
func dispatch(count : int) -> void:
	var compute_list : int = rd.compute_list_begin()
	# Execute the shader `count` times, inserting a barrier between steps so subsequent passes see previous writes.
	for c : int in range(count):
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		var push_constants : PackedByteArray = get_push_constants_buffer()
		rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
		rd.compute_list_dispatch(compute_list, w, h, 1)
		if c < count+1:
			rd.compute_list_add_barrier(compute_list)
	rd.compute_list_end()


## Packs updated push constant values into the cached byte buffer using their pre-calculated std430 offsets.
func get_push_constants_buffer() -> PackedByteArray:
	# Update each push constant value at its designated byte offset.
	for push_const : Push_Constant in push_constants_resources:
		if not push_const or not _push_constant_offsets.has(push_const):
			continue
		
		var current_val : Variant = push_const.get_value()
		var offset : int = _push_constant_offsets[push_const]
		
		match push_const.type:
			TYPE_INT:
				@warning_ignore("unsafe_cast")
				_cached_push_constants_buffer.encode_s32(offset, current_val as int)
			TYPE_FLOAT:
				@warning_ignore("unsafe_cast")
				_cached_push_constants_buffer.encode_float(offset, current_val as float)
			TYPE_VECTOR2:
				@warning_ignore("unsafe_cast")
				var pc : Vector2 = current_val as Vector2
				_cached_push_constants_buffer.encode_float(offset, pc.x)
				_cached_push_constants_buffer.encode_float(offset + 4, pc.y)
			TYPE_VECTOR2I:
				@warning_ignore("unsafe_cast")
				var pc : Vector2i = current_val as Vector2i
				_cached_push_constants_buffer.encode_s32(offset, pc.x)
				_cached_push_constants_buffer.encode_s32(offset + 4, pc.y)
			TYPE_VECTOR3:
				@warning_ignore("unsafe_cast")
				var pc : Vector3 = current_val as Vector3
				_cached_push_constants_buffer.encode_float(offset, pc.x)
				_cached_push_constants_buffer.encode_float(offset + 4, pc.y)
				_cached_push_constants_buffer.encode_float(offset + 8, pc.z)
			TYPE_VECTOR3I:
				@warning_ignore("unsafe_cast")
				var pc : Vector3i = current_val as Vector3i
				_cached_push_constants_buffer.encode_s32(offset, pc.x)
				_cached_push_constants_buffer.encode_s32(offset + 4, pc.y)
				_cached_push_constants_buffer.encode_s32(offset + 8, pc.z)
				
	return _cached_push_constants_buffer


## Frees compiled pipelines, uniform sets, shaders, and noise textures from GPU memory.
func cleanup() -> void:
	# Free GPU descriptor sets, compute pipelines, shader objects, and noise textures.
	if rd.uniform_set_is_valid(uniform_set):
		rd.free_rid(uniform_set)
	if rd.compute_pipeline_is_valid(pipeline):
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	if rd.texture_is_valid(custom_textures):
		rd.free_rid(custom_textures)
	print(Helpers.system_names.find_key(system_name) + " cleaned up.")

