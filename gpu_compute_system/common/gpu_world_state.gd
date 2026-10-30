extends RefCounted
## Manages GPU VRAM allocations for the simulation, including double-buffered fine float textures,
## atomic integer textures, agent SSBOs, coarse dynamics textures, and auxiliary buffers.
class_name GpuWorldState

## Low-level RenderingDevice API instance used to create and manipulate GPU resources.
var rd : RenderingDevice
## Active world configuration providing grid dimensions and layer counts.
var world_config : WorldConfig

## Pair of texture RIDs for the 512x512 fine float grid, alternating as read and write targets each frame.
var float_state_textures : Array[RID]
## Uniforms mapped to Set 0 Binding 1 for reading fine float data in compute shaders.
var float_read_uniforms : Array[RDUniform]
## Uniforms mapped to Set 0 Binding 0 for writing fine float data in compute shaders.
var float_write_uniforms : Array[RDUniform]

## Single-buffered texture RID for the 512x512 atomic uint grid (Binding 2), holding conserved masses.
var atomic_state_texture : RID
## Uniform mapped to Set 0 Binding 2 for atomic read/write operations (e.g. imageAtomicAdd).
var atomic_uniform : RDUniform
## Single-buffered r16f texture RID (Binding 5) receiving normalized visual values from the atomic grid.
var atomic_visual_texture : RID
## Uniform mapped to Set 0 Binding 5 for shaders to write normalized atomic visualization data.
var atomic_visual_uniform : RDUniform

## Pair of storage buffer RIDs for double-buffering Lagrangian agent clusters in VRAM.
var ssbo_state_buffers : Array[RID]
## Uniforms mapped to Set 0 Binding 4 for reading previous-frame SSBO agent data.
var ssbo_read_uniforms : Array[RDUniform]
## Uniforms mapped to Set 0 Binding 3 for writing new-frame SSBO agent data.
var ssbo_write_uniforms : Array[RDUniform]

## Pair of texture RIDs for the 64x64 coarse atmospheric dynamics grid, alternating each frame.
var coarse_state_textures : Array[RID]
## Uniforms mapped to Set 0 Binding 6 for writing coarse dynamics data in compute shaders.
var coarse_write_uniforms : Array[RDUniform]
## Uniforms mapped to Set 0 Binding 7 for reading coarse dynamics data in compute shaders.
var coarse_read_uniforms : Array[RDUniform]

## Per-domain auxiliary storage buffers (e.g. SpellBook, ArchetypeLimits) keyed by simulation domain.
var aux_ssbo_buffers : Dictionary [int, RID]
## Per-domain auxiliary storage buffer uniforms keyed by simulation domain.
var aux_ssbo_uniforms : Dictionary [int, RDUniform]

## Double-buffered ping-pong storage buffer RIDs for accumulating Impact Currency at Binding 12.
var impact_currency_buffers : Array[RID]
## Uniforms mapped to Set 0 Binding 12 for the two Impact Currency ping-pong halves.
var impact_currency_uniforms : Array[RDUniform]
## Index (0 or 1) indicating which Impact Currency buffer half the GPU writes to this cycle.
var impact_currency_active_index : int = 0

## Index (0 or 1) indicating which ping-pong texture/buffer the GPU reads from this frame.
var read_world_state_index : int = 0
## Index (0 or 1) indicating which ping-pong texture/buffer the GPU writes to this frame.
var write_world_state_index : int:
	get:
		if float_state_textures.size() == 0:
			return 0
		return (read_world_state_index + 1) % float_state_textures.size()

## Emitted periodically during async save readbacks reporting progress.
signal save_progress(current: int, total: int)
## Emitted when all pending asynchronous save readback tasks have completed.
signal _save_data_complete

## Emitted when buffer swapping finishes, signaling that a new read frame is ready.
signal state_updated(read_index: int)

## Counter tracking outstanding async GPU texture and buffer readback tasks.
var _pending_save_tasks: int = 0
## Accumulator holding captured layer data during save operations.
var _async_save_layers: Array[SaveSimLayer] = []


