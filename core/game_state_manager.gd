extends Node
## Central coordinator owning `WorldConfig`, `GpuWorldState`, simulation timekeeping,
## world generation/runtime lifecycle, save/load, and CPU biome telemetry managers.
class_name GameStateManager 

## Planet mesh instance displaying the simulated globe in the active 3D scene.
@export var world : MeshInstance3D
## Active 3D camera viewing the planet mesh.
@export var camera : Camera3D 

## World configuration resource applied on initialization and whenever reassigned in the Inspector.
@export var active_world_config : WorldConfig = preload("uid://p4kta36gfome"): 
	set(value):
		active_world_config = value
		initialise_game_state()

## Ordered player spell registry whose array index defines both the SSBO slot and `ACTION_KEY` bit position.
@export var active_spellbook : SpellbookManager = preload("res://spells/default_spellbook.tres"):
	set(value):
		active_spellbook = value
		_sync_spellbook_manager()

## Globally accessible `WorldConfig` instance; logs an error if read before `initialise_game_state()`.
static var world_config : WorldConfig:
	get:
		if not world_config:
			push_error("Game State has no World Config loaded")
		return world_config

## Singleton scene-tree instance of `GameStateManager`.
static var instance : GameStateManager

## Active GPU VRAM buffer and texture state (`GpuWorldState`) for the current world.
static var current_world_state : GpuWorldState

## Globally accessible `SpellbookManager` synchronized with `active_spellbook`.
static var spellbook_manager : SpellbookManager

## Active `SphereCursorPicker` handling 3D globe raycasting and click/hover events.
static var cursor_picker : SphereCursorPicker

## Active `SaveManager` handling disk serialization and slot persistence.
static var save_manager : SaveManager

## Active `BiomeSnapshotManager` polling and diffing the GPU `BIOME_TYPE` atomic layer.
static var biome_snapshot_manager : BiomeSnapshotManager

## Active `RegionGraphManager` maintaining contiguous biome regions and chronicle milestones.
static var region_graph_manager : RegionGraphManager

## Active `AeonLog` storing Year-prefixed planetary chronicle entries.
static var aeon_log : AeonLog

## True when the current bootstrap originated from `load_game()` rather than `generate_world()`.
static var _loaded_world_bootstrap : bool = false

## Active `BiomeEconomy` awarding Impact Currency from player-attributed biome transitions.
static var biome_economy : BiomeEconomy

## Maps `Helpers.sim_layers` domains to their flat slice indices in the Fine Float Grid.
static var float_layer_to_indices_map : Dictionary[Helpers.sim_layers, PackedInt32Array]
## Total number of slices allocated in the Fine Float Grid (`r16f`).
static var total_float_layers : int
## Maps `Helpers.sim_layers` domains to their flat slice indices in the Atomic Grid.
static var atomic_layer_to_indices_map : Dictionary[Helpers.sim_layers, PackedInt32Array]
## Total number of slices allocated in the Atomic Grid (`r32ui`).
static var total_atomic_layers : int
## Maps `Helpers.sim_layers` domains to their `[start_offset, capacity]` bounds in the Cluster SSBO.
static var ssbo_layer_to_indices_map : Dictionary[Helpers.sim_layers, PackedInt32Array]
## Total number of `PopulationCluster` slots allocated across all SSBO domains.
static var total_ssbo_clusters : int
## Maps `Helpers.coarse_layers` enum values to their slice indices in the Coarse Dynamics Grid.
static var coarse_layer_to_indices_map : Dictionary[Helpers.coarse_layers, int]
## Total number of slices allocated in the Coarse Dynamics Grid (`r32f`).
static var total_coarse_layers : int = 9

## True when runtime simulation stepping is paused.
static var is_paused : bool
## Number of full simulation pipeline dispatches executed per rendered frame (`0..max_sim_speed`).
static var sim_speed : int = 1
## Fixed simulation timestep in seconds per pipeline dispatch (`0.01667 s` = 60 Hz).
static var simDeltaTime : float = 0.01667

## Cumulative whole in-game days elapsed since world creation.
static var elapsed_days : int = 0
## Cumulative whole in-game years elapsed since world creation (`elapsed_days / days_per_year`).
static var elapsed_years : int = 0
## Fractional progress (`[0.0, 1.0)`) through the current in-game day.
static var day_progress : float = 0.0
## Fractional progress (`[0.0, 1.0)`) through the current orbital year.
static var year_progress : float = 0.0

