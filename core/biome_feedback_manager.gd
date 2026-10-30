extends Node
## Coalesces raw biome transition batches into rate-limited visual particle
## bursts, spatialized audio cues, and UI notifications on the globe.
class_name BiomeFeedbackManager

## Emitted once per coalesced biome cluster in a transition batch for UI feedback listeners.
signal biome_transition_feedback(cell : Vector2i, old_biome : int, new_biome : int, amount : int)

## Target planet mesh to which 3D particle bursts and audio emitters are aligned.
@export var globe : MeshInstance3D

## Maximum number of coalesced biome clusters that can spawn particles/audio in a single diff batch.
@export var max_clusters_per_batch : int = 8

## Optional lookup of `AudioStream` assets keyed by biome naming category; missing entries play nothing.
@export var audio_streams : Dictionary = {}

## Cached lookup table mapping biome IDs (`0..17`) to their naming/audio category strings.
@onready var _category_for_biome : PackedStringArray = RegionNameGenerator.BIOME_CATEGORY

## Container node holding transient 3D particle bursts and audio players.
var _marker_parent : Node3D


## Creates the marker container node and subscribes to `BiomeSnapshotManager.transitions_resolved`.
func _ready() -> void:
	# Create a dedicated child node to parent transient feedback particles and audio players.
	_marker_parent = Node3D.new()
	_marker_parent.name = "BiomeFeedbackMarkers"
	add_child(_marker_parent)
	# Connect to the active snapshot manager's transition signal if available.
	var bsm : BiomeSnapshotManager = GameStateManager.biome_snapshot_manager
	if bsm and not bsm.transitions_resolved.is_connected(_on_transitions):
		bsm.transitions_resolved.connect(_on_transitions)


## Groups a transition batch by target biome ID and triggers up to `max_clusters_per_batch` feedback cues.
func _on_transitions(transitions : Array) -> void:
	if transitions.is_empty():
		return
	# Coalesce cell transitions by `new_biome` so mass succession waves trigger one cue per biome type.
	var clusters : Dictionary = {}
	for t : BiomeTransitionRecord in transitions:
		var new_biome : int = t.new_biome
		if not clusters.has(new_biome):
			@warning_ignore("integer_division")
			clusters[new_biome] = {"count": 0, "first": Vector2i(t.cell_index % _grid_width(), t.cell_index / _grid_width()), "cell": t.cell_index}
		clusters[new_biome]["count"] += 1
		clusters[new_biome]["cell"] = t.cell_index

	# Emit UI signal, particle burst, and spatial audio for each coalesced cluster up to the per-batch cap.
	var emitted : int = 0
	for new_biome : int in clusters:
		if emitted >= max_clusters_per_batch:
			break
		var cluster : Dictionary = clusters[new_biome]
		var cell_index : int = cluster["cell"]
		@warning_ignore("integer_division")
		var cell : Vector2i = Vector2i(cell_index % _grid_width(), cell_index / _grid_width())
		biome_transition_feedback.emit(cell, -1, new_biome, 0)
		_spawn_marker(cell, new_biome)
		_play_cue(new_biome, cell)
		emitted += 1


## Spawns a self-freeing one-shot 3D particle burst on the surface of `globe` at `cell`.
func _spawn_marker(cell : Vector2i, _new_biome : int) -> void:
	if globe == null:
		return
	# Convert 2D grid coordinates to a unit-sphere direction vector matching the terrain UV projection.
	var u : float = (float(cell.x) + 0.5) / _grid_width()
	var v : float = (float(cell.y) + 0.5) / _grid_height()
	var theta : float = u * TAU
	var phi : float = v * PI
	var dir : Vector3 = Vector3(
		sin(phi) * cos(theta),
		cos(phi),
		sin(phi) * sin(theta)
	)
	# Configure a one-shot outward particle burst just above the sphere surface.
	var burst : GPUParticles3D = GPUParticles3D.new()
	burst.amount = 12
	burst.lifetime = 1.2
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.emitting = true
	burst.position = dir * 1.01
	burst.look_at_from_position(burst.position, dir * 2.0 + globe.position)
	var mat : ParticleProcessMaterial = ParticleProcessMaterial.new()
	mat.direction = Vector3(0, 1, 0)
	mat.spread = 60.0
	mat.initial_velocity_min = 0.15
	mat.initial_velocity_max = 0.35
	mat.gravity = Vector3.ZERO
	mat.scale_min = 0.01
	mat.scale_max = 0.03
	burst.process_material = mat
	var mesh : SphereMesh = SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	burst.draw_pass_1 = mesh
	_marker_parent.add_child(burst)
	# Free the particle node automatically after its emission lifetime completes.
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if is_instance_valid(burst):
			burst.queue_free()
	)


## Plays a spatialized 3D audio cue at `cell` for `new_biome`'s category if a stream is configured.
func _play_cue(new_biome : int, cell : Vector2i) -> void:
	# Resolve the biome category and abort silently if no audio stream is assigned for it.
	var category : String = _category_for_biome[new_biome] if new_biome >= 0 and new_biome < _category_for_biome.size() else "grassland"
	if not audio_streams.has(category):
		return
	var stream : AudioStream = audio_streams[category]
	if stream == null:
		return
	# Spawn a temporary 3D audio player positioned on the globe surface and free it on completion.
	var player : AudioStreamPlayer3D = AudioStreamPlayer3D.new()
	player.stream = stream
	player.unit_size = 4.0
	_marker_parent.add_child(player)
	if globe:
		var u : float = (float(cell.x) + 0.5) / _grid_width()
		var v : float = (float(cell.y) + 0.5) / _grid_height()
		var theta : float = u * TAU
		var phi : float = v * PI
		player.position = Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)) * 1.05
	player.finished.connect(player.queue_free)
	player.play()


## Returns the active world grid width, defaulting to 512 if `WorldConfig` is not yet loaded.
func _grid_width() -> int:
	var wc : WorldConfig = GameStateManager.world_config
	return wc.world_width if wc else 512


## Returns the active world grid height, defaulting to 512 if `WorldConfig` is not yet loaded.
func _grid_height() -> int:
	var wc : WorldConfig = GameStateManager.world_config
	return wc.world_height if wc else 512
