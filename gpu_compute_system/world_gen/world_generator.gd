extends GpuWorld
class_name WorldGenerator
## Orchestrates the procedural world generation pipeline using Godot's RenderingDevice and Compute Shaders.

var layer_generators : Array[LayerGenerator]

## Emitted when the world generation process has completed.
signal on_generation_complete

func _init() -> void:
	pass

func _ready() -> void:
	pass

func generate_world() -> void: 
	_has_completed = false
	await initialise_layer_generators()

## Bootstraps the master arrays and loops through each configured generator calling its initialization functions.
func initialise_layer_generators() -> void:
	if not GameStateManager.instance.is_node_ready():
		await GameStateManager.instance.ready
	if is_opengl:
		return
	# Create these shared resources
	world_config = GameStateManager.world_config
	world_state = GameStateManager.current_world_state
	rd = world_state.rd
	layer_generators = world_config.layer_generators
	
	# create derived resources from shared uniform sources.
	for lg : LayerGenerator in layer_generators:
		if lg.is_enabled:
			lg.initialise_layer_generator(rd)
			_total_dispatches += lg.repeat_times
	default_dispatches_per_frame = dispatches_per_frame

# Layer generation local variables
var _has_completed : bool = false
var _layer_index : int = 0
var _repeat_count : int = 0
var _total_dispatches : int = 0
var _current_dispatches : int = 0
@export var dispatches_per_frame : int = 128:
	set(value):
		dispatches_per_frame = value
var default_dispatches_per_frame : int = 128

func get_progress() -> float:
	var progress_amount : float = _current_dispatches as float / _total_dispatches as float
	return progress_amount

## Coordinates progressive staggered generation frames, allowing the main CPU thread to stay active.
@warning_ignore("unused_parameter")
func _process(deltaTime : float) -> void:
	if is_opengl:
		return
	if not _has_completed:
		while (_layer_index < layer_generators.size() and (_repeat_count >= layer_generators[_layer_index].repeat_times or layer_generators[_layer_index].is_enabled == false)):
			_layer_index += 1
			_repeat_count = 0
			dispatches_per_frame = default_dispatches_per_frame
		if _layer_index < layer_generators.size():
			var dispatches_to_send : int = min(dispatches_per_frame, layer_generators[_layer_index].repeat_times - _repeat_count)
			var layer_gen : LayerGenerator = layer_generators[_layer_index]
			
			# Dispatch 'dispatches_to_send' times into a single compute list queue
			layer_gen.dispatch(dispatches_to_send)
			print(layer_gen)
			# We successfully queued 'dispatches_to_send', so we increment the count by that amount!
			_repeat_count += dispatches_to_send
			_current_dispatches += dispatches_to_send
			world_state.swap_state(0)
			if deltaTime > 0.017:
				dispatches_per_frame = ceil(dispatches_per_frame / (deltaTime/(1.0/60.0)))
		else:
			print("World Generation Complete")
			world_state.sync_double_buffers()
			_has_completed = true
			on_generation_complete.emit()
