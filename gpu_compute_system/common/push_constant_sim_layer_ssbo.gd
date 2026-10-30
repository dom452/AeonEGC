@tool
extends Push_Constant
## Push constant providing the starting element offset for a domain's population clusters in the shared SSBO buffer.
class_name PushConstant_SimLayer_SSBO

## The simulation domain (e.g. FAUNA, CIVILISATION) whose cluster offset is being supplied.
@export var target_domain : Helpers.sim_layers:
	set(val):
		target_domain = val
		_update_metadata()


## Sets integer type and updates the metadata name.
func _init() -> void:
	type = TYPE_INT
	_update_metadata()


## Generates a descriptive variable name indicating the domain's SSBO offset.
func _update_metadata() -> void:
	type = TYPE_INT
	var domain_key = Helpers.sim_layers.find_key(target_domain)
	var domain_name : String = domain_key if domain_key != null else str(target_domain)
	name = StringName(domain_name + ".SSBO_OFFSET")


## Returns the starting cluster element offset in the SSBO buffer for this domain.
func get_value() -> Variant:
	type = TYPE_INT
	if not Engine.is_editor_hint():
		# SSBO domains map to [start_offset, capacity]; index 0 is the starting offset.
		if GameStateManager.ssbo_layer_to_indices_map.has(target_domain):
			return GameStateManager.ssbo_layer_to_indices_map[target_domain][0]
	return 0

