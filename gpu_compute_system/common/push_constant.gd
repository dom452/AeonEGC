extends Resource
## Base resource for defining a push constant variable passed directly to a compute shader.
class_name Push_Constant

## Unique variable name for this push constant used in inspector listings and logging.
@export var name : StringName
## Value held by this push constant; automatically determines `type` when assigned.
@export var value : Variant:
	set(v):
		value = v
		type = typeof(v) as Variant.Type
## The Variant.Type enum indicating how many bytes and what format this variable takes in GLSL memory.
var type : Variant.Type

## Returns the current value to be packed into the push constant byte buffer for GPU dispatch.
func get_value() -> Variant:
	# Return the stored variant value directly.
	return value

