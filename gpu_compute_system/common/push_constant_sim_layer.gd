@tool
extends Push_Constant
## Push constant providing the absolute integer texture-array slice index of a fine Float sub-layer to a shader.
class_name PushConstant_SimLayer

## The high-level simulation domain (e.g. LANDSCAPE, WATER, ATMOSPHERE) containing the target sub-layer.
@export var target_domain : Helpers.sim_layers:
	set(val):
		target_domain = val
		_update_metadata()
		notify_property_list_changed()

## The specific sub-layer index within the selected simulation domain (e.g. BEDROCK_HEIGHT, AIR_TEMP).
@export var target_sub_layer_index : int:
	set(val):
		target_sub_layer_index = val
		_update_metadata()


## Sets integer type and derives the variable name from domain and sub-layer.
func _init() -> void:
	type = TYPE_INT
	_update_metadata()


## Constructs a human-readable identifier (e.g. "LANDSCAPE.BEDROCK_HEIGHT") and sets integer type.
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


## Customizes the Godot inspector dropdown to display readable sub-layer names instead of raw integer indices.
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


## Resolves and returns the absolute texture array slice index for this float sub-layer at runtime.
func get_value() -> Variant:
	type = TYPE_INT
	if not Engine.is_editor_hint():
		# Look up the actual slice index assigned to this sub-layer in the active world.
		return GameStateManager.float_layer_to_indices_map[target_domain][target_sub_layer_index]
	return 0

