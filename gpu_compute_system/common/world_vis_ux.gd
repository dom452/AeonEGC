extends Container
## Debug-scene only (reusable as a template for production multi-layer telemetry inspectors):
## builds an interactive tabbed matrix of 2D slice previews across fine float, atomic, and coarse simulation layers.
class_name WorldVisualiserUX

## Active GameStateManager instance providing world state and configuration.
@export var game_state_manager : GameStateManager
## Material configured with a shader that visualizes fine float texture arrays.
@export var float_material : ShaderMaterial
## Material configured with a shader that visualizes atomic integer texture arrays.
@export var atomic_material : ShaderMaterial
## Fallback material template for debug visualization.
@export var debug_material_template : ShaderMaterial
## Parent TabContainer node organizing layer previews into system-specific tabs.
@export var tab_container : TabContainer
## Legacy container node retained for scene compatibility.
@export var float_layers_container : GridContainer
## Legacy container node retained for scene compatibility.
@export var atomic_layers_container : GridContainer
## Default initial layer slice indices displayed on startup.
@export var default_layer_indices : Array[int] = [0, 1, 2, 3]

## Ping-pong texture array wrappers for reading fine float layers.
var runtime_texture_arrays_float : Array[Texture2DArrayRD] = []
## Ping-pong texture array wrappers for reading coarse dynamics layers.
var runtime_texture_arrays_coarse : Array[Texture2DArrayRD] = []
## Texture array wrapper for reading atomic visualizer data.
var runtime_texture_array_atomic : Texture2DArrayRD
## List of instantiated visualizer preview items holding references to preview rects and selector buttons.
var visualiser_items : Array[Dictionary] = []


## Waits for GameStateManager to become ready and constructs the debug tabbed UI.
func _ready() -> void:
	if not game_state_manager.is_node_ready():
		await game_state_manager.ready
	await setup_debug_ui()


## Updates all preview tile ShaderMaterials with the latest active read texture arrays.
func _force_material_redraw() -> void:
	if not GameStateManager.current_world_state:
		return
	var current_read_idx : int = GameStateManager.current_world_state.read_world_state_index
	if current_read_idx < 0 or current_read_idx >= runtime_texture_arrays_float.size():
		return
		
	# Select current readable ping-pong textures for float, atomic, and coarse data.
	var float_tex : Texture2DArrayRD = runtime_texture_arrays_float[current_read_idx]
	var atomic_tex : Texture2DArrayRD = runtime_texture_array_atomic
	var coarse_tex : Texture2DArrayRD = runtime_texture_arrays_coarse[current_read_idx] if current_read_idx < runtime_texture_arrays_coarse.size() else null
	
	# Push the active textures to each preview tile's ShaderMaterial.
	for entry : Dictionary in visualiser_items:
		var rect : ColorRect = entry.get("rect")
		if not rect or not rect.material:
			continue
		var mat : ShaderMaterial = rect.material as ShaderMaterial
		var is_atomic : bool = entry.get("is_atomic", false)
		var is_coarse : bool = entry.get("is_coarse", false)
		if is_atomic:
			mat.set_shader_parameter("world_texture", atomic_tex)
		elif is_coarse and coarse_tex != null:
			mat.set_shader_parameter("world_texture", coarse_tex)
		else:
			mat.set_shader_parameter("world_texture", float_tex)


## Signal listener called when the GPU world state completes a frame and swaps buffers.
@warning_ignore("unused_parameter")
func on_state_updated(read_index : int) -> void:
	_force_material_redraw()


