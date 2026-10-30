extends Resource
## Configures and manages a single runtime compute shader pass, supporting double-buffered ping-pong
## textures, sub-cycling with even step enforcement, and opt-in auxiliary SSBO bindings.
class_name LayerSimulator

## The high-level simulation system (e.g. THERMODYNAMICS, FLUID_DYNAMICS, ECOLOGY_BASELINE) this pass belongs to.
@export var system_name : Helpers.system_names
## The compiled SPIR-V compute shader file to execute on the GPU.
@export var shader_resource : RDShaderFile
## When true, computes dispatch dimensions using the 64x64 coarse grid instead of the 512x512 fine grid.
@export var is_coarse : bool = false
## Number of internal sub-cycling passes per frame; must be an even number (> 1) so ping-pong buffers land on the expected target.
@export_range(1, 16, 1) var execution_steps : int = 1:
	set(val):
		var clamped : int = maxi(val, 1)
		if clamped > 1 and clamped % 2 != 0:
			clamped += 1
		execution_steps = clamped
## Ordered push constants passed to the shader; offset 0 is always reserved for `float deltaTime`.
@export var push_constants_resources : Array[Push_Constant]:
	set(val):
		push_constants_resources = val
		if val.size() > 31:
			push_warning("Push constant array length exceeds 32. This may lead to 128-byte limit issues on some hardware.")
			push_error(Helpers.system_names.get(Helpers.system_names))

@export_group("Dispatch")
## Mode determining how GPU workgroups are divided: GRID_2D for 2D cell grids, LINEAR_1D for 1D cluster arrays.
enum DispatchMode { GRID_2D, LINEAR_1D }
## Dispatch geometry mode: 2D planetary grid or 1D agent array.
@export var dispatch_mode : DispatchMode = DispatchMode.GRID_2D
## Number of elements to process when using LINEAR_1D mode (e.g. total fauna clusters).
@export var linear_dispatch_count : int = 0
## Number of workgroups to dispatch along the Z axis (typically 1 unless slicing 3D volume passes).
@export var dispatch_z : int = 1

@export_group("Auxiliary SSBOs")
## When true, binds the read-only SpellBook storage buffer at Set 0 Binding 10.
@export var uses_spellbook : bool = false
## When true, binds the read-only SpeciesArchetype limits storage buffer at Set 0 Binding 11.
@export var uses_archetype_limits : bool = false
## When true, binds the double-buffered Impact Currency ping-pong storage buffer at Set 0 Binding 12.
@export var uses_impact_currency : bool = false

## When true on player action layers, logs the submitted push constant bytes whenever a click occurs.
var debug_trace_dispatch : bool = false

## Unique layer indices written by this simulation pass.
var write_layer_indices : PackedInt32Array

## Low-level RenderingDevice API instance.
var rd : RenderingDevice
## Compiled compute shader RID.
var shader : RID
## Pre-baked descriptor sets matching read/write ping-pong configurations.
var uniform_sets : Array[RID]
## Compute pipeline RID linking the compiled shader.
var pipeline : RID

## Number of threads per workgroup dimension (8x8 = 64 threads per workgroup).
var workgroup_size : float = 8.0

## Number of workgroups dispatched horizontally (`width / 8`).
var w : int
## Number of workgroups dispatched vertically (`height / 8`).
var h : int

## Pre-allocated byte buffer packing `deltaTime` and all push constants with std430 alignment.
var _cached_push_constants_buffer : PackedByteArray

## Lookup table mapping each Push_Constant resource to its starting byte offset in the buffer.
var _push_constant_offsets : Dictionary


## Prepares dispatch dimensions, compiles the shader, creates pre-baked ping-pong uniform sets, and caches push constant offsets.
func initialise_sim_layer(render_device : RenderingDevice) -> void:
	rd = render_device
	var width : int = GameStateManager.world_config.world_width
	var height : int = GameStateManager.world_config.world_height
	if is_coarse:
		width = GameStateManager.world_config.coarse_width
		height = GameStateManager.world_config.coarse_height
	# Compute workgroup counts based on whether this pass operates on a 2D spatial grid or a 1D agent list.
	match dispatch_mode:
		DispatchMode.GRID_2D:
			w = ceil(float(width) / workgroup_size)
			h = ceil(float(height) / workgroup_size)
		DispatchMode.LINEAR_1D:
			w = ceil(float(linear_dispatch_count) / workgroup_size)
			h = 1
	prepare_shader()
	prepare_pipeline()
	prepare_uniform_sets()
	cache_push_constants_layout()