## Initializes textures, buffers, and shader uniforms on the provided RenderingDevice.
func _init(render_device: RenderingDevice, config: WorldConfig) -> void:
	rd = render_device
	world_config = config
	_setup_world_state_textures()
	_setup_world_state_uniforms()


## Allocates fine float, atomic, SSBO, coarse, and auxiliary GPU resources in VRAM.
func _setup_world_state_textures() -> void:
	# Allocate double-buffered 512x512 R16_SFLOAT texture arrays for fine grid physics.
	float_state_textures.resize(2)
	var float_tx_format : RDTextureFormat = RDTextureFormat.new()
	float_tx_format.texture_type = rd.TEXTURE_TYPE_2D_ARRAY
	
	# Godot Texture2DArrayRD requires at least 2 layers in the array format even if only 1 is used.
	float_tx_format.array_layers = maxi(GameStateManager.total_float_layers, 2)
	float_tx_format.width = world_config.world_width
	float_tx_format.height = world_config.world_height
	float_tx_format.format = rd.DATA_FORMAT_R16_SFLOAT
	float_tx_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	var float_view : RDTextureView = RDTextureView.new()
	
	float_state_textures[0] = rd.texture_create(float_tx_format, float_view)
	float_state_textures[1] = rd.texture_create(float_tx_format, float_view)

	# Allocate single-buffered R32_UINT texture array for atomic operations and mass conservation.
	var atomic_tx_format : RDTextureFormat = RDTextureFormat.new()
	atomic_tx_format.texture_type = rd.TEXTURE_TYPE_2D_ARRAY
	atomic_tx_format.array_layers = maxi(GameStateManager.total_atomic_layers, 2)
	atomic_tx_format.width = world_config.world_width
	atomic_tx_format.height = world_config.world_height
	atomic_tx_format.format = rd.DATA_FORMAT_R32_UINT
	atomic_tx_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)

	var atomic_view : RDTextureView = RDTextureView.new()
	atomic_state_texture = rd.texture_create(atomic_tx_format, atomic_view)
	# Allocate companion R16_SFLOAT texture for normalized visualization of atomic data in standard materials.
	atomic_visual_texture = rd.texture_create(float_tx_format, atomic_view)

	# Allocate double-buffered storage buffers for Lagrangian agent populations.
	ssbo_state_buffers.resize(2)
	var ssbo_size_in_bytes : int = maxi(GameStateManager.total_ssbo_clusters, 1) * Helpers.POPULATION_CLUSTER_BYTE_SIZE 
	var buffer_bytes : PackedByteArray = PackedByteArray()
	buffer_bytes.resize(ssbo_size_in_bytes)
	buffer_bytes.fill(0)
	ssbo_state_buffers[0] = rd.storage_buffer_create(ssbo_size_in_bytes, buffer_bytes)
	ssbo_state_buffers[1] = rd.storage_buffer_create(ssbo_size_in_bytes, buffer_bytes)

	# Allocate double-buffered 64x64 R32_SFLOAT texture arrays for coarse atmospheric dynamics.
	coarse_state_textures.resize(2)
	var coarse_tx_format : RDTextureFormat = RDTextureFormat.new()
	coarse_tx_format.texture_type = rd.TEXTURE_TYPE_2D_ARRAY
	
	coarse_tx_format.array_layers = maxi(GameStateManager.total_coarse_layers, 2)
	coarse_tx_format.width = int(world_config.world_width/8.0)
	coarse_tx_format.height = int(world_config.world_height/8.0)
	coarse_tx_format.format = rd.DATA_FORMAT_R32_SFLOAT
	coarse_tx_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	var coarse_view : RDTextureView = RDTextureView.new()
	coarse_state_textures[0] = rd.texture_create(coarse_tx_format, coarse_view)
	coarse_state_textures[1] = rd.texture_create(coarse_tx_format, coarse_view)

	# Allocate double-buffered storage buffers for accumulating Impact Currency without race conditions.
	impact_currency_buffers.resize(2)
	var currency_bytes : PackedByteArray = PackedByteArray()
	currency_bytes.resize(Helpers.impact_currency_byte_size)
	currency_bytes.fill(0)
	impact_currency_buffers[0] = rd.storage_buffer_create(Helpers.impact_currency_byte_size, currency_bytes)
	impact_currency_buffers[1] = rd.storage_buffer_create(Helpers.impact_currency_byte_size, currency_bytes)

	# Allocate dedicated read-only auxiliary buffers for spells and species archetypes.
	for domain : int in Helpers.aux_ssbo_struct_sizes.keys():
		var struct_size : int = Helpers.aux_ssbo_struct_sizes[domain]
		var count : int = Helpers.aux_ssbo_counts[domain]
		var total_bytes : int = struct_size * count
		var aux_bytes : PackedByteArray = PackedByteArray()
		aux_bytes.resize(total_bytes)
		aux_bytes.fill(0)
		aux_ssbo_buffers[domain] = rd.storage_buffer_create(total_bytes, aux_bytes)