## Active `WorldSimulator` node dispatching runtime compute passes each frame.
var world_simulator : WorldSimulator

## True when Godot is running on an OpenGL rendering driver instead of Vulkan/RenderingDevice.
static var is_opengl : bool = false

## Emitted once `world_config`, `current_world_state`, `save_manager`, `cursor_picker`, and `spellbook_manager` are initialized.
signal game_state_manager_initialised

## Emitted when world generation or save loading finishes and `current_world_state` is bound.
signal world_ready


## Registers this node as the singleton `GameStateManager.instance`.
func _init() -> void:
	instance = self


## Initializes the game state when the node enters the scene tree.
func _ready() -> void:
	var err : Error = initialise_game_state()
	print (err)


## Builds layer index maps from `Helpers`, allocates `GpuWorldState`, ensures child managers exist,
## loads the active spellbook, and emits `game_state_manager_initialised`.
func initialise_game_state() -> Error:
	# Abort if the current rendering driver does not support Vulkan compute (`RenderingDevice`).
	if RenderingServer.get_current_rendering_driver_name().contains("opengl"):
		is_opengl = true
		return Error.ERR_CANT_CREATE
	var rd : RenderingDevice = RenderingServer.get_rendering_device()
	# Lock frame pacing to 60 FPS with VSync disabled to match the fixed 60 Hz simulation timestep.
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 60
	world_config = active_world_config
	
	# Build domain-to-slice lookup maps from Helpers.
	float_layer_to_indices_map = Helpers.create_float_layer_indices_map()
	atomic_layer_to_indices_map = Helpers.create_atomic_layer_indices_map()
	ssbo_layer_to_indices_map = Helpers.create_ssbo_layer_indices_map()
	coarse_layer_to_indices_map = Helpers.create_coarse_layer_indices_map()
	
	# Compute total float texture array slice count.
	var max_index : int = 0
	for indices : PackedInt32Array in float_layer_to_indices_map.values():
		if indices.size() > 0 and indices[-1] > max_index:
			max_index = indices[-1]
	total_float_layers = max_index + 1
	
	# Compute total atomic texture array slice count.
	max_index = 0
	for indices : PackedInt32Array in atomic_layer_to_indices_map.values():
		if indices.size() > 0 and indices[-1] > max_index:
			max_index = indices[-1]
	total_atomic_layers = max_index + 1
	
	total_coarse_layers = Helpers.coarse_layers.COUNT
	
	# Compute total SSBO cluster capacity across all domains.
	var max_cluster_bound : int = 0
	for indices : PackedInt32Array in ssbo_layer_to_indices_map.values():
		if indices.size() == 2:
			var upper_bound : int = indices[0] + indices[1]
			if upper_bound > max_cluster_bound:
				max_cluster_bound = upper_bound
	total_ssbo_clusters = max_cluster_bound
	
	# Allocate VRAM textures and SSBO buffers for the active world configuration.
	current_world_state = GpuWorldState.new(rd, world_config)

	# Locate or instantiate the child SaveManager node.
	if not save_manager:
		var children : Array[Node] = get_children()
		for child : Node in children:
			if child is SaveManager:
				save_manager = child as SaveManager
				break
	if not save_manager:
		save_manager = SaveManager.new()
		add_child(save_manager)
	
	# Locate or instantiate the child SphereCursorPicker node.
	if not cursor_picker:
		var children : Array[Node] = get_children()
		for child : Node in children:
			if child is SphereCursorPicker:
				cursor_picker = child as SphereCursorPicker
				break
	if not cursor_picker:
		cursor_picker = SphereCursorPicker.new()
		add_child(cursor_picker)
	
	# Upload the active spellbook to VRAM and notify listeners that initialization succeeded.
	if world_config and save_manager and cursor_picker:
		spellbook_manager = active_spellbook
		if spellbook_manager:
			spellbook_manager.load_spellbook()
		game_state_manager_initialised.emit()
	
	return Error.OK


## Synchronizes the static `spellbook_manager` reference with `active_spellbook` and uploads it to VRAM.
func _sync_spellbook_manager() -> void:
	spellbook_manager = active_spellbook
	if active_spellbook and current_world_state:
		active_spellbook.load_spellbook()


