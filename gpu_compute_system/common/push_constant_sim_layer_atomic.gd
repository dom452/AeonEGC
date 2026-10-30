@tool
extends Push_Constant
## Push constant providing the absolute integer texture-array slice index of an Atomic sub-layer to a shader.
class_name PushConstant_SimLayer_Atomic

## The simulation domain containing the target atomic sub-layer (e.g. WATER, LANDSCAPE, FLORA).
@export var target_domain : Helpers.sim_layers:
	set(val):
		target_domain = val
		_update_metadata()
		notify_property_list_changed()

## The specific sub-layer index within the domain (e.g. LIQUID_VOLUME, SOIL_NUTRIENTS, BIOME_TYPE).
@export var target_sub_layer_index : int:
	set(val):
		target_sub_layer_index = val
		_update_metadata()


## Sets integer type and updates the debug name based on the configured atomic sub-layer.
func _init() -> void:
	type = TYPE_INT
	_update_metadata()


## Assembles an identifiable debug name (e.g. "WATER.ATOMIC.LIQUID_VOLUME") and sets integer type.
func _update_metadata() -> void:
	type = TYPE_INT
	var domain_key : String = Helpers.sim_layers.find_key(target_domain)
	var domain_name : String = domain_key if domain_key != null else str(target_domain)
	var sub_layer_names : PackedStringArray = Helpers.atomic_sub_layer_names.get(target_domain, PackedStringArray())
	var sub_name : String = ""
	if target_sub_layer_index >= 0 and target_sub_layer_index < sub_layer_names.size():
		sub_name = sub_layer_names[target_sub_layer_index]
	else:
		sub_name = str(target_sub_layer_index)
	name = StringName(domain_name + ".ATOMIC." + sub_name)


## Configures the Godot inspector dropdown with human-readable atomic sub-layer names.
func _validate_property(property: Dictionary) -> void:
	if property.name == "target_sub_layer_index":
		var sub_layer_names: PackedStringArray = Helpers.atomic_sub_layer_names.get(target_domain, PackedStringArray())
		var hint_string : String = ""
		for i : int in range(sub_layer_names.size()):
			if i > 0:
				hint_string += ","
			hint_string += sub_layer_names[i] + ":" + str(i)
		
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = hint_string


## Resolves and returns the absolute texture array slice index for this atomic sub-layer at runtime.
func get_value() -> Variant:
	type = TYPE_INT
	if not Engine.is_editor_hint():
		# Retrieve the slice index in the atomic texture assigned to this sub-layer.
		return GameStateManager.atomic_layer_to_indices_map[target_domain][target_sub_layer_index]
	return 0

