extends Resource
class_name LayerGenerator
## Base class for specific world generation passes utilizing Compute Shaders. Subclassed to specify target buffers (Float vs Atomic).

## The overarching system this layer belongs to.
@export var system_name : Helpers.system_names
## whether to run the shader. For debugging.
@export var is_enabled : bool = true
## If true, workgroup dimensions will be calculated using coarse_resolution instead of world_width.
@export var is_coarse : bool = false
## The compiled SPIR-V compute shader to execute for generation mapping.
@export var shader_resource : RDShaderFile
## Array of Push_Constant resources used to pass variables to the shader.
@export var push_constants_resources : Array[Push_Constant]:
	set(val):
		push_constants_resources = val
		if val.size() > 32:
			push_warning("Push constant array length exceeds 32. This may lead to 128-byte limit issues on some hardware.")
## Number of times this layer generator should be dispatched.
@export var repeat_times : int = 1
## Array of CustomImage resources to be passed as uniform textures.
@export var custom_images : Array[CustomImage]
var custom_textures : RID
var custom_tex_uniform : RDUniform

## write layer indices held here, used for uniform construction. These are given by the Gpu World Sim
## important: these CANNOT be the same as other write_layers from other gpu work orders. 
## these are unique. 
var write_layer_indices : PackedInt32Array

## Compute Shader properties. Set at runtime. 
var rd : RenderingDevice
## generated once at initialisation() out of the shader_resource
var shader : RID
## always request with the write index to return the correct configuration for the frame. 
var uniform_set : RID
## generated once at initialisation() after the shader is compiled. 
var pipeline : RID

var workgroup_size : float = 8.0

# cached workgroup sizes. 
var w : int
var h : int

var _cached_push_constants_buffer : PackedByteArray

# Maps each Push_Constant resource to its starting byte offset in the buffer
var _push_constant_offsets : Dictionary

## assigns render device, the prepares shader, pipeline and uniform set array.
## Initializes the render device, calculates workgroup sizes, sets up custom images, and prepares the shader and pipeline.
func initialise_layer_generator(render_device : RenderingDevice) -> void:
	rd = render_device
	var width : int = GameStateManager.world_config.world_width
	var height : int = GameStateManager.world_config.world_height
	if is_coarse:
		width = int(width / 8.0)
		height = int(height / 8.0)
	w = ceil(float(width) / workgroup_size)
	h = ceil(float(height) / workgroup_size)
	for ci : CustomImage in custom_images:
		ci.set_image_params(width, height)
		
	setup_custom_image_textures()
	setup_custom_texture_uniforms()
	prepare_shader()
	prepare_pipeline()
	prepare_uniform_set()
	cache_push_constants_layout()

## Returns the complete unified uniform binding list for world generation passes.
func _get_target_uniforms() -> Array[RDUniform]:
	var ws : GpuWorldState = GameStateManager.current_world_state
	var uniforms : Array[RDUniform] = [
		ws.float_write_uniforms[0], # binding = 0: Fine Float Write
		ws.float_read_uniforms[0],  # binding = 1: Fine Float Read
		ws.atomic_uniform           # binding = 2: Atomic Grid RW
	]
	if ws.ssbo_write_uniforms.size() > 0:
		uniforms.append(ws.ssbo_write_uniforms[0]) # binding = 3: SSBO Write
		uniforms.append(ws.ssbo_read_uniforms[0])  # binding = 4: SSBO Read
	if ws.atomic_visual_uniform != null:
		uniforms.append(ws.atomic_visual_uniform)  # binding = 5: Atomic Visual
	if ws.coarse_write_uniforms.size() > 0:
		uniforms.append(ws.coarse_write_uniforms[0]) # binding = 6: Coarse Write
		uniforms.append(ws.coarse_read_uniforms[0])  # binding = 7: Coarse Read
	if custom_tex_uniform != null:
		uniforms.append(custom_tex_uniform)          # binding = 15: Custom Noise Textures Read
	return uniforms