## Executes the `WorldGenerator` pipeline, binds the biome snapshot and region graph managers,
## emits `world_ready`, and initiates the first GPU `BIOME_TYPE` shadow readback.
func generate_world() -> Error:
	# Pause runtime stepping and run all world generation passes to completion.
	is_paused = true
	_loaded_world_bootstrap = false
	var world_generator : WorldGenerator = WorldGenerator.new()
	self.add_child(world_generator)
	if not world_generator.is_node_ready():
		await world_generator.ready
	await world_generator.generate_world()
	if not world_generator._has_completed:
		await world_generator.on_generation_complete
	else:
		self.remove_child(world_generator)

	# Ensure CPU telemetry managers exist, bind the new GPU state, and trigger bootstrap readback.
	_ensure_biome_snapshot_manager()
	_ensure_region_graph_manager()

	biome_snapshot_manager.bind_world_state(current_world_state)

	world_ready.emit()

	if not biome_snapshot_manager.shadow_ready.is_connected(_on_biome_shadow_ready):
		biome_snapshot_manager.shadow_ready.connect(_on_biome_shadow_ready)
	if not biome_snapshot_manager.transitions_resolved.is_connected(_on_biome_transitions):
		biome_snapshot_manager.transitions_resolved.connect(_on_biome_transitions)
	biome_snapshot_manager.initialize_shadow_from_gpu()
	return OK


## Triggers initial Connected Component Labeling on `region_graph_manager` once `biome_snapshot_manager` finishes bootstrap readback.
static func _on_biome_shadow_ready() -> void:
	if region_graph_manager and biome_snapshot_manager:
		if not region_graph_manager.graph_rebuilt.is_connected(_on_graph_rebuilt):
			region_graph_manager.graph_rebuilt.connect(_on_graph_rebuilt)
		region_graph_manager.suppress_bootstrap_births = _loaded_world_bootstrap
		region_graph_manager.build_from_shadow(
			biome_snapshot_manager.get_shadow_snapshot(),
			world_config.world_width,
			world_config.world_height,
		)


## Logs the opening `AeonLog` chronicle entry once bootstrap region labeling completes.
static func _on_graph_rebuilt(region_count : int) -> void:
	if aeon_log == null:
		return
	# Log a resume entry after save loads or an awakening entry after fresh generation.
	if _loaded_world_bootstrap:
		aeon_log.log_region_named_after_load(region_count)
		_loaded_world_bootstrap = false
	else:
		aeon_log.log_world_awakens()


## Routes each resolved `BIOME_TYPE` transition batch to `region_graph_manager` and `biome_economy`.
static func _on_biome_transitions(transitions : Array) -> void:
	if region_graph_manager:
		region_graph_manager.on_transitions_resolved(transitions)
	if biome_economy:
		biome_economy.process_batch(
			transitions,
			biome_snapshot_manager.get_shadow_texel,
			world_config.world_width,
			world_config.world_height,
		)


## Instantiates `aeon_log`, `biome_economy`, and the child `RegionGraphManager` node if not already present.
func _ensure_region_graph_manager() -> void:
	if region_graph_manager and is_instance_valid(region_graph_manager):
		return
	if aeon_log == null:
		aeon_log = AeonLog.new()
	if biome_economy == null:
		biome_economy = BiomeEconomy.new()
	if world_config:
		biome_economy.bind(world_config.world_width * world_config.world_height)
	region_graph_manager = RegionGraphManager.new()
	region_graph_manager.aeon_log = aeon_log
	add_child(region_graph_manager)


## Instantiates the child `BiomeSnapshotManager` node if not already present.
func _ensure_biome_snapshot_manager() -> void:
	if biome_snapshot_manager and is_instance_valid(biome_snapshot_manager):
		return
	biome_snapshot_manager = BiomeSnapshotManager.new()
	add_child(biome_snapshot_manager)


## Instantiates and starts `WorldSimulator`, unpausing runtime simulation stepping.
func start_simulation() -> Error:
	is_paused = true
	if not world_simulator:
		world_simulator = WorldSimulator.new()
		self.add_child(world_simulator)
	if not world_simulator.is_node_ready():
		await world_simulator.ready
	world_simulator.start_sim()
	is_paused = false
	return OK