func _setup_world_state_uniforms() -> void:
	float_write_uniforms.resize(float_state_textures.size())
	float_read_uniforms.resize(float_state_textures.size())
	for i : int in float_state_textures.size():
		var write_u : RDUniform = RDUniform.new()
		write_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		write_u.binding = 0
		write_u.add_id(float_state_textures[i])
		float_write_uniforms[i] = write_u
		
		var read_u : RDUniform = RDUniform.new()
		read_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		read_u.binding = 1
		read_u.add_id(float_state_textures[i])
		float_read_uniforms[i] = read_u
	
	atomic_visual_uniform = RDUniform.new()
	atomic_visual_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	atomic_visual_uniform.binding = 5
	atomic_visual_uniform.add_id(atomic_visual_texture)
	
	atomic_uniform = RDUniform.new()
	atomic_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	# Standard Sim Binding 2: Atomic RW
	atomic_uniform.binding = 2
	atomic_uniform.add_id(atomic_state_texture)
	
	ssbo_write_uniforms.resize(ssbo_state_buffers.size())
	ssbo_read_uniforms.resize(ssbo_state_buffers.size())
	for i : int in ssbo_state_buffers.size():
		var write_u : RDUniform = RDUniform.new()
		write_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		# Standard Sim Binding 3: SSBO Write
		write_u.binding = 3
		write_u.add_id(ssbo_state_buffers[i])
		ssbo_write_uniforms[i] = write_u
		
		var read_u : RDUniform = RDUniform.new()
		read_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		# Standard Sim Binding 4: SSBO Read
		read_u.binding = 4
		read_u.add_id(ssbo_state_buffers[i])
		ssbo_read_uniforms[i] = read_u

	coarse_write_uniforms.resize(coarse_state_textures.size())
	coarse_read_uniforms.resize(coarse_state_textures.size())
	for i : int in coarse_state_textures.size():
		var write_u : RDUniform = RDUniform.new()
		write_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		# Standard Sim Binding 6: Coarse Write
		write_u.binding = 6
		write_u.add_id(coarse_state_textures[i])
		coarse_write_uniforms[i] = write_u
		
		var read_u : RDUniform = RDUniform.new()
		read_u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		# Standard Sim Binding 7: Coarse Read
		read_u.binding = 7
		read_u.add_id(coarse_state_textures[i])
		coarse_read_uniforms[i] = read_u

	# AUXILIARY SSBO UNIFORMS
	# ImpactCurrency (binding 12) — one uniform per ping-pong half.
	impact_currency_uniforms.resize(2)
	for i : int in impact_currency_buffers.size():
		var currency_u : RDUniform = RDUniform.new()
		currency_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		currency_u.binding = Helpers.aux_ssbo_bindings["IMPACT_CURRENCY"]
		currency_u.add_id(impact_currency_buffers[i])
		impact_currency_uniforms[i] = currency_u

	# Per-domain aux SSBOs (binding 10 = SpellBook, binding 11 = ArchetypeLimits).
	for domain : int in aux_ssbo_buffers.keys():
		var aux_u : RDUniform = RDUniform.new()
		aux_u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		# PLAYER_ACTIONS → binding 10 (SpellBook), FAUNA → binding 11 (ArchetypeLimits)
		match domain:
			Helpers.sim_layers.PLAYER_ACTIONS:
				aux_u.binding = Helpers.aux_ssbo_bindings["SPELLBOOK"]
			Helpers.sim_layers.FAUNA:
				aux_u.binding = Helpers.aux_ssbo_bindings["ARCHETYPE_LIMITS"]
			_:
				push_error("GpuWorldState: No aux SSBO binding assigned for domain %d" % domain)
				continue
		aux_u.add_id(aux_ssbo_buffers[domain])
		aux_ssbo_uniforms[domain] = aux_u
	return

