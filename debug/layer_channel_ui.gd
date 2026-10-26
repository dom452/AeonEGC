extends Node
class_name LayerChannelUI 

## Dropdown-driven RGB layer-channel visualizer for the planet sphere.
##
## Wire 3 OptionButton nodes (one per R/G/B channel) and the SphereVisualiser via
## the @export vars in the inspector. The script populates each dropdown with
## "Flat 1.0", "Flat 0.0", and every float + atomic simulation layer. On selection
## it sets the `u_channel_*` array uniforms on the planet's ShaderMaterial, and
## toggles `u_debug_layer_mode` when any channel departs from the Flat 1.0 default.
##
## The UI layout itself is authored by hand in the scene — this script only handles
## dropdown population and shader-parameter relay.

## The planet visualiser whose `mat_terrain` ShaderMaterial receives the uniforms.
@export var sphere_visualiser : SphereVisualiser

## R channel dropdown. Metadata per item: { src: int, z: int, is_atomic: bool }.
@export var menu_r : OptionButton

## G channel dropdown.
@export var menu_g : OptionButton

## B channel dropdown.
@export var menu_b : OptionButton

var mat_terrain : ShaderMaterial

# Per-channel state arrays (pushed to shader on change). Index 0=R, 1=G, 2=B.
var _src_arr    : PackedInt32Array = [0, 0, 0]      # all Flat 1.0
var _layer_arr  : PackedInt32Array = [0, 0, 0]
var _scale_arr  : PackedFloat32Array = [1.0, 1.0, 1.0]
var _offset_arr : PackedFloat32Array = [0.0, 0.0, 0.0]

var _menus : Array[OptionButton] = []
var _initialised : bool = false


func _ready() -> void:
	_menus = [menu_r, menu_g, menu_b]
	# Populate dropdowns as soon as GameStateManager layer maps are available.
	# The SphereVisualiser may not have created mat_terrain yet (it awaits
	# game_state_manager.ready), so we poll for that in _process().
	if GameStateManager.current_world_state:
		_populate_all_menus()
	else:
		GameStateManager.instance.game_state_manager_initialised.connect(_on_gsm_ready)
	set_process(true)


func _on_gsm_ready() -> void:
	_populate_all_menus()


func _process(_delta: float) -> void:
	if _initialised:
		return
	if not is_instance_valid(sphere_visualiser) or not sphere_visualiser.mat_terrain:
		return
	mat_terrain = sphere_visualiser.mat_terrain
	_push_to_shader()
	_initialised = true
	set_process(false)


# ============================================================
#  Dropdown population
# ============================================================

## Populates all 3 OptionButtons with identical content: Flat 1.0, Flat 0.0,
## then every float layer, then every atomic layer. Connects item_selected.
func _populate_all_menus() -> void:
	for channel_idx : int in range(_menus.size()):
		var btn : OptionButton = _menus[channel_idx]
		if not btn:
			continue
		_populate_menu(btn)
		btn.select(0)  # Flat 1.0 by default
		# Use a lambda capturing channel_idx so each menu routes to the right slot.
		btn.item_selected.connect(_on_channel_selected.bind(channel_idx))


## Fills a single OptionButton. Item metadata format: { src, z, is_atomic }.
##   src 0 = Flat 1.0, 1 = Flat 0.0, 2 = float array, 3 = atomic array.
static func _populate_menu(btn : OptionButton) -> void:
	btn.clear()
	var idx : int = 0

	# --- Flat options ---
	btn.add_item("Flat 1.0")
	btn.set_item_metadata(idx, { "src": 0 })
	idx += 1

	btn.add_item("Flat 0.0")
	btn.set_item_metadata(idx, { "src": 1 })
	idx += 1

	# --- Float layers ---
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

	# --- Atomic layers ---
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


# ============================================================
#  Selection handling
# ============================================================

func _on_channel_selected(_index : int, channel_idx : int) -> void:
	if channel_idx < 0 or channel_idx >= _menus.size():
		return
	var btn : OptionButton = _menus[channel_idx]
	if not btn:
		return

	var meta : Dictionary = btn.get_item_metadata(btn.selected)
	var src : int = meta.get("src", 0)
	var z : int = meta.get("z", 0)

	_src_arr[channel_idx] = src
	_layer_arr[channel_idx] = z

	if src == 2:  # float — apply VisHelpers normalization
		_scale_arr[channel_idx] = VisHelpers.get_scale_for_layer(z, false)
		_offset_arr[channel_idx] = VisHelpers.get_offset_for_layer(z, false)
	else:         # flat or atomic — no normalization
		_scale_arr[channel_idx] = 1.0
		_offset_arr[channel_idx] = 0.0

	# Auto-toggle debug mode: on when any channel is not Flat 1.0 (src != 0),
	# off when all channels are back to Flat 1.0.
	var any_active : bool = false
	for i : int in range(_src_arr.size()):
		if _src_arr[i] != 0:
			any_active = true
			break

	if mat_terrain:
		mat_terrain.set_shader_parameter("u_debug_layer_mode", any_active)
		_push_to_shader()


# ============================================================
#  Shader relay
# ============================================================

func _push_to_shader() -> void:
	if not mat_terrain:
		return
	mat_terrain.set_shader_parameter("u_channel_src", _src_arr)
	mat_terrain.set_shader_parameter("u_channel_layer", _layer_arr)
	mat_terrain.set_shader_parameter("u_channel_scale", _scale_arr)
	mat_terrain.set_shader_parameter("u_channel_offset", _offset_arr)
