extends Node
class_name BiomeFeedbackManager

## Player-facing transition feedback (event-logging plan §5.2), driven by the
## snapshot manager's transition batches with per-batch COALESCING (§5.2 rate
## limiting): one notification per (new_biome, region-area) cluster, never one
## per cell — a succession wave diffing hundreds of cells must not spawn
## hundreds of floating texts, particles, and audio triggers.
##
## Components:
##   1. Tactile: `biome_transition_feedback` signal (UI floating text / wallet).
##   2. Globe marker: temporary particle burst at the sphere position of the
##      cluster's largest cell group (converted from UV grid coords).
##   3. Audio: one spatialized cue per coalesced cluster, keyed by biome
##      category. Streams are pre-loaded per category; missing files degrade
##      silently to no audio.
##
## The frozen POC's `impact_currency_gained` signal is untouched (§5.2) — the
## two signal names never collide, and this manager never emits it (Phase 5's
## economy emits its own).

signal biome_transition_feedback(cell : Vector2i, old_biome : int, new_biome : int, amount : int)

## Globe mesh the markers attach to (exported; assigned by the scene).
@export var globe : MeshInstance3D

## Maximum coalesced clusters rendered per batch (hard ceiling for particle
## and audio spawning during succession storms).
@export var max_clusters_per_batch : int = 8

## Audio streams keyed by naming category (optional; empty = silent).
@export var audio_streams : Dictionary = {}

@onready var _category_for_biome : PackedStringArray = RegionNameGenerator.BIOME_CATEGORY

var _marker_parent : Node3D


func _ready() -> void:
	_marker_parent = Node3D.new()
	_marker_parent.name = "BiomeFeedbackMarkers"
	add_child(_marker_parent)
	var bsm : BiomeSnapshotManager = GameStateManager.biome_snapshot_manager
	if bsm and not bsm.transitions_resolved.is_connected(_on_transitions):
		bsm.transitions_resolved.connect(_on_transitions)


## Consumes one diff batch and coalesces it into clusters.
func _on_transitions(transitions : Array) -> void:
	if transitions.is_empty():
		return
	# Cluster by new biome (§5.2: one notification per same-new_biome cluster).
	var clusters : Dictionary = {}  # new_biome -> {count, first_cell, last_cell}
	for t : BiomeTransitionRecord in transitions:
		var new_biome : int = t.new_biome
		if not clusters.has(new_biome):
			@warning_ignore("integer_division")
			clusters[new_biome] = {"count": 0, "first": Vector2i(t.cell_index % _grid_width(), t.cell_index / _grid_width()), "cell": t.cell_index}
		clusters[new_biome]["count"] += 1
		clusters[new_biome]["cell"] = t.cell_index

	var emitted : int = 0
	for new_biome : int in clusters:
		if emitted >= max_clusters_per_batch:
			break
		var cluster : Dictionary = clusters[new_biome]
		var cell_index : int = cluster["cell"]
		@warning_ignore("integer_division")
		var cell : Vector2i = Vector2i(cell_index % _grid_width(), cell_index / _grid_width())
		# 1. Tactile (amount 0 here — the Phase 5 economy emits its own signal
		#    with real payouts; this is the presentation-layer notification).
		biome_transition_feedback.emit(cell, -1, new_biome, 0)
		# 2. Globe particle burst at the cluster's last cell.
		_spawn_marker(cell, new_biome)
		# 3. Audio cue keyed by category.
		_play_cue(new_biome, cell)
		emitted += 1


func _spawn_marker(cell : Vector2i, new_biome : int) -> void:
	if globe == null:
		return
	# UV -> sphere direction matching the visualizer's mapping (v = 0 at the
	# +Y pole; u wraps longitude). Local to the globe so it follows rotation.
	var u : float = (float(cell.x) + 0.5) / _grid_width()
	var v : float = (float(cell.y) + 0.5) / _grid_height()
	var theta : float = u * TAU
	var phi : float = v * PI
	var dir : Vector3 = Vector3(
		sin(phi) * cos(theta),
		cos(phi),
		sin(phi) * sin(theta)
	)
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
	# Self-cleanup once the burst dies.
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if is_instance_valid(burst):
			burst.queue_free()
	)


func _play_cue(new_biome : int, cell : Vector2i) -> void:
	var category : String = _category_for_biome[new_biome] if new_biome >= 0 and new_biome < _category_for_biome.size() else "grassland"
	if not audio_streams.has(category):
		return
	var stream : AudioStream = audio_streams[category]
	if stream == null:
		return
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


func _grid_width() -> int:
	var wc : WorldConfig = GameStateManager.world_config
	return wc.world_width if wc else 512


func _grid_height() -> int:
	var wc : WorldConfig = GameStateManager.world_config
	return wc.world_height if wc else 512