## Creates system tabs, populates layer dropdowns, and initializes texture array wrappers.
func setup_debug_ui() -> void:
	if not GameStateManager.current_world_state:
		return
		
	GameStateManager.current_world_state.state_updated.connect(on_state_updated)
	
	# Wrap GPU float texture RIDs in Texture2DArrayRD objects.
	runtime_texture_arrays_float.resize(2)
	runtime_texture_arrays_float[0] = Texture2DArrayRD.new()
	runtime_texture_arrays_float[0].texture_rd_rid = GameStateManager.current_world_state.float_state_textures[0]
	runtime_texture_arrays_float[1] = Texture2DArrayRD.new()
	runtime_texture_arrays_float[1].texture_rd_rid = GameStateManager.current_world_state.float_state_textures[1]

	# Wrap GPU coarse texture RIDs in Texture2DArrayRD objects.
	runtime_texture_arrays_coarse.resize(2)
	runtime_texture_arrays_coarse[0] = Texture2DArrayRD.new()
	runtime_texture_arrays_coarse[0].texture_rd_rid = GameStateManager.current_world_state.coarse_state_textures[0]
	runtime_texture_arrays_coarse[1] = Texture2DArrayRD.new()
	runtime_texture_arrays_coarse[1].texture_rd_rid = GameStateManager.current_world_state.coarse_state_textures[1]
	
	# Wrap GPU atomic visualization texture RID.
	runtime_texture_array_atomic = Texture2DArrayRD.new()
	runtime_texture_array_atomic.texture_rd_rid = GameStateManager.current_world_state.atomic_visual_texture
	
	var active_float_mat : ShaderMaterial = float_material
	var active_atomic_mat : ShaderMaterial = atomic_material

	# Locate or construct the parent TabContainer node.
	if not tab_container:
		tab_container = find_child("TabContainer", true, false) as TabContainer
	if not tab_container:
		tab_container = TabContainer.new()
		tab_container.name = "TabContainer"
		tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		add_child(tab_container)
	else:
		# Clean up any leftover generated tabs from prior sessions.
		for child : Node in tab_container.get_children():
			if child.name == "FloatLayers" or child.name == "AtomicLayers" or child.has_meta("is_auto_tab"):
				tab_container.remove_child(child)
				child.queue_free()

	visualiser_items.clear()

	# Create a dedicated visualizer tab for each high-level simulation system.
	for sys_value : int in Helpers.system_names.values():
		var sys_enum : Helpers.system_names = sys_value as Helpers.system_names
		var sys_key : String = Helpers.system_names.keys()[sys_value]
		var sys_title : String = sys_key.replace("_", " ").capitalize()
		var layers : Array[Dictionary] = _get_layers_for_system(sys_enum)
		_create_tab(sys_title, layers, active_float_mat, active_atomic_mat)

	# Create a tab for Coarse Dynamics atmospheric layers.
	var coarse_layers : Array[Dictionary] = []
	for cl : Helpers.coarse_layers in Helpers.coarse_sub_layer_names.keys():
		if cl == Helpers.coarse_layers.COUNT:
			continue
		if not GameStateManager.coarse_layer_to_indices_map.has(cl):
			continue
		var coarse_idx : int = GameStateManager.coarse_layer_to_indices_map[cl]
		coarse_layers.append({
			"is_atomic": false,
			"is_coarse": true,
			"z": coarse_idx
		})
	if not coarse_layers.is_empty():
		_create_tab("Coarse Dynamics", coarse_layers, active_float_mat, active_atomic_mat)

	# Wait two frames for layout nodes to settle, then force initial material redraw.
	await get_tree().process_frame
	await get_tree().process_frame
	_force_material_redraw()


## Constructs a scrollable grid tab populated with preview boxes for each layer in `layers`.
func _create_tab(title : String, layers : Array[Dictionary], active_float_mat : ShaderMaterial, active_atomic_mat : ShaderMaterial) -> void:
	var scroll : ScrollContainer = ScrollContainer.new()
	scroll.name = title
	scroll.set_meta("is_auto_tab", true)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var margin : MarginContainer = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	scroll.add_child(margin)

	var grid : GridContainer = GridContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	margin.add_child(grid)

	tab_container.add_child(scroll)

	# Set grid columns to arrange in 2 rows (at least 3 columns per row)
	grid.columns = max(3, ceil(layers.size() / 2.0))

	# Build visualizer preview boxes.
	for layer_info : Dictionary in layers:
		var vbox : VBoxContainer = VBoxContainer.new()
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
		vbox.custom_minimum_size = Vector2(180, 0)

		var option_btn : OptionButton = OptionButton.new()
		option_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(option_btn)

		var aspect : AspectRatioContainer = AspectRatioContainer.new()
		aspect.ratio = 1.0
		aspect.alignment_horizontal = AspectRatioContainer.ALIGNMENT_CENTER
		aspect.alignment_vertical = AspectRatioContainer.ALIGNMENT_CENTER
		aspect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		aspect.size_flags_vertical = Control.SIZE_EXPAND_FILL
		aspect.custom_minimum_size = Vector2(160, 160)
		vbox.add_child(aspect)

		var rect : ColorRect = ColorRect.new()
		rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
		aspect.add_child(rect)

		grid.add_child(vbox)

		# Populate option_btn with all available float, atomic, and coarse layers.
		_populate_option_button(option_btn)

		# Select the initial configured layer.
		var init_is_atomic : bool = layer_info.get("is_atomic", false)
		var init_is_coarse : bool = layer_info.get("is_coarse", false)
		var init_z : int = layer_info.get("z", 0)

		_select_option_item(option_btn, init_is_atomic, init_is_coarse, init_z)

		var vis_entry : Dictionary = {
			"rect": rect,
			"option_btn": option_btn,
			"is_atomic": init_is_atomic,
			"is_coarse": init_is_coarse,
			"layer_index": init_z
		}
		visualiser_items.append(vis_entry)

		_apply_visualiser_material(vis_entry, active_float_mat, active_atomic_mat)

		var item_ref_idx : int = visualiser_items.size() - 1
		option_btn.item_selected.connect(_on_item_selected.bind(item_ref_idx, active_float_mat, active_atomic_mat))


