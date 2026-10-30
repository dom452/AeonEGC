extends Node
## Debug-scene only (reusable as a template for production data-lens / map-mode UI):
## populates R/G/B `OptionButton` dropdowns with all float and atomic simulation layers and
## relays normalization uniforms (`u_channel_*`, `u_debug_layer_mode`) to `SphereVisualiser.mat_terrain`.
class_name LayerChannelUI 

## Target `SphereVisualiser` whose `mat_terrain` `ShaderMaterial` receives the channel uniforms.
@export var sphere_visualiser : SphereVisualiser

## Dropdown selecting the simulation layer mapped to the Red visualization channel.
@export var menu_r : OptionButton

## Dropdown selecting the simulation layer mapped to the Green visualization channel.
@export var menu_g : OptionButton

## Dropdown selecting the simulation layer mapped to the Blue visualization channel.
@export var menu_b : OptionButton

## Cached reference to `sphere_visualiser.mat_terrain` once initialized.
var mat_terrain : ShaderMaterial

## Per-channel source type (`0 = Flat 1.0`, `1 = Flat 0.0`, `2 = Float grid`, `3 = Atomic grid`) for `[R, G, B]`.
var _src_arr    : PackedInt32Array = [0, 0, 0]
## Per-channel texture-array slice index `z` for `[R, G, B]`.
var _layer_arr  : PackedInt32Array = [0, 0, 0]
## Per-channel `VisHelpers` normalization scale factor for `[R, G, B]`.
var _scale_arr  : PackedFloat32Array = [1.0, 1.0, 1.0]
## Per-channel `VisHelpers` normalization offset for `[R, G, B]`.
var _offset_arr : PackedFloat32Array = [0.0, 0.0, 0.0]

## Ordered `[menu_r, menu_g, menu_b]` array indexed by channel (`0..2`).
var _menus : Array[OptionButton] = []
## True once `mat_terrain` has been acquired and initial channel uniforms have been pushed.
var _initialised : bool = false


## Populates the R/G/B dropdown menus once `GameStateManager` layer maps are ready and enables polling for `mat_terrain`.
func _ready() -> void:
	_menus = [menu_r, menu_g, menu_b]
	# Populate dropdowns immediately if world state exists, or wait for `game_state_manager_initialised`.
	if GameStateManager.current_world_state:
		_populate_all_menus()
	else:
		GameStateManager.instance.game_state_manager_initialised.connect(_on_gsm_ready)
	set_process(true)


## Populates all channel dropdowns once `GameStateManager` finishes initialization.
func _on_gsm_ready() -> void:
	_populate_all_menus()


## Polls until `sphere_visualiser.mat_terrain` is available, pushes initial channel uniforms, and disables `_process`.
func _process(_delta: float) -> void:
	if _initialised:
		return
	if not is_instance_valid(sphere_visualiser) or not sphere_visualiser.mat_terrain:
		return
	mat_terrain = sphere_visualiser.mat_terrain
	_push_to_shader()
	_initialised = true
	set_process(false)


## Populates each R/G/B `OptionButton` with flat constants, float layers, and atomic layers, and connects `item_selected`.
func _populate_all_menus() -> void:
	for channel_idx : int in range(_menus.size()):
		var btn : OptionButton = _menus[channel_idx]
		if not btn:
			continue
		_populate_menu(btn)
		btn.select(0)
		btn.item_selected.connect(_on_channel_selected.bind(channel_idx))


