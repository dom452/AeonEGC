@tool
extends Push_Constant
class_name Push_Constant_World_Config

@export_storage var config_property : String = ""

## We override how Godot draws the inspector for this specific class.
func _get_property_list() -> Array[Dictionary]:
	var props : Array[Dictionary] = []
	
	# Fetch valid variables from WorldConfig
	var valid_props : PackedStringArray = _get_world_config_properties()
	
	# Create a comma-separated list to feed to the Enum Hint
	var enum_string : String = ",".join(valid_props)
	
	props.append({
		"name": "config_property",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": enum_string
	})
	
	return props

## Helper to extract only valid math properties from the WorldConfig script
func _get_world_config_properties() -> PackedStringArray:
	var dummy : WorldConfig = preload("res://core/world_config.gd").new()
	var valid_props : PackedStringArray = [""] # Empty option
	
	for p : Dictionary in dummy.get_property_list():
		# Only look at script variables (not base Resource/RefCounted properties)
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			# Only allow types that can be passed to GLSL
			if p.type in [TYPE_INT, TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I]:
				valid_props.append(str(p.name))
				
	return valid_props

## Runtime evaluation
func get_value() -> Variant:
	if GameStateManager.world_config and config_property != "":
		var val : Variant = GameStateManager.world_config.get(config_property)
		type = typeof(val) as Variant.Type
		return val
	return value

## Editor validation warning
func _get_configuration_warnings() -> PackedStringArray:
	var warnings : PackedStringArray = []
	if config_property == "":
		warnings.append("No config property selected. Will use fallback 'value'.")
	elif not _get_world_config_properties().has(config_property):
		warnings.append("Property '" + config_property + "' does not exist on WorldConfig! It may have been renamed or deleted.")
	return warnings
