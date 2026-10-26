@tool
extends Push_Constant
class_name PushConstant_SimLayer

@export var target_domain : Helpers.sim_layers:
	set(val):
		target_domain = val
		_update_metadata()
		notify_property_list_changed()

@export var target_sub_layer_index : int:
	set(val):
		target_sub_layer_index = val
		_update_metadata()

func _init() -> void:
	type = TYPE_INT
	_update_metadata()

func _update_metadata() -> void:
	type = TYPE_INT
	var domain_key : String = Helpers.sim_layers.find_key(target_domain)
	var domain_name : String = domain_key if domain_key != null else str(target_domain)
	var sub_layer_names : PackedStringArray = Helpers.float_sub_layer_names.get(target_domain, PackedStringArray())
	var sub_name : String = ""
	if target_sub_layer_index >= 0 and target_sub_layer_index < sub_layer_names.size():
		sub_name = sub_layer_names[target_sub_layer_index]
	else:
		sub_name = str(target_sub_layer_index)
	name = StringName(domain_name + "." + sub_name)

func _validate_property(property: Dictionary) -> void:
	if property.name == "target_sub_layer_index":
		var sub_layer_names: PackedStringArray = Helpers.float_sub_layer_names.get(target_domain, PackedStringArray())
		var hint_string : String = ""
		for i : int in range(sub_layer_names.size()):
			if i > 0:
				hint_string += ","
			hint_string += sub_layer_names[i] + ":" + str(i)
		
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = hint_string

func get_value() -> Variant:
	type = TYPE_INT
	if not Engine.is_editor_hint():
		return GameStateManager.float_layer_to_indices_map[target_domain][target_sub_layer_index]
	return 0
