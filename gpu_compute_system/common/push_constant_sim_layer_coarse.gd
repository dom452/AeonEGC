@tool
extends Push_Constant
## Push constant providing the integer slice index of a 64x64 Coarse Dynamics layer to a compute shader.
class_name PushConstant_SimLayer_Coarse

## The coarse grid layer enum (e.g. H_UPPER, WIND_LOWER_X, AIR_TEMP) to expose to the shader.
@export var target_coarse_layer : Helpers.coarse_layers:
	set(val):
		target_coarse_layer = val
		_update_metadata()
		notify_property_list_changed()


## Sets integer type and updates the metadata name.
func _init() -> void:
	type = TYPE_INT
	_update_metadata()


## Constructs an identifiable debug name (e.g. "COARSE.H_LOWER") and sets integer type.
func _update_metadata() -> void:
	type = TYPE_INT
	var layer_key : String = Helpers.coarse_layers.find_key(target_coarse_layer)
	var layer_name : String = layer_key if layer_key != null else str(target_coarse_layer)
	name = StringName("COARSE." + layer_name)


## Returns the integer slice index allocated in the coarse texture array for this layer.
func get_value() -> Variant:
	type = TYPE_INT
	if not Engine.is_editor_hint():
		# Retrieve the slice index in the coarse texture array mapped to this enum.
		if GameStateManager.coarse_layer_to_indices_map.has(target_coarse_layer):
			return GameStateManager.coarse_layer_to_indices_map[target_coarse_layer]
	return int(target_coarse_layer)