## Destructor: Frees all allocated VRAM automatically when object is destroyed.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if rd == null:
			return
		for i : int in float_state_textures.size():
			if rd.texture_is_valid(float_state_textures[i]):
				rd.free_rid(float_state_textures[i])
		if rd.texture_is_valid(atomic_state_texture):
			rd.free_rid(atomic_state_texture)
		for i : int in ssbo_state_buffers.size():
			if rd.texture_is_valid(ssbo_state_buffers[i]):
				rd.free_rid(ssbo_state_buffers[i])
		for i : int in coarse_state_textures.size():
			if rd.texture_is_valid(coarse_state_textures[i]):
				rd.free_rid(coarse_state_textures[i])
		# AUXILIARY SSBOs
		for buf : RID in impact_currency_buffers:
			if buf.is_valid():
				rd.free_rid(buf)
		for domain : int in aux_ssbo_buffers.keys():
			var buf : RID = aux_ssbo_buffers[domain]
			if buf.is_valid():
				rd.free_rid(buf)

func swap_state(override_index : int = -1) -> void:
	if override_index >= 0:
		read_world_state_index = override_index
	else:
		read_world_state_index = write_world_state_index

func end_frame() -> void:
	state_updated.emit(read_world_state_index)

	# AUXILIARY SSBO ACCESSORS & UTILITIES

## Returns the aux SSBO uniform for the given domain (binding 10 or 11), or null if none exists.
func get_aux_ssbo_uniform(domain: Helpers.sim_layers) -> RDUniform:
	if aux_ssbo_uniforms.has(domain):
		return aux_ssbo_uniforms[domain]
	return null

## Returns the currently GPU-writable ImpactCurrency uniform (binding 12).
func get_impact_currency_uniform() -> RDUniform:
	return impact_currency_uniforms[impact_currency_active_index]

## Swaps the active Impact Currency buffer half so the CPU can extract one half while the GPU writes to the other.
func swap_impact_currency() -> void:
	impact_currency_active_index = (impact_currency_active_index + 1) % impact_currency_buffers.size()

## Uploads CPU-prepared data (e.g. spellbook, archetype limits) to a per-domain aux SSBO.
func upload_aux_ssbo_data(domain: Helpers.sim_layers, data: PackedByteArray) -> void:
	if not aux_ssbo_buffers.has(domain):
		push_error("GpuWorldState: No aux SSBO buffer for domain %d" % domain)
		return
	rd.buffer_update(aux_ssbo_buffers[domain], 0, data.size(), data)

## Partial update of a per-domain aux SSBO (e.g. a single spell definition on level-up).
func upload_aux_ssbo_region(domain: Helpers.sim_layers, data: PackedByteArray, offset: int) -> void:
	if not aux_ssbo_buffers.has(domain):
		push_error("GpuWorldState: No aux SSBO buffer for domain %d" % domain)
		return
	rd.buffer_update(aux_ssbo_buffers[domain], offset, data.size(), data)