## Advances `day_progress`, `elapsed_days`, `year_progress`, and `elapsed_years` at `sim_speed * simDeltaTime` per frame.
@warning_ignore("unused_parameter")
func _process(delta: float) -> void:
	if not is_paused and world_config:
		# Advance simulated day progress where 1.0 real second at 1x speed equals 1 in-game day.
		var dt : float = sim_speed * simDeltaTime
		day_progress += dt
		
		# Roll whole days into `elapsed_days`.
		while day_progress >= 1.0:
			day_progress -= 1.0
			elapsed_days += 1
			
		# Derive normalized orbital year progress and whole elapsed years.
		year_progress = fmod(float(elapsed_days) + day_progress, world_config.days_per_year) / world_config.days_per_year
		elapsed_years = floori(elapsed_days / world_config.days_per_year)


## Removes the active `WorldSimulator` child node to halt runtime simulation dispatches.
static func stop_simulation() -> void:
	if GameStateManager.instance.world_simulator:
		GameStateManager.instance.remove_child(GameStateManager.instance.world_simulator)


## Increments `sim_speed` by 1 up to `world_config.max_sim_speed`.
static func increase_sim_speed() -> void:
	sim_speed = min(sim_speed + 1, world_config.max_sim_speed)


## Decrements `sim_speed` by 1 down to a minimum of 1.
static func decrease_sim_speed() -> void:
	sim_speed = max(sim_speed - 1, 1)


## Sets `sim_speed` to 0 to pause pipeline dispatches.
static func pause_sim_speed() -> void:
	sim_speed = 0


## Sets `sim_speed` to `world_config.max_sim_speed`.
func max_sim_speed() -> void:
	sim_speed = world_config.max_sim_speed

#region Save and Load Interface

## Reads back all GPU simulation layers asynchronously and writes a `SaveGameObject` to `slot`.
func save_game(slot: int) -> Error:
	# Pause simulation and wait two frames so any in-flight GPU work finishes before readback.
	is_paused = true
	await get_tree().process_frame
	await get_tree().process_frame
		
	# Package world configuration metadata and GPU layer readbacks into a SaveGameObject.
	var saved_game : SaveGameObject = SaveGameObject.new()
	
	var config_layer : SaveWorldConfig = SaveWorldConfig.new()
	config_layer.chunk_resolution = world_config.chunk_resolution
	config_layer.chunk_grid_x = world_config.chunk_grid_x
	config_layer.chunk_grid_y = world_config.chunk_grid_y
	config_layer.world_seed = world_config.world_seed
	saved_game.save_layers.append(config_layer)
	var err : Error
	if current_world_state:
		var sim_layers : Array[SaveSimLayer] = await current_world_state.get_save_data_async()
		for sl : SaveSimLayer in sim_layers:
			saved_game.save_layers.append(sl)
			
		err = save_manager.save_to_slot(slot, saved_game)
	else: 
		err = Error.ERR_DOES_NOT_EXIST
	
	is_paused = false
		
	return err


## Loads a `SaveGameObject` from `slot`, restores GPU textures/SSBOs, repairs legacy `BIOME_TYPE` layers if needed,
## and re-initializes the biome snapshot and region graph managers.
func load_game(slot: int) -> Error:
	# Pause simulation and wait two frames before replacing GPU state.
	is_paused = true
	await get_tree().process_frame
	await get_tree().process_frame

	# Deserialize the save slot and separate config metadata from simulation layer payloads.
	var saved_game : SaveGameObject = save_manager.load_world_state(slot)
	if saved_game == null:
		is_paused = false
		return Error.ERR_FILE_NOT_FOUND
		
	var loaded_config : SaveWorldConfig = null
	var sim_layers : Array[SaveSimLayer] = []
	
	for sl : SaveLayer in saved_game.save_layers:
		if sl.layer_type == SaveLayer.save_layer_type.WORLD_CONFIG:
			loaded_config = sl as SaveWorldConfig
		elif sl.layer_type == SaveLayer.save_layer_type.SIM_LAYER:
			var ssl : SaveSimLayer = sl as SaveSimLayer
			sim_layers.append(ssl)
			
	# Reject save files whose grid dimensions do not match the active `WorldConfig`.
	if loaded_config:
		if loaded_config.chunk_resolution != world_config.chunk_resolution or loaded_config.chunk_grid_x != world_config.chunk_grid_x or loaded_config.chunk_grid_y != world_config.chunk_grid_y:
			push_error("Save file world dimensions do not match the current world config. Aborting load.")
			is_paused = false
			return Error.ERR_INVALID_DATA
			
	var rd : RenderingDevice = RenderingServer.get_rendering_device()
	if not rd:
		is_paused = false
		return Error.ERR_UNAVAILABLE

	# Allocate a fresh GpuWorldState, upload saved layers, and rebind CPU telemetry managers.
	current_world_state = GpuWorldState.new(rd, world_config)
	var load_err : Error = current_world_state.load_save_data(sim_layers)
	_loaded_world_bootstrap = true
	
	_ensure_biome_snapshot_manager()
	_ensure_region_graph_manager()
	world_ready.emit()
	biome_snapshot_manager.bind_world_state(current_world_state)
	if not biome_snapshot_manager.shadow_ready.is_connected(_on_biome_shadow_ready):
		biome_snapshot_manager.shadow_ready.connect(_on_biome_shadow_ready)
	if not biome_snapshot_manager.transitions_resolved.is_connected(_on_biome_transitions):
		biome_snapshot_manager.transitions_resolved.connect(_on_biome_transitions)
	await _repair_fill_biome_type_if_legacy()
	biome_snapshot_manager.initialize_shadow_from_gpu()

	is_paused = false

	return load_err