## Discovers all layers referenced by compute passes belonging to `sys_enum`.
func _get_layers_for_system(sys_enum : Helpers.system_names) -> Array[Dictionary]:
	var result : Array[Dictionary] = []
	var added_keys : Dictionary = {}
	
	if not GameStateManager.world_config:
		return result
		
	# Search active runtime simulation layers.
	for sim_layer : LayerSimulator in GameStateManager.world_config.sim_layers:
		if sim_layer and sim_layer.system_name == sys_enum:
			_collect_layers_from_push_constants(sim_layer.push_constants_resources, result, added_keys)
			
	# Search active world generation layers.
	for gen_layer : LayerGenerator in GameStateManager.world_config.layer_generators:
		if gen_layer and gen_layer.system_name == sys_enum:
			_collect_layers_from_push_constants(gen_layer.push_constants_resources, result, added_keys)
			
	if result.is_empty():
		_add_default_fallback_layers(result)
		
	return result


## Extracts float and atomic layer slice indices from push constant resources attached to a compute pass.
func _collect_layers_from_push_constants(pc_array : Array[Push_Constant], out_result : Array[Dictionary], added_keys : Dictionary) -> void:
	for pc : Push_Constant in pc_array:
		if not pc:
			continue
		if pc is PushConstant_SimLayer:
			var domain : Helpers.sim_layers = (pc as PushConstant_SimLayer).target_domain
			var sub_idx : int = (pc as PushConstant_SimLayer).target_sub_layer_index
			if GameStateManager.float_layer_to_indices_map.has(domain):
				var indices : PackedInt32Array = GameStateManager.float_layer_to_indices_map[domain]
				if sub_idx >= 0 and sub_idx < indices.size():
					var abs_z : int = indices[sub_idx]
					var key : String = "float_%d" % abs_z
					if not added_keys.has(key):
						added_keys[key] = true
						out_result.append({
							"is_atomic": false,
							"is_coarse": false,
							"z": abs_z
						})
		elif pc is PushConstant_SimLayer_Atomic:
			var domain : Helpers.sim_layers = (pc as PushConstant_SimLayer_Atomic).target_domain
			var sub_idx : int = (pc as PushConstant_SimLayer_Atomic).target_sub_layer_index
			if GameStateManager.atomic_layer_to_indices_map.has(domain):
				var indices : PackedInt32Array = GameStateManager.atomic_layer_to_indices_map[domain]
				if sub_idx >= 0 and sub_idx < indices.size():
					var abs_z : int = indices[sub_idx]
					var key : String = "atomic_%d" % abs_z
					if not added_keys.has(key):
						added_keys[key] = true
						out_result.append({
							"is_atomic": true,
							"is_coarse": false,
							"z": abs_z
						})


## Populates fallback preview slots if a system has no push constants configured.
func _add_default_fallback_layers(out_result : Array[Dictionary]) -> void:
	# Add up to 4 sequential float layers as defaults.
	for i : int in range(4):
		var abs_z : int = i % maxi(GameStateManager.total_float_layers, 1)
		out_result.append({
			"is_atomic": false,
			"is_coarse": false,
			"z": abs_z
		})


