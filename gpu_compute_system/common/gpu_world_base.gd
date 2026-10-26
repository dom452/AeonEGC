@abstract
extends Node
class_name GpuWorld

var world_config : WorldConfig

## Reference to the global RenderingServer rendering device API.
var rd : RenderingDevice

## Failsafe bool tracking if the user is running an unsupported OpenGL backend.
var is_opengl : bool = false:
	get:
		if is_opengl:
			push_error("Rendering Driver is OpenGL. Rendering Device cannot be created.")
		return is_opengl

## The globally active VRAM representation of the world.
var world_state : GpuWorldState