## Synchronizes the inactive double-buffer with the active read buffer so unsimulated layers remain identical across buffer swaps.
func sync_double_buffers() -> void:
	if not rd:
		return
	var width : int = world_config.world_width
	var height : int = world_config.world_height
	var total_layers : int = maxi(GameStateManager.total_float_layers, 2)
	
	var src_idx : int = read_world_state_index
	var dst_idx : int = (read_world_state_index + 1) % float_state_textures.size()
	
	if float_state_textures.size() >= 2 and rd.texture_is_valid(float_state_textures[src_idx]) and rd.texture_is_valid(float_state_textures[dst_idx]):
		for layer_idx : int in range(total_layers):
			rd.texture_copy(
				float_state_textures[src_idx],
				float_state_textures[dst_idx],
				Vector3(0, 0, 0),
				Vector3(0, 0, 0),
				Vector3(width, height, 1),
				0, 0,
				layer_idx,
				layer_idx
			)
			
	if ssbo_state_buffers.size() >= 2 and ssbo_state_buffers[src_idx].is_valid() and ssbo_state_buffers[dst_idx].is_valid():
		var ssbo_size : int = maxi(GameStateManager.total_ssbo_clusters, 1) * Helpers.POPULATION_CLUSTER_BYTE_SIZE
		rd.buffer_copy(ssbo_state_buffers[src_idx], ssbo_state_buffers[dst_idx], 0, 0, ssbo_size)

	if coarse_state_textures.size() >= 2 and rd.texture_is_valid(coarse_state_textures[src_idx]) and rd.texture_is_valid(coarse_state_textures[dst_idx]):
		var coarse_w : int = int(world_config.world_width / 8.0)
		var coarse_h : int = int(world_config.world_height / 8.0)
		var coarse_layers_count : int = maxi(GameStateManager.total_coarse_layers, 2)
		for layer_idx : int in range(coarse_layers_count):
			rd.texture_copy(
				coarse_state_textures[src_idx],
				coarse_state_textures[dst_idx],
				Vector3(0, 0, 0),
				Vector3(0, 0, 0),
				Vector3(coarse_w, coarse_h, 1),
				0, 0,
				layer_idx,
				layer_idx
			)

func get_float_array_read_texture_RID() -> RID: 
	return float_state_textures[read_world_state_index]
	
func get_atomic_array_read_texture_RID() -> RID: 
	return atomic_state_texture

func get_coarse_array_read_texture_RID() -> RID:
	return coarse_state_textures[read_world_state_index]