## Detects an uninitialized all-zero `BIOME_TYPE` layer in a loaded save (disambiguated from a true
## all-glacier world by checking for non-zero `LIQUID_VOLUME`) and fills it with `Helpers.BIOME_UNCLASSIFIED`.
func _repair_fill_biome_type_if_legacy() -> void:
	var ws : GpuWorldState = current_world_state
	var rd : RenderingDevice = ws.rd
	var biome_idx : int = atomic_layer_to_indices_map[Helpers.sim_layers.LANDSCAPE][3]
	var liquid_idx : int = atomic_layer_to_indices_map[Helpers.sim_layers.WATER][0]

	# Read back `BIOME_TYPE` and `LIQUID_VOLUME` asynchronously without stalling the main thread.
	var biome_bytes : PackedByteArray = await _read_texture_layer_async(rd, ws.atomic_state_texture, biome_idx)
	if biome_bytes.is_empty():
		push_error("BiomeSnapshotManager: legacy-detection readback failed; skipping repair fill.")
		return
	var any_water : PackedByteArray = await _read_texture_layer_async(rd, ws.atomic_state_texture, liquid_idx)
	var world_has_water : bool = false
	if not any_water.is_empty():
		@warning_ignore("integer_division")
		var cells : int = any_water.size() / 4
		@warning_ignore("integer_division")
		var water_words : int = mini(cells, any_water.size() / 4)
		for i : int in range(0, water_words):
			if any_water.decode_u32(i * 4) != 0:
				world_has_water = true
				break

	# Check whether every `BIOME_TYPE` texel is zero.
	var all_zero : bool = true
	@warning_ignore("integer_division")
	var cells_count : int = biome_bytes.size() / 4
	for i : int in cells_count:
		if biome_bytes.decode_u32(i * 4) != 0:
			all_zero = false
			break

	# Fill `BIOME_TYPE` with `BIOME_UNCLASSIFIED` when all texels are zero in a world that contains liquid water.
	if all_zero and world_has_water:
		var fill : PackedByteArray = PackedByteArray()
		fill.resize(biome_bytes.size())
		fill.fill(0)
		var sentinel : int = Helpers.BIOME_UNCLASSIFIED
		for i : int in cells_count:
			fill.encode_u32(i * 4, sentinel)
		rd.texture_update(ws.atomic_state_texture, biome_idx, fill)
		print("[GameStateManager] Legacy save detected: BIOME_TYPE repair-filled with %d (unclassified); the classifier will self-heal." % sentinel)
	elif all_zero and not world_has_water:
		pass


## Performs an asynchronous single-layer texture readback on `rd` and awaits completion across frames.
func _read_texture_layer_async(rd : RenderingDevice, tex : RID, layer : int) -> PackedByteArray:
	var result : PackedByteArray = PackedByteArray()
	# Box the completion flag in a Dictionary so the lambda mutates it by reference across frames.
	var state : Dictionary = {"done": false}
	var err : Error = rd.texture_get_data_async(tex, layer, func(data : PackedByteArray) -> void:
		result.append_array(data)
		state["done"] = true
	)
	if err != OK:
		return result
	while not state["done"]:
		await get_tree().process_frame
	return result

#endregion
