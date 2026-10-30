extends GpuWorld
## Orchestrates the runtime simulation pipeline by dispatching each configured LayerSimulator
## compute pass in sequence, stepping fixed-rate physics, and swapping ping-pong buffers each frame.
class_name WorldSimulator

## Ordered list of runtime simulation compute passes configured in WorldConfig.
var sim_layers : Array[LayerSimulator]


## Unused initialization constructor.
func _init() -> void:
	pass


## Unused ready callback.
func _ready() -> void:
	pass


## Initializes all simulation compute passes and synchronizes ping-pong buffers so read/write states match.
func start_sim() -> void:
	# Initialize all shader passes and synchronize double-buffered textures.
	initialise_sim_layers()
	if world_state:
		world_state.sync_double_buffers()


## Binds world state, auto-calibrates radiative cooling, and initializes compute pipelines for each sim layer.
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
	
	# Auto-calibrate radiative cooling constant (stefan_scale) so global mean temperature settles at the design target.
	if world_config.auto_calibrate_stefan:
		world_config.calibrate_stefan_scale()
	
	# Initialize compiled shaders, pipelines, and uniform sets for each runtime pass.
	for sl : LayerSimulator in sim_layers:
		sl.initialise_sim_layer(rd)
		
	return Error.OK


## Dispatches all simulation passes across `sim_speed` iterations per frame at a fixed 60 Hz timestep (`0.01667s`).
@warning_ignore("unused_parameter")
func _process(deltaTime : float) -> void:
	if is_opengl or GameStateManager.is_paused:
		return	

	# Run the full simulation pipeline once per speed multiplier tick (up to max_sim_speed passes per frame).
	for i : int in GameStateManager.sim_speed:
		for layer : LayerSimulator in sim_layers:
			# Dispatch this compute pass into a command list writing to the write_world_state_index buffer.
			layer.dispatch(
				world_state.write_world_state_index, 
				GameStateManager.simDeltaTime,
			)
		# Swap ping-pong buffer indices so newly written data becomes readable by subsequent steps.
		world_state.swap_state()
	# Notify visualizers and inspectors that a new read frame has completed.
	world_state.end_frame()

