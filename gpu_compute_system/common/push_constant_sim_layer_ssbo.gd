@tool
extends Push_Constant
class_name PushConstant_SimLayer_SSBO

@export var target_domain : Helpers.sim_layers:
	set(val):
		target_domain = val
		_update_metadata()

func _init() -> void:
	type = TYPE_INT
	_update_metadata()

func _update_metadata() -> void:
	type = TYPE_INT
	var domain_key = Helpers.sim_layers.find_key(target_domain)
	var domain_name : String = domain_key if domain_key != null else str(target_domain)
	name = StringName(domain_name + ".SSBO_OFFSET")

func get_value() -> Variant:
	type = TYPE_INT
	if not Engine.is_editor_hint():
		if GameStateManager.ssbo_layer_to_indices_map.has(target_domain):
			return GameStateManager.ssbo_layer_to_indices_map[target_domain][0]
	return 0