func get_save_data_async() -> Array[SaveSimLayer]:
	_async_save_layers.clear()
	
	var total_float: int = 0
	for layer_enum : Helpers.sim_layers in GameStateManager.float_layer_to_indices_map.keys():
		if layer_enum != Helpers.sim_layers.INVALID: total_float += GameStateManager.float_layer_to_indices_map[layer_enum].size()
		
	var total_atomic: int = 0
	for layer_enum : Helpers.sim_layers in GameStateManager.atomic_layer_to_indices_map.keys():
		if layer_enum != Helpers.sim_layers.INVALID: total_atomic += GameStateManager.atomic_layer_to_indices_map[layer_enum].size()
		
	var total_ssbo: int = 0
	for layer_enum : Helpers.sim_layers in GameStateManager.ssbo_layer_to_indices_map.keys():
		if layer_enum != Helpers.sim_layers.INVALID:
			var info : PackedInt32Array = GameStateManager.ssbo_layer_to_indices_map[layer_enum]
			if info.size() == 2 and info[1] > 0:
				total_ssbo += 1

	var total_tasks : int = total_float + total_atomic + total_ssbo
	_pending_save_tasks = total_tasks
	
	if total_tasks == 0:
		return []

	# FLOAT GRID
	for layer_enum : int in GameStateManager.float_layer_to_indices_map.keys():
		if layer_enum == Helpers.sim_layers.INVALID: continue
		var indices : PackedInt32Array = GameStateManager.float_layer_to_indices_map[layer_enum]
		for i : int in range(indices.size()):
			var absolute_index : int = indices[i]
			var callable : Callable = _on_async_data_received.bind(SaveSimLayer.data_type.FLOAT, layer_enum, i, total_tasks)
			var err : Error = rd.texture_get_data_async(float_state_textures[read_world_state_index], absolute_index, callable)
			if err != OK:
				push_error("Failed async texture fetch for float layer %s:%d" % [layer_enum, i])
				_decrement_pending_save_task(total_tasks)

	# ATOMIC GRID
	for layer_enum : int in GameStateManager.atomic_layer_to_indices_map.keys():
		if layer_enum == Helpers.sim_layers.INVALID: continue
		var indices : PackedInt32Array = GameStateManager.atomic_layer_to_indices_map[layer_enum]
		for i : int in range(indices.size()):
			var absolute_index : int = indices[i]
			var callable : Callable = _on_async_data_received.bind(SaveSimLayer.data_type.ATOMIC, layer_enum, i, total_tasks)
			var err : Error = rd.texture_get_data_async(atomic_state_texture, absolute_index, callable)
			if err != OK:
				push_error("Failed async texture fetch for atomic layer %s:%d" % [layer_enum, i])
				_decrement_pending_save_task(total_tasks)
			
	# SSBO GRID
	for layer_enum : int in GameStateManager.ssbo_layer_to_indices_map.keys():
		if layer_enum == Helpers.sim_layers.INVALID: continue
		var info : PackedInt32Array = GameStateManager.ssbo_layer_to_indices_map[layer_enum]
		if info.size() == 2 and info[1] > 0:
			var offset_elements : int = info[0]
			var capacity : int = info[1]
			var offset_bytes : int = offset_elements * Helpers.POPULATION_CLUSTER_BYTE_SIZE
			var size_bytes : int = capacity * Helpers.POPULATION_CLUSTER_BYTE_SIZE
			
			var callable : Callable = _on_async_data_received.bind(SaveSimLayer.data_type.SSBO, layer_enum, 0, total_tasks)
			var err : Error = rd.buffer_get_data_async(ssbo_state_buffers[read_world_state_index], callable, offset_bytes, size_bytes)
			if err != OK:
				push_error("Failed async buffer fetch for ssbo layer %s" % layer_enum)
				_decrement_pending_save_task(total_tasks)

	if _pending_save_tasks > 0:
		await _save_data_complete
	return _async_save_layers

func _decrement_pending_save_task(total_tasks: int) -> void:
	_pending_save_tasks -= 1
	var completed : int = total_tasks - _pending_save_tasks
	save_progress.emit(completed, total_tasks)
	
	if _pending_save_tasks == 0:
		_save_data_complete.emit()

func _on_async_data_received(data: PackedByteArray, layer_data_type: int, layer_enum: int, sub_layer_int: int, total_tasks: int) -> void:
	var sl : SaveSimLayer = SaveSimLayer.new()
	sl.layer_data_type = layer_data_type as SaveSimLayer.data_type
	sl.sim_layer_int = layer_enum
	sl.sim_layer_name = Helpers.sim_layers.find_key(layer_enum)
	sl.sub_layer_int = sub_layer_int
	
	match sl.layer_data_type:
		SaveSimLayer.data_type.FLOAT:
			sl.sub_layer_name = Helpers.float_sub_layer_names[layer_enum][sub_layer_int]
			sl.data_file_name = "float_%s_%s.dat" % [sl.sim_layer_name, sl.sub_layer_name]
			sl.image_format_hint = Image.FORMAT_RH
		SaveSimLayer.data_type.ATOMIC:
			sl.sub_layer_name = Helpers.atomic_sub_layer_names[layer_enum][sub_layer_int]
			sl.data_file_name = "atomic_%s_%s.dat" % [sl.sim_layer_name, sl.sub_layer_name]
		SaveSimLayer.data_type.SSBO:
			if Helpers.ssbo_sub_layer_names[layer_enum].size() > 0:
				sl.sub_layer_name = Helpers.ssbo_sub_layer_names[layer_enum][0]
			else:
				sl.sub_layer_name = "CLUSTERS"
			sl.data_file_name = "ssbo_%s.dat" % [sl.sim_layer_name]

	sl.temporary_data = data
	_async_save_layers.append(sl)
	
	_decrement_pending_save_task(total_tasks)

