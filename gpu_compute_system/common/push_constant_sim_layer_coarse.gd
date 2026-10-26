@tool
extends Push_Constant
class_name PushConstant_SimLayer_Coarse

@export var target_coarse_layer : Helpers.coarse_layers:
	set(val):
		target_coarse_layer = val
		_update_metadata()
		notify_property_list_changed()

func _init() -> void:
	type = TYPE_INT
	_update_metadata()

func _update_metadata() -> void:
	type = TYPE_INT
	var layer_key : String = Helpers.coarse_layers.find_key(target_coarse_layer)
	var layer_name : String = layer_key if layer_key != null else str(target_coarse_layer)
	name = StringName("COARSE." + layer_name)

func get_value() -> Variant:
	type = TYPE_INT
	if not Engine.is_editor_hint():
		if GameStateManager.coarse_layer_to_indices_map.has(target_coarse_layer):
			return GameStateManager.coarse_layer_to_indices_map[target_coarse_layer]
	return int(target_coarse_layer)
