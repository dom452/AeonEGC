extends Resource
class_name LayerSimulator
## Wraps a specific compute shader step within the simulation loop.

## The overarching system this layer belongs to.
@export var system_name : Helpers.system_names
## The compiled SPIR-V compute shader resource.
@export var shader_resource : RDShaderFile
## If true, workgroup dimensions will be calculated using coarse resolution instead of world_width.
@export var is_coarse : bool = false
## Number of sub-cycling steps per frame. Must be even when ping-ponging double-buffered grids.
@export_range(1, 16, 1) var execution_steps : int = 1:
	set(val):
		var clamped : int = maxi(val, 1)
		if clamped > 1 and clamped % 2 != 0:
			clamped += 1
		execution_steps = clamped
@export var push_constants_resources : Array[Push_Constant]:
	set(val):
		push_constants_resources = val
		if val.size() > 31:
			push_warning("Push constant array length exceeds 32. This may lead to 128-byte limit issues on some hardware.")
			push_error(Helpers.system_names.get(Helpers.system_names))

@export_group("Dispatch")
enum DispatchMode { GRID_2D, LINEAR_1D }
## How workgroup dimensions are calculated. GRID_2D = world_width × world_height (default, Eulerian grid layers).
## LINEAR_1D = linear_dispatch_count × 1 (SSBO-agent layers like fauna).
@export var dispatch_mode : DispatchMode = DispatchMode.GRID_2D
## Element count for LINEAR_1D mode (e.g. cluster count). Ignored in GRID_2D.
@export var linear_dispatch_count : int = 0
## Z dispatch groups. Default 1. Set >1 for 3D invocation ID passes.
@export var dispatch_z : int = 1

@export_group("Auxiliary SSBOs")
## Opt-in flags for auxiliary SSBO uniform injection. When true, the corresponding
## uniform from GpuWorldState is appended to this layer's uniform set at its fixed binding.
@export var uses_spellbook : bool = false           # binding 10 (PLAYER_ACTIONS)
@export var uses_archetype_limits : bool = false    # binding 11 (FAUNA)
@export var uses_impact_currency : bool = false     # binding 12 (ping-pong; plan §2.7)
# NOTE: binding 8 (EventBuffer) was decommissioned with the geothermal POC at
# plan §8.4 — the flag and its plumbing are gone; biome causation travels in
# the BIOME_TYPE texel's attribution bits instead.

## Debug tracing. When true AND this is a PLAYER_ACTIONS layer, _dispatch_single_pass
## prints the write-set index and the exact push-constant bytes submitted — but only
## on frames carrying a non-zero PlayerAction click payload, so there is no per-frame
## spam. Purely observational: never mutates dispatch behavior. Leave false in normal
## runs; enable temporarily to prove CPU-side click submission (the tool that found
## the missing local_size declaration during the spell POC debugging).
var debug_trace_dispatch : bool = false

## write layer indices held here, used for uniform construction. These are given by the Gpu World Sim
## important: these CANNOT be the same as other write_layers from other gpu work orders. 
## these are unique. 
var write_layer_indices : PackedInt32Array

## Compute Shader properties. Set at runtime. 
var rd : RenderingDevice
## generated once at initialisation() out of the shader_resource
var shader : RID
## Array of RDUniform sets generated for read and write swapping.
## Always request with the write index to return the correct configuration for the frame. 
var uniform_sets : Array[RID]
## generated once at initialisation() after the shader is compiled. 
var pipeline : RID

var workgroup_size : float = 8.0

# cached workgroup sizes. 
var w : int
var h : int

var _cached_push_constants_buffer : PackedByteArray

# Maps each Push_Constant resource to its starting byte offset in the buffer
var _push_constant_offsets : Dictionary

## Initializes the render device, prepares the shader, pipeline, uniform sets, and caches push constant offsets.
func initialise_sim_layer(render_device : RenderingDevice) -> void:
	rd = render_device
	var width : int = GameStateManager.world_config.world_width
	var height : int = GameStateManager.world_config.world_height
	if is_coarse:
		width = GameStateManager.world_config.coarse_width
		height = GameStateManager.world_config.coarse_height
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

## Requests all standard bindings: Float Write (0), Float Read (1), Atomic RW (2), SSBO Write (3), SSBO Read (4), Atomic Vis (5), Coarse Write (6), Coarse Read (7).
## impact_currency_index selects which ping-pong ImpactCurrency half to bind
## (-1 = the currently active half).
func _get_target_uniforms(write_index: int, read_index: int, impact_currency_index: int = -1) -> Array[RDUniform]:
	var ws : GpuWorldState = GameStateManager.current_world_state
	var uniforms : Array[RDUniform] = [
		ws.float_write_uniforms[write_index], # binding = 0
		ws.float_read_uniforms[read_index],   # binding = 1
		ws.atomic_uniform                     # binding = 2
	]
	if ws.ssbo_write_uniforms.size() > 0:
		uniforms.append(ws.ssbo_write_uniforms[write_index])  # binding = 3
		uniforms.append(ws.ssbo_read_uniforms[read_index])    # binding = 4
	if ws.atomic_visual_uniform != null:
		uniforms.append(ws.atomic_visual_uniform)             # binding = 5
	if ws.coarse_write_uniforms.size() > 0:
		uniforms.append(ws.coarse_write_uniforms[write_index]) # binding = 6: Coarse Write
		uniforms.append(ws.coarse_read_uniforms[read_index])   # binding = 7: Coarse Read
	_append_aux_uniforms(uniforms, ws, impact_currency_index)
	return uniforms