func load_save_data(save_layers: Array[SaveSimLayer]) -> Error:
	var success : bool = true
	for sl : SaveSimLayer in save_layers:
		if sl.sim_layer_int == Helpers.sim_layers.INVALID:
			continue
			
		match sl.layer_data_type:
			SaveSimLayer.data_type.FLOAT:
				var indices : PackedInt32Array = GameStateManager.float_layer_to_indices_map.get(sl.sim_layer_int, PackedInt32Array())
				if sl.sub_layer_int >= indices.size():
					push_error("Save data mismatch: Float sub-layer index out of bounds for %s" % sl.sim_layer_name)
					success = false
					continue
				var absolute_index : int = indices[sl.sub_layer_int]
				
				var expected_size : int = world_config.world_width * world_config.world_height * 2 # R16_SFLOAT is 2 bytes
				if sl.temporary_data.size() != expected_size:
					push_error("Save data size mismatch for float layer %s: expected %d, got %d" % [sl.data_file_name, expected_size, sl.temporary_data.size()])
					success = false
					continue
					
				if rd.texture_is_valid(float_state_textures[0]) and rd.texture_is_valid(float_state_textures[1]):
					var err1 : Error = rd.texture_update(float_state_textures[0], absolute_index, sl.temporary_data)
					var err2 : Error = rd.texture_update(float_state_textures[1], absolute_index, sl.temporary_data)
					if err1 != OK or err2 != OK:
						success = false
				else:
					success = false
				
			SaveSimLayer.data_type.ATOMIC:
				var indices : PackedInt32Array = GameStateManager.atomic_layer_to_indices_map.get(sl.sim_layer_int, PackedInt32Array())
				if sl.sub_layer_int >= indices.size():
					push_error("Save data mismatch: Atomic sub-layer index out of bounds for %s" % sl.sim_layer_name)
					success = false
					continue
				var absolute_index : int = indices[sl.sub_layer_int]
				
				var expected_size : int = world_config.world_width * world_config.world_height * 4 # R32_UINT is 4 bytes
				if sl.temporary_data.size() != expected_size:
					push_error("Save data size mismatch for atomic layer %s: expected %d, got %d" % [sl.data_file_name, expected_size, sl.temporary_data.size()])
					success = false
					continue
					
				if rd.texture_is_valid(atomic_state_texture):
					var err : Error = rd.texture_update(atomic_state_texture, absolute_index, sl.temporary_data)
					if err != OK:
						success = false
				else:
					success = false
					
			SaveSimLayer.data_type.SSBO:
				var info : PackedInt32Array = GameStateManager.ssbo_layer_to_indices_map.get(sl.sim_layer_int, PackedInt32Array())
				if info.size() != 2:
					continue
				var offset_bytes : int = info[0] * Helpers.POPULATION_CLUSTER_BYTE_SIZE
				var expected_size : int = info[1] * Helpers.POPULATION_CLUSTER_BYTE_SIZE
				
				if sl.temporary_data.size() != expected_size:
					push_error("Save data size mismatch for SSBO layer %s: expected %d, got %d" % [sl.data_file_name, expected_size, sl.temporary_data.size()])
					success = false
					continue
					
				if ssbo_state_buffers[0].is_valid() and ssbo_state_buffers[1].is_valid():
					var err1 : Error = rd.buffer_update(ssbo_state_buffers[0], offset_bytes, expected_size, sl.temporary_data)
					var err2 : Error = rd.buffer_update(ssbo_state_buffers[1], offset_bytes, expected_size, sl.temporary_data)
					if err1 != OK or err2 != OK:
						success = false
				else:
					success = false
					
		# RAM cleanup mitigation
		sl.temporary_data = PackedByteArray()
		
	return OK if success else Error.ERR_INVALID_DATA