## Constructs the Set 0 uniform list matching read and write ping-pong buffer indices.
func _get_target_uniforms(write_index: int, read_index: int, impact_currency_index: int = -1) -> Array[RDUniform]:
	var ws : GpuWorldState = GameStateManager.current_world_state
	# Include standard fine float read/write textures and the atomic integer grid.
	var uniforms : Array[RDUniform] = [
		ws.float_write_uniforms[write_index],
		ws.float_read_uniforms[read_index],
		ws.atomic_uniform
	]
	# Include SSBO population clusters if active.
	if ws.ssbo_write_uniforms.size() > 0:
		uniforms.append(ws.ssbo_write_uniforms[write_index])
		uniforms.append(ws.ssbo_read_uniforms[read_index])
	# Include normalized atomic visualization texture.
	if ws.atomic_visual_uniform != null:
		uniforms.append(ws.atomic_visual_uniform)
	# Include coarse dynamics read/write textures.
	if ws.coarse_write_uniforms.size() > 0:
		uniforms.append(ws.coarse_write_uniforms[write_index])
		uniforms.append(ws.coarse_read_uniforms[read_index])
	_append_aux_uniforms(uniforms, ws, impact_currency_index)
	return uniforms


## Appends optional auxiliary SSBO uniforms (Bindings 10, 11, 12) if enabled on this pass.
func _append_aux_uniforms(uniforms : Array[RDUniform], ws : GpuWorldState, impact_currency_index: int = -1) -> void:
	# Binding 10: SpellBook definitions.
	if uses_spellbook:
		var spellbook_u : RDUniform = ws.get_aux_ssbo_uniform(Helpers.sim_layers.PLAYER_ACTIONS)
		if spellbook_u:
			uniforms.append(spellbook_u)
	# Binding 11: Species Archetype trait limits.
	if uses_archetype_limits:
		var archetype_u : RDUniform = ws.get_aux_ssbo_uniform(Helpers.sim_layers.FAUNA)
		if archetype_u:
			uniforms.append(archetype_u)
	# Binding 12: Impact Currency ping-pong buffer.
	if uses_impact_currency:
		if impact_currency_index >= 0 and impact_currency_index < ws.impact_currency_uniforms.size():
			uniforms.append(ws.impact_currency_uniforms[impact_currency_index])
		else:
			uniforms.append(ws.get_impact_currency_uniform())


## Computes std430 memory offsets for all push constants, reserving bytes 0-3 for `float deltaTime`.
func cache_push_constants_layout() -> void:
	# Reserve offset 0 for 4-byte float deltaTime.
	var current_size : int = 4
	
	# Compute std430 byte alignment for each subsequent push constant variable.
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
				
	# Pad to Vulkan's required multiple of 16 bytes.
	var final_remainder : int = current_size % 16
	if final_remainder > 0:
		current_size += (16 - final_remainder)
		
	if current_size > 128:
		push_error("Push constants buffer size exceeds 128-byte limit! GPU crash imminent. Aborting caching. - " + shader_resource.resource_name)
		return
		
	_cached_push_constants_buffer.resize(current_size)


## Compiles the SPIR-V shader bytecode into a GPU shader resource.
func prepare_shader() -> void:
	var spirv : RDShaderSPIRV = shader_resource.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)


## Creates the GPU compute pipeline linking the compiled shader.
func prepare_pipeline() -> void:
	pipeline = rd.compute_pipeline_create(shader)


