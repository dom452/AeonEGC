extends Node
class_name GameStateManager 
## The central hub controlling execution phases, ticking the simulation, and interfacing between UI, rendering, and logic.
@export var world : MeshInstance3D
@export var camera : Camera3D 

@export var active_world_config : WorldConfig = preload("uid://p4kta36gfome"): 
	set(value):
		active_world_config = value
		initialise_game_state()

## The spell registry this game instance runs with. Order is identity: array position
## == SSBO slot == ACTION_KEY bit. Owned here so the book is inspectable/editable in
## the editor and (once the save system is revived) savable per-save-file.
@export var active_spellbook : SpellbookManager = preload("res://spells/default_spellbook.tres"):
	set(value):
		active_spellbook = value
		_sync_spellbook_manager()

## The globally active WorldConfig. Will push an error if accessed before being loaded.
static var world_config : WorldConfig:
	get:
		if not world_config:
			push_error("Game State has no World Config loaded")
		return world_config

static var instance : GameStateManager

## The globally active VRAM representation of the world.
static var current_world_state : GpuWorldState

## Globally active SpellbookManager (owned via `active_spellbook`). Null until
## initialise_game_state() assigns it; consumers (debug UI, future spell-selection UI)
## read the ordered spell list from here.
static var spellbook_manager : SpellbookManager

## Globally active SphereCursorPicker (set by whichever system spawns/owns the picker).
## Read by PushConstant_PlayerAction to subscribe to click signals. Null until assigned.
static var cursor_picker : SphereCursorPicker

## Globally active biome snapshot/diff pipeline (event-logging plan §3.1).
## Owned here as a node child of the manager instance; consumers (Phase 3
## RegionGraphManager, economy) subscribe to its signals via this static.
static var biome_snapshot_manager : BiomeSnapshotManager

## Globally active region graph + chronicle (event-logging plan §3.3/§5.1).
## Consumes the snapshot manager's transition batches; owns SimulationRegion
## lifecycle, naming, and the AeonLog. Node child, mirroring the snapshot
## manager's ownership pattern.
static var region_graph_manager : RegionGraphManager

## The planetary chronicle. Separate RefCounted so UI (and the Phase 5
## economy) can read entries without reaching through the graph node.
static var aeon_log : AeonLog

## True for the current bootstrap when the world came from load_game() (as
## opposed to fresh generation). Steers chronicle flavor: a loaded world
## "resumes"; a fresh one "awakens". Cleared once consumed by the
## graph_rebuilt summary.
static var _loaded_world_bootstrap : bool = false

## Phase 5 economy: Impact Currency payouts from biome transitions
## (event-logging plan §4.1/§4.2). RefCounted; consumers read `currency` and
## subscribe to its `currency_gained` signal via this static.
static var biome_economy : BiomeEconomy

## Maps simulation float layers to their absolute corresponding indices in the float grid. Initialized from Helpers.
static var float_layer_to_indices_map : Dictionary[Helpers.sim_layers, PackedInt32Array]
## The total number of floating-point layers managed by the Game State.
static var total_float_layers : int
## Maps simulation atomic layers to their integer indices in the atomic texture grid. Initialized from Helpers.
static var atomic_layer_to_indices_map : Dictionary[Helpers.sim_layers, PackedInt32Array]
## The total number of integer atomic layers managed by the Game State.
static var total_atomic_layers : int
## Maps SSBO-based simulation layers to their structural offset and bound limits.
static var ssbo_layer_to_indices_map : Dictionary[Helpers.sim_layers, PackedInt32Array]
## The total number of SSBO population clusters available in the simulation across all populations.
static var total_ssbo_clusters : int
## Maps coarse simulation layers to their integer indices in the coarse texture grid. Initialized from Helpers.
static var coarse_layer_to_indices_map : Dictionary[Helpers.coarse_layers, int]
## The total number of coarse simulation layers managed by the Game State.
static var total_coarse_layers : int = 9


static var is_paused : bool
static var sim_speed : int = 1
static var simDeltaTime : float = 0.01667

static var elapsed_days : int = 0
static var elapsed_years : int = 0
static var day_progress : float = 0.0
static var year_progress : float = 0.0

var world_simulator : WorldSimulator

static var is_opengl : bool = false

## Emitted when the world configuration has been successfully loaded and is ready for use.
signal game_state_manager_initialised

signal world_ready

## Initializes the game state, requesting map builds from Helpers and calculating the global maximum bounds for VRAM allocations.
func _init() -> void:
	instance = self
	
func _ready() -> void:
	var err : Error = initialise_game_state()
	print (err)


func initialise_game_state() -> Error:
	if RenderingServer.get_current_rendering_driver_name().contains("opengl"):
		is_opengl = true
		return Error.ERR_CANT_CREATE
	var rd : RenderingDevice = RenderingServer.get_rendering_device()
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 60
	world_config = active_world_config
	
	float_layer_to_indices_map = Helpers.create_float_layer_indices_map()
	atomic_layer_to_indices_map = Helpers.create_atomic_layer_indices_map()
	ssbo_layer_to_indices_map = Helpers.create_ssbo_layer_indices_map()
	coarse_layer_to_indices_map = Helpers.create_coarse_layer_indices_map()
	
	var max_index : int = 0
	for indices : PackedInt32Array in float_layer_to_indices_map.values():
		if indices.size() > 0 and indices[-1] > max_index:
			max_index = indices[-1]
	total_float_layers = max_index + 1
	
	max_index = 0
	for indices : PackedInt32Array in atomic_layer_to_indices_map.values():
		if indices.size() > 0 and indices[-1] > max_index:
			max_index = indices[-1]
	total_atomic_layers = max_index + 1
	
	total_coarse_layers = Helpers.coarse_layers.COUNT
	
	var max_cluster_bound : int = 0
	for indices : PackedInt32Array in ssbo_layer_to_indices_map.values():
		if indices.size() == 2:
			var upper_bound : int = indices[0] + indices[1]
			if upper_bound > max_cluster_bound:
				max_cluster_bound = upper_bound
	total_ssbo_clusters = max_cluster_bound
	
	current_world_state = GpuWorldState.new(rd, world_config)

	if not cursor_picker:
		var children : Array[Node] = get_children()
		for child : Node in children:
			if child is SphereCursorPicker:
				cursor_picker = child as SphereCursorPicker
				break
	if not cursor_picker:
		cursor_picker = SphereCursorPicker.new()
		add_child(cursor_picker)
	
	if world_config and cursor_picker:
		spellbook_manager = active_spellbook
		if spellbook_manager:
			spellbook_manager.load_spellbook()
		game_state_manager_initialised.emit()
	
	return Error.OK

