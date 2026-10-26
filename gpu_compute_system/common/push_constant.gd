extends Resource
class_name  Push_Constant

@export var name : StringName
@export var value : Variant:
	set(v):
		value = v
		type = typeof(v) as Variant.Type
var type : Variant.Type

func get_value() -> Variant:
	return value