## Calculates the memory offsets and aligns push constants into a PackedByteArray according to std140/std430 rules.
func cache_push_constants_layout() -> void:
	# 1. Start sizing the main buffer:
	var current_size : int = 0
	
	# 2. Iterate through user push constants to calculate sizes, alignments, and record offsets
	for push_const : Push_Constant in push_constants_resources:
		if not push_const:
			continue
			
		if push_const.type == TYPE_NIL:
			# If the type hasn't been set by Godot's setter yet, determine it from get_value()
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
					current_size += (8 - remainder) # Pad to 8-byte alignment
				_push_constant_offsets[push_const] = current_size
				current_size += 8
			TYPE_VECTOR3, TYPE_VECTOR3I:
				remainder = current_size % 16
				if remainder > 0:
					current_size += (16 - remainder) # Pad to 16-byte alignment
				_push_constant_offsets[push_const] = current_size
				current_size += 16
				
	# 3. Final padding for Vulkan requirement (must be multiple of 16)
	var final_remainder : int = current_size % 16
	if final_remainder > 0:
		current_size += (16 - final_remainder)
		
	if current_size > 128:
		push_error("Push constants buffer size exceeds 128-byte limit! GPU crash imminent. Aborting caching.")
		return
		
	# 4. Allocate the persistent buffer
	_cached_push_constants_buffer.resize(current_size)

func prepare_shader() -> void:
	var spirv : RDShaderSPIRV = shader_resource.get_spirv()
	if not spirv:
		push_error(shader_resource.resource_name + " failed to compile.")
	shader = rd.shader_create_from_spirv(spirv)

func prepare_pipeline() -> void:
	pipeline = rd.compute_pipeline_create(shader)

func setup_custom_image_textures() -> void:
	var tx_format : RDTextureFormat = RDTextureFormat.new()
	tx_format.texture_type = rd.TEXTURE_TYPE_2D_ARRAY
	
	# Texture2DArrayRD requires at least 2 layers in Godot, even if only 1 is used
	tx_format.array_layers = maxi(2, custom_images.size())
	var width : int = GameStateManager.world_config.world_width
	var height : int = GameStateManager.world_config.world_height
	if is_coarse:
		width = int(GameStateManager.world_config.world_width / 8.0)
		height = int(GameStateManager.world_config.world_height / 8.0)
	tx_format.width = width
	tx_format.height = height
	# single float channel
	tx_format.format = rd.DATA_FORMAT_R32_SFLOAT
	tx_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	
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
	
	#need to create a view to specify the number of layers in the array, even though we're only using 1 layer here
	var view : RDTextureView = RDTextureView.new()
	# create the actual texture
	custom_textures = rd.texture_create(tx_format, view, image_data_array)

func setup_custom_texture_uniforms() -> void:
	custom_tex_uniform = RDUniform.new()
	custom_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	custom_tex_uniform.binding = 15
	custom_tex_uniform.add_id(custom_textures)
	return


func prepare_uniform_set() -> void:
	var uniforms : Array[RDUniform] = _get_target_uniforms()
	uniform_set = rd.uniform_set_create(
		uniforms, 
		shader, 
		0
	)
	return

## Dispatches the compute shader pipeline.
func dispatch(count : int) -> void:
	var compute_list : int = rd.compute_list_begin()
	for c : int in range(count):
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		var push_constants : PackedByteArray = get_push_constants_buffer()
		rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
		rd.compute_list_dispatch(compute_list, w, h, 1)
		if c < count+1:
			rd.compute_list_add_barrier(compute_list)
	rd.compute_list_end()
	
# PUSH CONSTANTS
func get_push_constants_buffer() -> PackedByteArray:
	# Update dynamic user push constants at their pre-calculated offsets
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
	

func cleanup() -> void:
	# freeing the shaders automatically frees the pipelines and uniform sets that include them
	if rd.uniform_set_is_valid(uniform_set):
		rd.free_rid(uniform_set)
	if rd.compute_pipeline_is_valid(pipeline):
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	if rd.texture_is_valid(custom_textures):
		rd.free_rid(custom_textures)
	print(Helpers.system_names.find_key(system_name) + " cleaned up.")