## Appends auxiliary SSBO uniforms (bindings 10, 11, 12) for layers that opt in
## via the @export flags. Vulkan uniform bindings are identified by the binding field
## on each RDUniform, not by array position, so append order does not matter.
func _append_aux_uniforms(uniforms : Array[RDUniform], ws : GpuWorldState, impact_currency_index: int = -1) -> void:
	if uses_spellbook:
		var spellbook_u : RDUniform = ws.get_aux_ssbo_uniform(Helpers.sim_layers.PLAYER_ACTIONS)
		if spellbook_u:
			uniforms.append(spellbook_u)
	if uses_archetype_limits:
		var archetype_u : RDUniform = ws.get_aux_ssbo_uniform(Helpers.sim_layers.FAUNA)
		if archetype_u:
			uniforms.append(archetype_u)
	if uses_impact_currency:
		if impact_currency_index >= 0 and impact_currency_index < ws.impact_currency_uniforms.size():
			uniforms.append(ws.impact_currency_uniforms[impact_currency_index])
		else:
			uniforms.append(ws.get_impact_currency_uniform())
	

func cache_push_constants_layout() -> void:
	# 1. Start sizing the main buffer:
	# deltaTime (4 bytes)
	var current_size : int = 4
	
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
		push_error("Push constants buffer size exceeds 128-byte limit! GPU crash imminent. Aborting caching. - " + shader_resource.resource_name)
		return
		
	# 4. Allocate the persistent buffer
	_cached_push_constants_buffer.resize(current_size)

func prepare_shader() -> void:
	var spirv : RDShaderSPIRV = shader_resource.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)

func prepare_pipeline() -> void:
	pipeline = rd.compute_pipeline_create(shader)

func prepare_uniform_sets() -> void:
	if uses_impact_currency:
		# Currency ping-pong layers get a 2x2 pre-baked uniform-set grid
		# (currency half x write half); index = currency_active * 2 + write.
		# The ~1 Hz aux swap is a pure index read at bind time (plan §2.7).
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

## Dispatches a single compute pass into a compute list queue.
func _dispatch_single_pass(write_set_index : int, deltaTime : float) -> void:
	var compute_list : int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	if uses_impact_currency:
		# 2x2 pre-baked set grid (see prepare_uniform_sets). Pure index read —
		# the ~1 Hz currency swap is picked up from GpuWorldState's active index.
		var ws : GpuWorldState = GameStateManager.current_world_state
		var set_index : int = ws.impact_currency_active_index * 2 + write_set_index
		rd.compute_list_bind_uniform_set(compute_list, uniform_sets[set_index], 0)
	else:
		rd.compute_list_bind_uniform_set(compute_list, uniform_sets[write_set_index], 0)
	var push_constants : PackedByteArray = get_push_constants_buffer(deltaTime)
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	rd.compute_list_dispatch(compute_list, w, h, dispatch_z)
	rd.compute_list_end()
	# SpellClickVerifier tracing: fires ONLY on PLAYER_ACTIONS frames whose encoded
	# push constants carry a non-zero click payload (key@32 != 0), so exactly one
	# line per real click. Logs the write-set index bound and the payload bytes the
	# GPU is being submitted — the last CPU-side observation point.
	if debug_trace_dispatch and system_name == Helpers.system_names.PLAYER_ACTIONS and push_constants.size() >= 36:
		if push_constants.decode_s32(32) != 0:
			print("[DispatchTrace] write_set=%d | dt=%.4f key@4=%d fb@8=%d | cell@16=(%d,%d) uv@24=(%.3f,%.3f) | key@32=0x%X val@36=%.1f | %dB submitted, dispatch=%dx%dx%d" % [
				write_set_index, deltaTime,
				push_constants.decode_s32(4), push_constants.decode_s32(8),
				push_constants.decode_s32(16), push_constants.decode_s32(20),
				push_constants.decode_float(24), push_constants.decode_float(28),
				push_constants.decode_s32(32), push_constants.decode_float(36),
				push_constants.size(), w, h, dispatch_z])

## Binds the pipeline and uniforms, sets push constants, and dispatches the compute list (supporting sub-cycling).
func dispatch(write_set_index : int, deltaTime : float) -> void:
	if execution_steps <= 1:
		_dispatch_single_pass(write_set_index, deltaTime)
	else:
		var sub_dt : float = deltaTime / float(execution_steps)
		var cur_write : int = write_set_index
		var cur_read : int = (write_set_index + 1) % 2
		for s : int in range(execution_steps):
			_dispatch_single_pass(cur_write, sub_dt)
			var temp : int = cur_write
			cur_write = cur_read
			cur_read = temp
	# NOTE: No end of dispatch barrier needed as Godot 4.6 automatically injects them, 
	# where needed, between compute lists. 


# PUSH CONSTANTS
## Constructs the byte array for push constants, updating delta time and custom push constant values.
func get_push_constants_buffer(deltaTime : float) -> PackedByteArray:
	# 1. Encode delta time (always offset 0)
	_cached_push_constants_buffer.encode_float(0, deltaTime)
	
	# 2. Layer indices are static and were pre-encoded at offset 4 during initialization
	
	# 3. Update dynamic user push constants at their pre-calculated offsets
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
	for us : RID in uniform_sets:
		if rd.uniform_set_is_valid(us):
			rd.free_rid(us)
	if rd.compute_pipeline_is_valid(pipeline):
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)
	print(Helpers.system_names.find_key(system_name) + " cleaned up.")