## Pre-bakes descriptor uniform sets for both ping-pong orientations so buffer swaps require zero CPU allocation at runtime.
func prepare_uniform_sets() -> void:
	# For currency layers, pre-bake a 2x2 grid (currency active half × texture write half) to handle currency swaps cleanly.
	if uses_impact_currency:
		uniform_sets.resize(4)
		for active_currency : int in 2:
			for write_index : int in 2:
				var read_index : int = (write_index + 1) % 2
				uniform_sets[active_currency * 2 + write_index] = rd.uniform_set_create(
					_get_target_uniforms(write_index, read_index, active_currency),
					shader,
					0
				)
		return
	# Standard layers pre-bake two sets: Set 0 (write 0, read 1) and Set 1 (write 1, read 0).
	uniform_sets.resize(2)
	uniform_sets[0] = rd.uniform_set_create(
		_get_target_uniforms(0, 1),
		shader,
		0
	)
	uniform_sets[1] = rd.uniform_set_create(
		_get_target_uniforms(1, 0),
		shader,
		0
	)
	return


## Dispatches a single compute pass into the GPU command list.
func _dispatch_single_pass(write_set_index : int, deltaTime : float) -> void:
	var compute_list : int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	# Select the appropriate pre-baked uniform set based on the active write buffer index.
	if uses_impact_currency:
		var ws : GpuWorldState = GameStateManager.current_world_state
		var set_index : int = ws.impact_currency_active_index * 2 + write_set_index
		rd.compute_list_bind_uniform_set(compute_list, uniform_sets[set_index], 0)
	else:
		rd.compute_list_bind_uniform_set(compute_list, uniform_sets[write_set_index], 0)
	# Pack deltaTime and dynamic parameters into the push constant block.
	var push_constants : PackedByteArray = get_push_constants_buffer(deltaTime)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, w, h, dispatch_z)
	rd.compute_list_end()

	# Optional diagnostic logging for player action click submission.
	if debug_trace_dispatch and system_name == Helpers.system_names.PLAYER_ACTIONS and push_constants.size() >= 36:
		if push_constants.decode_s32(32) != 0:
			print("[DispatchTrace] write_set=%d | dt=%.4f key@4=%d fb@8=%d | cell@16=(%d,%d) uv@24=(%.3f,%.3f) | key@32=0x%X val@36=%.1f | %dB submitted, dispatch=%dx%dx%d" % [
				write_set_index, deltaTime,
				push_constants.decode_s32(4), push_constants.decode_s32(8),
				push_constants.decode_s32(16), push_constants.decode_s32(20),
				push_constants.decode_float(24), push_constants.decode_float(28),
				push_constants.decode_s32(32), push_constants.decode_float(36),
				push_constants.size(), w, h, dispatch_z])


## Dispatches this simulation pass, iterating across sub-cycling steps if `execution_steps > 1`.
func dispatch(write_set_index : int, deltaTime : float) -> void:
	if execution_steps <= 1:
		_dispatch_single_pass(write_set_index, deltaTime)
	else:
		# Divide deltaTime evenly across sub-cycling steps and alternate write/read targets.
		var sub_dt : float = deltaTime / float(execution_steps)
		var cur_write : int = write_set_index
		var cur_read : int = (write_set_index + 1) % 2
		for s : int in range(execution_steps):
			_dispatch_single_pass(cur_write, sub_dt)
			var temp : int = cur_write
			cur_write = cur_read
			cur_read = temp


## Packs updated deltaTime and dynamic push constant values into the cached byte buffer.
func get_push_constants_buffer(deltaTime : float) -> PackedByteArray:
	# Encode deltaTime at byte offset 0.
	_cached_push_constants_buffer.encode_float(0, deltaTime)
	
	# Update each user push constant value at its pre-calculated std430 byte offset.
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


## Frees compiled compute pipelines, uniform sets, and shaders from GPU memory.
func cleanup() -> void:
	# Release GPU uniform descriptor sets, compute pipelines, and shader objects.
	for us : RID in uniform_sets:
		if rd.uniform_set_is_valid(us):
			rd.free_rid(us)
	if rd.compute_pipeline_is_valid(pipeline):
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	print(Helpers.system_names.find_key(system_name) + " cleaned up.")

