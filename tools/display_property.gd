extends Label

@export var target : Node:
	set(value):
		if value == self:
			target = null
		else:
			target = value
		notify_property_list_changed()

@export var config_property : String = ""

@export var clamped_decimals : int = 0

## Runtime evaluation
func get_value() -> String:
	if is_instance_valid(target) and config_property != "":
		var params : PackedStringArray = config_property.split(".")
		var current : Variant = target
		for i : int in params.size():
			@warning_ignore("unsafe_method_access")
			current = current.get(params[i])
			if i == params.size()-1 and current != null:
				if current is float:
					current = ("%." + str(clamped_decimals) + "f") % current
					return current
				return str(current)
	return ""
	
func _process(_delta: float) -> void:
	text = get_value()
