extends RefCounted
class_name GpuWorldState

var rd : RenderingDevice
var world_config : WorldConfig

# These are RIDs to the Image2DArray and buffers that hold the world states. 
## An array of two texture RIDs used for double-buffering float data.
var float_state_textures : Array[RID]
## Uniforms mapped to binding 1 for reading float state.
var float_read_uniforms : Array[RDUniform]
## Uniforms mapped to binding 0 for writing float state.
var float_write_uniforms : Array[RDUniform]

## Texture RID for the atomic integer grid.
var atomic_state_texture : RID
## Uniform mapped to binding 2 for atomic read/write operations.
var atomic_uniform : RDUniform
## Texture RID for the atomic integer grid.
var atomic_visual_texture : RID
## Uniform mapped to binding 2 for atomic read/write operations.
var atomic_visual_uniform : RDUniform

## An array of two SSBO RIDs used for double-buffering SSBO state.
var ssbo_state_buffers : Array[RID]
var ssbo_read_uniforms : Array[RDUniform]
var ssbo_write_uniforms : Array[RDUniform]

## Array of two texture RIDs used for double-buffering coarse float data (64x64xCOUNT, R32_SFLOAT).
var coarse_state_textures : Array[RID]
## Uniforms mapped to binding 6 for writing coarse state.
var coarse_write_uniforms : Array[RDUniform]
## Uniforms mapped to binding 7 for reading coarse state.
var coarse_read_uniforms : Array[RDUniform]

# ==========================================
# AUXILIARY SSBOs (Bindings 8, 10, 11, 12)
# Per-domain lookup tables and event-logging buffers.
# ==========================================

## Per-domain aux SSBO buffers (bindings 10, 11). Keyed by Helpers.sim_layers.
var aux_ssbo_buffers : Dictionary [int, RID]
## Per-domain aux SSBO uniforms. Keyed by Helpers.sim_layers.
var aux_ssbo_uniforms : Dictionary [int, RDUniform]

## Double-buffered ImpactCurrency RIDs (binding 12, ping-pong). Ping-pong is
## required because the window between the CPU's async readback snapshot and
## its buffer_update(0) reset is multi-frame; any GPU atomicAdd landing in
## that window on a single buffer would be silently destroyed (plan §2.7).
var impact_currency_buffers : Array[RID]
## ImpactCurrency uniforms, one per half.
var impact_currency_uniforms : Array[RDUniform]
## Which ImpactCurrency half is GPU-writable this cycle.
var impact_currency_active_index : int = 0

## Index tracking which state buffer should be read from this frame.
var read_world_state_index : int = 0
## Index tracking which state buffer should be written to this frame.
var write_world_state_index : int:
	get:
		if float_state_textures.size() == 0:
			return 0
		return (read_world_state_index + 1) % float_state_textures.size()

signal state_updated(read_index: int)

func _init(render_device: RenderingDevice, config: WorldConfig) -> void:
	rd = render_device
	world_config = config
	_setup_world_state_textures()
	_setup_world_state_uniforms()

func _setup_world_state_textures() -> void:
	# FLOAT GRID
	float_state_textures.resize(2)
	var float_tx_format : RDTextureFormat = RDTextureFormat.new()
	float_tx_format.texture_type = rd.TEXTURE_TYPE_2D_ARRAY
	
	# Texture2DArrayRD requires at least 2 layers in Godot, even if only 1 is used
	float_tx_format.array_layers = maxi(GameStateManager.total_float_layers, 2)
	float_tx_format.width = world_config.world_width
	float_tx_format.height = world_config.world_height
	# R16 float channel
	float_tx_format.format = rd.DATA_FORMAT_R16_SFLOAT
	float_tx_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	#need to create a view to specify the number of layers in the array, even though we're only using 1 layer here
	var float_view : RDTextureView = RDTextureView.new()
	
	float_state_textures[0] = rd.texture_create(float_tx_format, float_view)
	float_state_textures[1] = rd.texture_create(float_tx_format, float_view)

	# ATOMIC GRID
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
	# uses the float tx format for uniformity, since this texture normalises the atomic grid data
	atomic_visual_texture = rd.texture_create(float_tx_format, atomic_view)

	# SHADER STORAGE BUFFER OBJECT (SSBO)
	ssbo_state_buffers.resize(2)
	var ssbo_size_in_bytes : int = maxi(GameStateManager.total_ssbo_clusters, 1) * Helpers.POPULATION_CLUSTER_BYTE_SIZE 
	var buffer_bytes : PackedByteArray = PackedByteArray()
	buffer_bytes.resize(ssbo_size_in_bytes)
	buffer_bytes.fill(0)
	ssbo_state_buffers[0] = rd.storage_buffer_create(ssbo_size_in_bytes, buffer_bytes)
	ssbo_state_buffers[1] = rd.storage_buffer_create(ssbo_size_in_bytes, buffer_bytes)

	# COARSE GRID
	coarse_state_textures.resize(2)
	var coarse_tx_format : RDTextureFormat = RDTextureFormat.new()
	coarse_tx_format.texture_type = rd.TEXTURE_TYPE_2D_ARRAY
	
	coarse_tx_format.array_layers = maxi(GameStateManager.total_coarse_layers, 2)
	coarse_tx_format.width = int(world_config.world_width/8.0)
	coarse_tx_format.height = int(world_config.world_height/8.0)
	# R32 Float channel
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

	# AUXILIARY SSBOs
	# ImpactCurrency (binding 12) — double-buffered ping-pong (plan §2.7).
	# (Binding 8's EventBuffer was decommissioned with the geothermal POC at
	# plan §8.4; biome causation travels via the BIOME_TYPE texel instead.)
	impact_currency_buffers.resize(2)
	var currency_bytes : PackedByteArray = PackedByteArray()
	currency_bytes.resize(Helpers.impact_currency_byte_size)
	currency_bytes.fill(0)
	impact_currency_buffers[0] = rd.storage_buffer_create(Helpers.impact_currency_byte_size, currency_bytes)
	impact_currency_buffers[1] = rd.storage_buffer_create(Helpers.impact_currency_byte_size, currency_bytes)

	# Per-domain aux SSBOs (spellbook, archetype limits).
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

# ==========================================
# AUXILIARY SSBO ACCESSORS & UTILITIES
# ==========================================

## Returns the aux SSBO uniform for the given domain (binding 10 or 11), or null if none exists.
func get_aux_ssbo_uniform(domain: Helpers.sim_layers) -> RDUniform:
	if aux_ssbo_uniforms.has(domain):
		return aux_ssbo_uniforms[domain]
	return null

## Returns the currently GPU-writable ImpactCurrency uniform (binding 12).
func get_impact_currency_uniform() -> RDUniform:
	return impact_currency_uniforms[impact_currency_active_index]

## Swaps the active ImpactCurrency half. Called by the CPU consumer immediately
## after a successful async extraction request (plan §2.7): the GPU's next
## dispatch accumulates into the other half, so the just-extracted half can be
## zeroed at leisure without destroying GPU adds.
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
