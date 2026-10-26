extends GpuWorld
class_name WorldSimulator
## The Godot-side dispatcher that orchestrates the simulation loop using double-buffered float and SSBO states, and a single atomic state.

var sim_layers : Array[LayerSimulator]


func _init() -> void:
	pass
	
func _ready() -> void:
	pass

func start_sim() -> void:
	initialise_sim_layers()
	if world_state:
		world_state.sync_double_buffers()

## Initializes the simulation textures, uniforms, and layer configurations.
func initialise_sim_layers() -> Error:
	if is_opengl:
		return Error.ERR_CANT_CREATE
	world_config = GameStateManager.world_config
	sim_layers = world_config.sim_layers
	world_state = GameStateManager.current_world_state
	
	if not world_state:
		push_error("WorldSimulator initialized without a valid GpuWorldState in GameStateManager.")
		return Error.ERR_CANT_ACQUIRE_RESOURCE
	
	rd = world_state.rd
	
	# Auto-calibrate stefan_scale from the global energy balance formula before layer init,
	# so the thermodynamics push constant picks up the computed value on first dispatch.
	if world_config.auto_calibrate_stefan:
		world_config.calibrate_stefan_scale()
	
	# create derived resources from shared uniform sources.
	for sl : LayerSimulator in sim_layers:
		sl.initialise_sim_layer(rd)
		
	return Error.OK

## Processes the simulation step for a given delta time, dispatching all sim layers and swapping read/write buffer indices.
@warning_ignore("unused_parameter")
func _process(deltaTime : float) -> void:
	if is_opengl or GameStateManager.is_paused:
		return	
		
	# Reduce speed if sim running slower that 60fps
	# if deltaTime > (1.0/35.0): 
	# 		GameStateManager.instance.decrease_sim_speed()

	# process this frame
	for i : int in GameStateManager.sim_speed:
		for layer : LayerSimulator in sim_layers:
			# sim_layers dispatch() includes creating, dispatching and ending a compute list. 
			layer.dispatch(
				world_state.write_world_state_index, 
				GameStateManager.simDeltaTime,
				)
		# NOTE: No end of dispatch barrier needed as Godot 4.6 automatically injects them, 
		# where needed, between compute lists. 
		# swap the textures so the write texture from this frame becomes the read texture. 
		world_state.swap_state()
	world_state.end_frame()
