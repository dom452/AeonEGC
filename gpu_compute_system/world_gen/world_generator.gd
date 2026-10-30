extends GpuWorld
## Orchestrates procedural world generation compute passes across multiple frames,
## running compute shaders iteratively without freezing the engine's main thread.
class_name WorldGenerator

## Ordered list of compute pass generators configured on WorldConfig to execute during generation.
var layer_generators : Array[LayerGenerator]

## Emitted once all enabled layer generators have finished all repeated dispatches.
signal on_generation_complete

## True when all configured generation layers have completed execution.
var _has_completed : bool = false
## Index of the current LayerGenerator being executed in `layer_generators`.
var _layer_index : int = 0
## Number of times the current layer generator has already been dispatched.
var _repeat_count : int = 0
## Total number of GPU dispatches required across all enabled generation passes.
var _total_dispatches : int = 0
## Total number of GPU dispatches completed so far.
var _current_dispatches : int = 0
## Maximum number of compute shader dispatches submitted per frame to prevent GPU driver timeouts.
@export var dispatches_per_frame : int = 128:
	set(value):
		dispatches_per_frame = value
## Baseline dispatch budget per frame restored when advancing to a new generation layer.
var default_dispatches_per_frame : int = 128


## Unused initialization constructor.
func _init() -> void:
	pass


## Unused ready callback.
func _ready() -> void:
	pass


## Resets generation state flags and initializes the compute pass pipeline.
func generate_world() -> void: 
	# Reset completion flag and initialize all generation passes.
	_has_completed = false
	await initialise_layer_generators()


## Binds GPU world state and initializes compiled shaders, pipelines, and noise inputs for each enabled generator.
func initialise_layer_generators() -> void:
	# Ensure GameStateManager is fully ready before accessing shared singletons.
	if not GameStateManager.instance.is_node_ready():
		await GameStateManager.instance.ready
	if is_opengl:
		return

	# Bind shared world configuration and RenderingDevice resources.
	world_config = GameStateManager.world_config
	world_state = GameStateManager.current_world_state
	rd = world_state.rd
	layer_generators = world_config.layer_generators
	
	# Prepare each enabled generator pass and compute the total dispatch count.
	for lg : LayerGenerator in layer_generators:
		if lg.is_enabled:
			lg.initialise_layer_generator(rd)
			_total_dispatches += lg.repeat_times
	default_dispatches_per_frame = dispatches_per_frame


## Returns normalized overall generation progress from 0.0 (just started) to 1.0 (completed).
func get_progress() -> float:
	# Compute ratio of completed dispatches against total required dispatches.
	var progress_amount : float = _current_dispatches as float / _total_dispatches as float
	return progress_amount


## Dispatches a budgeted batch of compute passes each frame, dynamically throttling batch size if framerate drops.
@warning_ignore("unused_parameter")
func _process(deltaTime : float) -> void:
	if is_opengl:
		return
	if not _has_completed:
		# Advance past any generators that are disabled or have completed their required repeat count.
		while (_layer_index < layer_generators.size() and (_repeat_count >= layer_generators[_layer_index].repeat_times or layer_generators[_layer_index].is_enabled == false)):
			_layer_index += 1
			_repeat_count = 0
			dispatches_per_frame = default_dispatches_per_frame
		# Dispatch the current generator if more passes remain.
		if _layer_index < layer_generators.size():
			var dispatches_to_send : int = min(dispatches_per_frame, layer_generators[_layer_index].repeat_times - _repeat_count)
			var layer_gen : LayerGenerator = layer_generators[_layer_index]
			
			# Submit the budgeted number of dispatches to the GPU command queue.
			layer_gen.dispatch(dispatches_to_send)
			print(layer_gen)
			_repeat_count += dispatches_to_send
			_current_dispatches += dispatches_to_send
			world_state.swap_state(0)
			# Reduce dispatches per frame if the frame time exceeded 16.6ms (dropping below 60 FPS) to maintain responsiveness.
			if deltaTime > 0.017:
				dispatches_per_frame = ceil(dispatches_per_frame / (deltaTime/(1.0/60.0)))
		else:
			# Finalize world generation: synchronize ping-pong buffers so read and write states match, then emit completion.
			print("World Generation Complete")
			world_state.sync_double_buffers()
			_has_completed = true
			on_generation_complete.emit()