## Keeps the static spellbook_manager reference in sync with the exported resource
## (mirrors the world_config static pattern).
func _sync_spellbook_manager() -> void:
	spellbook_manager = active_spellbook
	if active_spellbook and current_world_state:
		active_spellbook.load_spellbook()


func generate_world() -> Error:
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

## Static bridge: builds the region graph from the first snapshot (§3.4).
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

## After the bootstrap CCL: one summary entry opens the chronicle — a fresh
## world awakens, a loaded one resumes (§5.1).
static func _on_graph_rebuilt(region_count : int) -> void:
	if aeon_log == null:
		return
	if _loaded_world_bootstrap:
		aeon_log.log_region_named_after_load(region_count)
		_loaded_world_bootstrap = false
	else:
		aeon_log.log_world_awakens()

## Static bridge: feeds every diff batch into the region graph (§3.3) and the
## Phase 5 economy (§4.1 — shadow-based neighbor attribution).
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

## Creates the region graph child node once (idempotent), with its chronicle.
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

## Creates the biome snapshot manager child node once (idempotent).
func _ensure_biome_snapshot_manager() -> void:
	if biome_snapshot_manager and is_instance_valid(biome_snapshot_manager):
		return
	biome_snapshot_manager = BiomeSnapshotManager.new()
	add_child(biome_snapshot_manager)

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

@warning_ignore("unused_parameter")
func _process(delta: float) -> void:
	if not is_paused and world_config:
		var dt : float = sim_speed * simDeltaTime
		# 1 real second at 1.0 sim_speed = 1 in-game day
		day_progress += dt
		
		while day_progress >= 1.0:
			day_progress -= 1.0
			elapsed_days += 1
			
		year_progress = fmod(float(elapsed_days) + day_progress, world_config.days_per_year) / world_config.days_per_year
		elapsed_years = floori(elapsed_days / world_config.days_per_year)
	

static func stop_simulation() -> void:
	if GameStateManager.instance.world_simulator:
		GameStateManager.instance.remove_child(GameStateManager.instance.world_simulator)

static func increase_sim_speed() -> void:
	sim_speed = min(sim_speed + 1, world_config.max_sim_speed)

static func decrease_sim_speed() -> void:
	sim_speed = max(sim_speed - 1, 1)

static func pause_sim_speed() -> void:
	sim_speed = 0
	
func max_sim_speed() -> void:
	sim_speed = world_config.max_sim_speed

## Detects a zero-filled BIOME_TYPE layer and fills it with the
## BIOME_UNCLASSIFIED sentinel. the repair runs once, on the main
## thread, before the first sim frame.
func _repair_fill_biome_type_if_legacy() -> void:
	var ws : GpuWorldState = current_world_state
	var rd : RenderingDevice = ws.rd
	var biome_idx : int = atomic_layer_to_indices_map[Helpers.sim_layers.LANDSCAPE][3]
	var liquid_idx : int = atomic_layer_to_indices_map[Helpers.sim_layers.WATER][0]

	var biome_bytes : PackedByteArray = await _read_texture_layer_async(rd, ws.atomic_state_texture, biome_idx)
	if biome_bytes.is_empty():
		push_error("BiomeSnapshotManager: legacy-detection readback failed; skipping repair fill (worst case: §2.6 sentinel covers it).")
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

	var all_zero : bool = true
	@warning_ignore("integer_division")
	var cells_count : int = biome_bytes.size() / 4
	for i : int in cells_count:
		if biome_bytes.decode_u32(i * 4) != 0:
			all_zero = false
			break

	if all_zero and world_has_water:
		var fill : PackedByteArray = PackedByteArray()
		fill.resize(biome_bytes.size())
		fill.fill(0)
		var sentinel : int = Helpers.BIOME_UNCLASSIFIED
		for i : int in cells_count:
			fill.encode_u32(i * 4, sentinel)
		rd.texture_update(ws.atomic_state_texture, biome_idx, fill)
		print("[GameStateManager] Legacy save detected: BIOME_TYPE repair-filled with %d (unclassified); the classifier will self-heal." % sentinel)
		# The chronicle opens here when the AeonLog lands (§7.7).
	elif all_zero and not world_has_water:
		# All-glacier world with zero water everywhere: zero IS valid state.
		pass

## One-shot async single-layer readback helper (main-thread callback awaited
## via signal bridging). Returns an empty array on failure.
func _read_texture_layer_async(rd : RenderingDevice, tex : RID, layer : int) -> PackedByteArray:
	var result : PackedByteArray = PackedByteArray()
	# Lambdas capture locals by value, so a plain bool flag can never be
	# observed mutating; box the flag in a Dictionary (captured by reference).
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
