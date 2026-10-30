@tool
extends Push_Constant
## Push constant that dynamically reads a numeric or vector parameter from the active WorldConfig resource.
class_name Push_Constant_World_Config

## Name of the property on WorldConfig whose value will be read and passed to the shader.
@export_storage var config_property : String = ""


## Overrides the Godot inspector property list to present WorldConfig properties in a dropdown menu.
func _get_property_list() -> Array[Dictionary]:
	var props : Array[Dictionary] = []
	
	# Fetch valid variables from WorldConfig.
	var valid_props : PackedStringArray = _get_world_config_properties()
	
	# Create a comma-separated list to feed to the Enum Hint.
	var enum_string : String = ",".join(valid_props)
	
	props.append({
		"name": "config_property",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": enum_string
	})
	
	return props


## Inspects WorldConfig and returns an array of property names that can be converted into GLSL shader variables.
func _get_world_config_properties() -> PackedStringArray:
	var dummy : WorldConfig = preload("res://core/world_config.gd").new()
	var valid_props : PackedStringArray = [""]
	
	# Scan for numeric, boolean, or vector script variables supported by push constants.
	for p : Dictionary in dummy.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			if p.type in [TYPE_INT, TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I]:
				valid_props.append(str(p.name))
				
	return valid_props


## Evaluates and returns the selected property's value from the active WorldConfig singleton.
func get_value() -> Variant:
	# Fetch property value from the live active WorldConfig when available.
	if GameStateManager.world_config and config_property != "":
		var val : Variant = GameStateManager.world_config.get(config_property)
		type = typeof(val) as Variant.Type
		return val
	return value


## Returns editor configuration warnings if no property is selected or if a selected property no longer exists.
func _get_configuration_warnings() -> PackedStringArray:
	var warnings : PackedStringArray = []
	if config_property == "":
		warnings.append("No config property selected. Will use fallback 'value'.")
	elif not _get_world_config_properties().has(config_property):
		warnings.append("Property '" + config_property + "' does not exist on WorldConfig! It may have been renamed or deleted.")
	return warnings