## Fills an OptionButton dropdown with all available float, atomic, and coarse layers.
func _populate_option_button(option_btn : OptionButton) -> void:
	option_btn.clear()
	var item_idx : int = 0

	# Float sub-layers.
	for sim_layer : Helpers.sim_layers in Helpers.sim_layers.values():
		if sim_layer == Helpers.sim_layers.INVALID or not GameStateManager.float_layer_to_indices_map.has(sim_layer):
			continue
		var float_indices : PackedInt32Array = GameStateManager.float_layer_to_indices_map[sim_layer]
		var float_names : PackedStringArray = Helpers.float_sub_layer_names.get(sim_layer, PackedStringArray())
		for j : int in range(float_indices.size()):
			var sub_name : String = float_names[j] if j < float_names.size() else str(j)
			var display_name : String = "[FLOAT] " + Helpers.sim_layers.find_key(sim_layer) + "_" + sub_name
			option_btn.add_item(display_name)
			option_btn.set_item_metadata(item_idx, {
				"is_atomic": false,
				"is_coarse": false,
				"z": float_indices[j]
			})
			item_idx += 1

	# Atomic sub-layers.
	for sim_layer : Helpers.sim_layers in Helpers.sim_layers.values():
		if sim_layer == Helpers.sim_layers.INVALID or not GameStateManager.atomic_layer_to_indices_map.has(sim_layer):
			continue
		var atomic_indices : PackedInt32Array = GameStateManager.atomic_layer_to_indices_map[sim_layer]
		var atomic_names : PackedStringArray = Helpers.atomic_sub_layer_names.get(sim_layer, PackedStringArray())
		for j : int in range(atomic_indices.size()):
			var sub_name : String = atomic_names[j] if j < atomic_names.size() else str(j)
			var display_name : String = "[ATOMIC] " + Helpers.sim_layers.find_key(sim_layer) + "_" + sub_name
			option_btn.add_item(display_name)
			option_btn.set_item_metadata(item_idx, {
				"is_atomic": true,
				"is_coarse": false,
				"z": atomic_indices[j]
			})
			item_idx += 1

	# Coarse sub-layers.
	for cl : Helpers.coarse_layers in Helpers.coarse_sub_layer_names.keys():
		if not GameStateManager.coarse_layer_to_indices_map.has(cl):
			continue
		var coarse_idx : int = GameStateManager.coarse_layer_to_indices_map[cl]
		var sub_name : String = Helpers.coarse_sub_layer_names[cl]
		var display_name : String = "[COARSE] " + sub_name
		option_btn.add_item(display_name)
		option_btn.set_item_metadata(item_idx, {
			"is_atomic": false,
			"is_coarse": true,
			"z": coarse_idx
		})
		item_idx += 1


## Selects the dropdown item matching the specified atomic/coarse flags and slice index.
func _select_option_item(option_btn : OptionButton, is_atomic : bool, is_coarse : bool, z_ind : int) -> void:
	for i : int in range(option_btn.item_count):
		var meta : Dictionary = option_btn.get_item_metadata(i)
		if meta.get("is_atomic", false) == is_atomic and meta.get("is_coarse", false) == is_coarse and meta.get("z") == z_ind:
			option_btn.select(i)
			return
	if option_btn.item_count > 0:
		option_btn.select(0)


