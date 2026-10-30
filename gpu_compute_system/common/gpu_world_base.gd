@abstract
extends Node
## Abstract base class representing a GPU-managed world system attached to RenderingDevice.
class_name GpuWorld

## Configuration resource specifying world dimensions, scale, and simulation parameters.
var world_config : WorldConfig

## Reference to the Godot low-level RenderingDevice API used to manage GPU textures and compute shaders.
var rd : RenderingDevice

## True if the active rendering driver is OpenGL, which cannot run compute shaders.
var is_opengl : bool = false:
	get:
		if is_opengl:
			push_error("Rendering Driver is OpenGL. Rendering Device cannot be created.")
		return is_opengl

## Active GPU world state managing ping-pong texture arrays and storage buffers in VRAM.
var world_state : GpuWorldState