## Fills `btn` with `"Flat 1.0"`, `"Flat 0.0"`, all float sub-layers, and all atomic sub-layers with `{src, z, is_atomic}` metadata.
static func _populate_menu(btn : OptionButton) -> void:
	btn.clear()
	var idx : int = 0

	# Add constant 1.0 and 0.0 channel options.
	btn.add_item("Flat 1.0")
	btn.set_item_metadata(idx, { "src": 0 })
	idx += 1

	btn.add_item("Flat 0.0")
	btn.set_item_metadata(idx, { "src": 1 })
	idx += 1

	# Append every fine float grid sub-layer in domain order.
	for sim_layer : Helpers.sim_layers in Helpers.sim_layers.values():
		if sim_layer == Helpers.sim_layers.INVALID:
			continue
		if not GameStateManager.float_layer_to_indices_map.has(sim_layer):
			continue
		var float_indices : PackedInt32Array = GameStateManager.float_layer_to_indices_map[sim_layer]
		var float_names : PackedStringArray = Helpers.float_sub_layer_names.get(sim_layer, PackedStringArray())
		for j : int in range(float_indices.size()):
			var sub_name : String = float_names[j] if j < float_names.size() else str(j)
			btn.add_item("[FLOAT] %s_%s" % [Helpers.sim_layers.find_key(sim_layer), sub_name])
			btn.set_item_metadata(idx, { "src": 2, "z": float_indices[j], "is_atomic": false })
			idx += 1

	# Append every atomic grid sub-layer in domain order.
	for sim_layer : Helpers.sim_layers in Helpers.sim_layers.values():
		if sim_layer == Helpers.sim_layers.INVALID:
			continue
		if not GameStateManager.atomic_layer_to_indices_map.has(sim_layer):
			continue
		var atomic_indices : PackedInt32Array = GameStateManager.atomic_layer_to_indices_map[sim_layer]
		var atomic_names : PackedStringArray = Helpers.atomic_sub_layer_names.get(sim_layer, PackedStringArray())
		for j : int in range(atomic_indices.size()):
			var sub_name : String = atomic_names[j] if j < atomic_names.size() else str(j)
			btn.add_item("[ATOMIC] %s_%s" % [Helpers.sim_layers.find_key(sim_layer), sub_name])
			btn.set_item_metadata(idx, { "src": 3, "z": atomic_indices[j], "is_atomic": true })
			idx += 1


## Updates the source, slice index, and `VisHelpers` scale/offset for `channel_idx` and refreshes `mat_terrain` uniforms.
func _on_channel_selected(_index : int, channel_idx : int) -> void:
	if channel_idx < 0 or channel_idx >= _menus.size():
		return
	var btn : OptionButton = _menus[channel_idx]
	if not btn:
		return

	# Read the selected item's `{src, z}` metadata and compute normalization scale/offset for float layers.
	var meta : Dictionary = btn.get_item_metadata(btn.selected)
	var src : int = meta.get("src", 0)
	var z : int = meta.get("z", 0)

	_src_arr[channel_idx] = src
	_layer_arr[channel_idx] = z

	if src == 2:
		_scale_arr[channel_idx] = VisHelpers.get_scale_for_layer(z, false)
		_offset_arr[channel_idx] = VisHelpers.get_offset_for_layer(z, false)
	else:
		_scale_arr[channel_idx] = 1.0
		_offset_arr[channel_idx] = 0.0

	# Enable `u_debug_layer_mode` whenever any R/G/B channel is set to a non-default source (`src != 0`).
	var any_active : bool = false
	for i : int in range(_src_arr.size()):
		if _src_arr[i] != 0:
			any_active = true
			break

	if mat_terrain:
		mat_terrain.set_shader_parameter("u_debug_layer_mode", any_active)
		_push_to_shader()


## Writes `_src_arr`, `_layer_arr`, `_scale_arr`, and `_offset_arr` to `mat_terrain`'s `u_channel_*` uniforms.
func _push_to_shader() -> void:
	if not mat_terrain:
		return
	mat_terrain.set_shader_parameter("u_channel_src", _src_arr)
	mat_terrain.set_shader_parameter("u_channel_layer", _layer_arr)
	mat_terrain.set_shader_parameter("u_channel_scale", _scale_arr)
	mat_terrain.set_shader_parameter("u_channel_offset", _offset_arr)