## Applies a configured ShaderMaterial instance to a preview rect, configuring its layer index and normalization bounds.
func _apply_visualiser_material(entry : Dictionary, active_float_mat : ShaderMaterial, active_atomic_mat : ShaderMaterial) -> void:
	var rect : ColorRect = entry.get("rect")
	if not rect:
		return
		
	var is_atomic : bool = entry.get("is_atomic", false)
	var is_coarse : bool = entry.get("is_coarse", false)
	var target_idx : int = entry.get("layer_index", 0)
	
	var mat_template : ShaderMaterial = active_atomic_mat if is_atomic else active_float_mat
	var mat_instance : ShaderMaterial = mat_template.duplicate() as ShaderMaterial
	rect.material = mat_instance
	
	mat_instance.set_shader_parameter("layer_to_view", target_idx)
	
	var current_read_idx : int = GameStateManager.current_world_state.read_world_state_index
	if is_atomic:
		mat_instance.set_shader_parameter("world_texture", runtime_texture_array_atomic)
		mat_instance.set_shader_parameter("scale", 1.0)
		mat_instance.set_shader_parameter("offset", 0.0)
		var bounds : Vector2 = VisHelpers.get_layer_min_max(target_idx, true)
		rect.tooltip_text = "Atomic Layer: %d\nBounds:\nMin: %.2f\nMax: %.2f" % [target_idx, bounds.x, bounds.y]
	elif is_coarse:
		if current_read_idx >= 0 and current_read_idx < runtime_texture_arrays_coarse.size():
			mat_instance.set_shader_parameter("world_texture", runtime_texture_arrays_coarse[current_read_idx])
		var scale_val : float = VisHelpers.get_coarse_scale_for_layer(target_idx)
		var offset_val : float = VisHelpers.get_coarse_offset_for_layer(target_idx)
		mat_instance.set_shader_parameter("scale", scale_val)
		mat_instance.set_shader_parameter("offset", offset_val)
		var bounds : Vector2 = VisHelpers.get_coarse_layer_min_max(target_idx)
		var layer_name : String = Helpers.coarse_sub_layer_names.get(target_idx as Helpers.coarse_layers, str(target_idx))
		rect.tooltip_text = "Coarse Layer: %s (%d)\nBounds:\nMin: %.2f\nMax: %.2f" % [layer_name, target_idx, bounds.x, bounds.y]
	else:
		if current_read_idx >= 0 and current_read_idx < runtime_texture_arrays_float.size():
			mat_instance.set_shader_parameter("world_texture", runtime_texture_arrays_float[current_read_idx])
		var scale_val : float = VisHelpers.get_scale_for_layer(target_idx, false)
		var offset_val : float = VisHelpers.get_offset_for_layer(target_idx, false)
		mat_instance.set_shader_parameter("scale", scale_val)
		mat_instance.set_shader_parameter("offset", offset_val)
		var bounds : Vector2 = VisHelpers.get_layer_min_max(target_idx, false)
		rect.tooltip_text = "Layer Bounds:\nMin: %.2f\nMax: %.2f" % [bounds.x, bounds.y]


## Handles dropdown selection changes on a preview box and re-applies the ShaderMaterial parameters.
func _on_item_selected(index : int, item_ref_idx : int, active_float_mat : ShaderMaterial, active_atomic_mat : ShaderMaterial) -> void:
	if item_ref_idx < 0 or item_ref_idx >= visualiser_items.size():
		return
	var entry : Dictionary = visualiser_items[item_ref_idx]
	var option_btn : OptionButton = entry.get("option_btn")
	if not option_btn:
		return
	var meta : Dictionary = option_btn.get_item_metadata(index)
	entry["is_atomic"] = meta.get("is_atomic", false)
	entry["is_coarse"] = meta.get("is_coarse", false)
	entry["layer_index"] = meta.get("z", 0)
	_apply_visualiser_material(entry, active_float_mat, active_atomic_mat)

		var atomic_names : PackedStringArray = Helpers.atomic_sub_layer_names.get(sim_layer, PackedStringArray())
		for j : int in range(atomic_indices.size()):
			var sub_name : String = atomic_names[j] if j < atomic_names.size() else str(j)
			var display_name : String = "[ATOMIC] " + Helpers.sim_layers.find_key(sim_layer) + "_" + sub_name
			option_btn.add_item(display_name)
			option_btn.set_item_metadata(item_idx, {
				"is_atomic": true,
				"is_coarse": false,
				"z": atomic_indices[j]
			})
			item_idx += 1

	# Coarse Sub-Layers
	for cl : Helpers.coarse_layers in Helpers.coarse_sub_layer_names.keys():
		if not GameStateManager.coarse_layer_to_indices_map.has(cl):
			continue
		var coarse_idx : int = GameStateManager.coarse_layer_to_indices_map[cl]
		var sub_name : String = Helpers.coarse_sub_layer_names[cl]
		var display_name : String = "[COARSE] " + sub_name
		option_btn.add_item(display_name)
		option_btn.set_item_metadata(item_idx, {
			"is_atomic": false,
			"is_coarse": true,
			"z": coarse_idx
		})
		item_idx += 1

func _select_option_item(option_btn : OptionButton, is_atomic : bool, is_coarse : bool, z_ind : int) -> void:
	for i : int in range(option_btn.item_count):
		var meta : Dictionary = option_btn.get_item_metadata(i)
		if meta.get("is_atomic", false) == is_atomic and meta.get("is_coarse", false) == is_coarse and meta.get("z") == z_ind:
			option_btn.select(i)
			return
	if option_btn.item_count > 0:
		option_btn.select(0)

func _apply_visualiser_material(entry : Dictionary, active_float_mat : ShaderMaterial, active_atomic_mat : ShaderMaterial) -> void:
	var rect : ColorRect = entry.get("rect")
	if not rect:
		return
		
	var is_atomic : bool = entry.get("is_atomic", false)
	var is_coarse : bool = entry.get("is_coarse", false)
	var target_idx : int = entry.get("layer_index", 0)
	
	var mat_template : ShaderMaterial = active_atomic_mat if is_atomic else active_float_mat
	var mat_instance : ShaderMaterial = mat_template.duplicate() as ShaderMaterial
	rect.material = mat_instance
	
	mat_instance.set_shader_parameter("layer_to_view", target_idx)
	
	var current_read_idx : int = GameStateManager.current_world_state.read_world_state_index
	if is_atomic:
		mat_instance.set_shader_parameter("world_texture", runtime_texture_array_atomic)
		mat_instance.set_shader_parameter("scale", 1.0)
		mat_instance.set_shader_parameter("offset", 0.0)
		var bounds : Vector2 = VisHelpers.get_layer_min_max(target_idx, true)
		rect.tooltip_text = "Atomic Layer: %d\nBounds:\nMin: %.2f\nMax: %.2f" % [target_idx, bounds.x, bounds.y]
	elif is_coarse:
		if current_read_idx >= 0 and current_read_idx < runtime_texture_arrays_coarse.size():
			mat_instance.set_shader_parameter("world_texture", runtime_texture_arrays_coarse[current_read_idx])
		var scale_val : float = VisHelpers.get_coarse_scale_for_layer(target_idx)
		var offset_val : float = VisHelpers.get_coarse_offset_for_layer(target_idx)
		mat_instance.set_shader_parameter("scale", scale_val)
		mat_instance.set_shader_parameter("offset", offset_val)
		var bounds : Vector2 = VisHelpers.get_coarse_layer_min_max(target_idx)
		var layer_name : String = Helpers.coarse_sub_layer_names.get(target_idx as Helpers.coarse_layers, str(target_idx))
		rect.tooltip_text = "Coarse Layer: %s (%d)\nBounds:\nMin: %.2f\nMax: %.2f" % [layer_name, target_idx, bounds.x, bounds.y]
	else:
		if current_read_idx >= 0 and current_read_idx < runtime_texture_arrays_float.size():
			mat_instance.set_shader_parameter("world_texture", runtime_texture_arrays_float[current_read_idx])
		var scale_val : float = VisHelpers.get_scale_for_layer(target_idx, false)
		var offset_val : float = VisHelpers.get_offset_for_layer(target_idx, false)
		mat_instance.set_shader_parameter("scale", scale_val)
		mat_instance.set_shader_parameter("offset", offset_val)
		var bounds : Vector2 = VisHelpers.get_layer_min_max(target_idx, false)
		rect.tooltip_text = "Layer Bounds:\nMin: %.2f\nMax: %.2f" % [bounds.x, bounds.y]

func _on_item_selected(index : int, item_ref_idx : int, active_float_mat : ShaderMaterial, active_atomic_mat : ShaderMaterial) -> void:
	if item_ref_idx < 0 or item_ref_idx >= visualiser_items.size():
		return
	var entry : Dictionary = visualiser_items[item_ref_idx]
	var option_btn : OptionButton = entry.get("option_btn")
	if not option_btn:
		return
	var meta : Dictionary = option_btn.get_item_metadata(index)
	entry["is_atomic"] = meta.get("is_atomic", false)
	entry["is_coarse"] = meta.get("is_coarse", false)
	entry["layer_index"] = meta.get("z", 0)
	_apply_visualiser_material(entry, active_float_mat, active_atomic_mat)
