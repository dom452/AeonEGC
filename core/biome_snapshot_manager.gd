extends Node
## Periodically reads back the GPU `BIOME_TYPE` atomic layer and diffs it on a
## worker thread against a CPU shadow copy to emit lossless cell transition batches.
class_name BiomeSnapshotManager

## Real-time interval in seconds between consecutive `BIOME_TYPE` GPU readbacks.
@export var snapshot_interval : float = 1.0

## When true, prints snapshot initialization and diff timing summaries to the console.
@export var debug_output : bool = false

## Emitted on the main thread with the ascending-cell-index batch of transitions from one diff.
signal transitions_resolved(transitions : Array[BiomeTransitionRecord])

## Emitted once on the main thread after the initial full readback populates `_shadow`.
signal shadow_ready

## True once `_shadow` holds an initialized snapshot from the GPU.
var has_shadow : bool = false

## Active GPU world state whose `atomic_state_texture` is sampled.
var _world_state : GpuWorldState
## Absolute layer index of `LANDSCAPE.BIOME_TYPE` inside `atomic_state_texture`.
var _biome_layer_index : int = -1
## Per-cell CPU shadow buffer storing the most recently committed 32-bit `BIOME_TYPE` texels.
var _shadow : PackedInt32Array = PackedInt32Array()
## True while an async GPU readback is currently in flight.
var _in_flight : bool = false
## Elapsed real-time seconds accumulated since the last snapshot request.
var _accum : float = 0.0
## Monotonically increasing counter guarding against commits from superseded worker tasks.
var _diff_generation : int = 0
## True once `shadow_ready` has been emitted for the current world binding.
var _shadow_ready_emitted : bool = false
## Total number of grid cells (`world_width * world_height`) in the bound world.
var _cell_count : int = 0
## Timestamp (`Time.get_ticks_msec()`) of the most recent committed diff or shadow initialization.
var _last_diff_msec : int = 0
## Timestamp (`Time.get_ticks_msec()`) when the current worker diff task was dispatched.
var _last_cycle_msec : int = 0
## True when the most recent `_scan_diff` call validated the readback buffer size without error.
var _scan_succeeded : bool = false


## Disables per-frame processing until `bind_world_state` attaches a live `GpuWorldState`.
func _ready() -> void:
	set_process(false)


## Binds the manager to `ws`, allocates the CPU shadow buffer, and enables periodic snapshot polling.
func bind_world_state(ws : GpuWorldState) -> void:
	# Resolve the BIOME_TYPE atomic layer index and allocate a zeroed shadow buffer for the grid.
	_world_state = ws
	_biome_layer_index = GameStateManager.atomic_layer_to_indices_map[Helpers.sim_layers.LANDSCAPE][3]
	_cell_count = GameStateManager.world_config.world_width * GameStateManager.world_config.world_height
	_shadow.resize(_cell_count)
	_shadow.fill(0)
	# Reset state flags and increment generation to invalidate any worker tasks from a prior world.
	has_shadow = false
	_shadow_ready_emitted = false
	_in_flight = false
	_accum = 0.0
	_diff_generation += 1
	set_process(true)


## Detaches the active world state, invalidates in-flight workers, and halts periodic polling.
func unbind() -> void:
	# Advance generation so any running worker discards its result on completion.
	_diff_generation += 1
	_world_state = null
	has_shadow = false
	set_process(false)


## Requests the initial full `BIOME_TYPE` GPU readback to populate `_shadow` and emit `shadow_ready`.
func initialize_shadow_from_gpu() -> void:
	# Guard against uninitialized world state or overlapping readback requests.
	if _world_state == null or _world_state.rd == null:
		push_error("BiomeSnapshotManager: initialize_shadow_from_gpu() called before bind_world_state().")
		return
	if _in_flight:
		push_warning("BiomeSnapshotManager: bootstrap readback requested while one is in flight; ignoring.")
		return
	# Issue an async GPU readback tagged as a bootstrap cycle.
	_in_flight = true
	var rd : RenderingDevice = _world_state.rd
	var err : Error = rd.texture_get_data_async(
		_world_state.atomic_state_texture,
		_biome_layer_index,
		_on_snapshot_received.bind(true)
	)
	if err != OK:
		push_error("BiomeSnapshotManager: bootstrap texture_get_data_async failed (err %d)." % err)
		_in_flight = false


## Accumulates real frame time and requests a non-bootstrap snapshot every `snapshot_interval` seconds.
func _process(delta : float) -> void:
	# Skip polling while a readback is already in flight or before the bootstrap shadow is ready.
	if _in_flight or not has_shadow or _world_state == null:
		return
	# Trigger a periodic snapshot request once the interval timer elapses.
	_accum += delta
	if _accum < snapshot_interval:
		return
	_accum = 0.0
	_request_snapshot(false)


## Issues an asynchronous GPU readback of the `BIOME_TYPE` layer from `atomic_state_texture`.
func _request_snapshot(is_bootstrap : bool) -> void:
	if _world_state == null or _world_state.rd == null:
		return
	# Mark readback in-flight and register `_on_snapshot_received` as the completion callback.
	_in_flight = true
	var rd : RenderingDevice = _world_state.rd
	var err : Error = rd.texture_get_data_async(
		_world_state.atomic_state_texture,
		_biome_layer_index,
		_on_snapshot_received.bind(is_bootstrap)
	)
	if err != OK:
		push_error("BiomeSnapshotManager: texture_get_data_async failed (err %d)." % err)
		_in_flight = false


## Validates the raw readback byte size and dispatches either the bootstrap or diff worker task.
func _on_snapshot_received(data : PackedByteArray, is_bootstrap : bool) -> void:
	_in_flight = false
	# Discard the callback if the world was torn down while the readback was in flight.
	if _world_state == null or _world_state.rd == null:
		return

	# Verify the readback matches the expected 4-byte `R32_UINT` texel count.
	var expected_bytes : int = _cell_count * 4
	if data.size() != expected_bytes:
		push_error("BiomeSnapshotManager: readback size mismatch — expected %d bytes, got %d."
			% [expected_bytes, data.size()])
		return
	
	var gen : int = _diff_generation

	# Route to the bootstrap worker when `_shadow` has not yet been initialized.
	if not has_shadow:
		_diff_generation += 1
		gen = _diff_generation
		WorkerThreadPool.add_task(_bootstrap_worker.bind(data, gen))
		return

	# Route to the periodic diff worker when `_shadow` is already initialized.
	_diff_generation += 1
	gen = _diff_generation
	_last_cycle_msec = Time.get_ticks_msec()
	WorkerThreadPool.add_task(_diff_worker.bind(data, gen, is_bootstrap))


## Converts the first GPU snapshot into `_shadow` on a worker thread and defers `shadow_ready` to the main thread.
func _bootstrap_worker(data : PackedByteArray, gen : int) -> void:
	# Abort if a newer world binding superseded this worker task.
	if gen != _diff_generation:
		return
	# Convert raw bytes to 32-bit integers and validate element count.
	var texels : PackedInt32Array = data.to_int32_array()
	if texels.size() != _cell_count:
		_on_bootstrap_failed.call_deferred()
		return
	# Store the initial shadow copy and schedule `shadow_ready` emission on the main thread.
	_shadow = texels.duplicate()
	has_shadow = true
	_on_shadow_ready.call_deferred()


## Logs an error on the main thread when a readback buffer fails integer-array size validation.
func _on_bootstrap_failed() -> void:
	push_error("BiomeSnapshotManager: bootstrap readback produced an unexpected layout; shadow NOT initialized.")


## Marks bootstrap completion on the main thread and emits `shadow_ready` once.
func _on_shadow_ready() -> void:
	if _shadow_ready_emitted:
		return
	_shadow_ready_emitted = true
	_last_diff_msec = Time.get_ticks_msec()
	if debug_output:
		print("[BiomeSnapshotManager] shadow initialized (%d cells, %d KiB)."
			% [_cell_count, float(_shadow.size()) * 4.0 / 1024.0])
	shadow_ready.emit()


## Runs `_scan_diff` on a worker thread and schedules `_commit_diff` on the main thread.
func _diff_worker(data : PackedByteArray, gen : int, _is_bootstrap : bool) -> void:
	# Abort if the world binding changed before the worker started.
	if gen != _diff_generation:
		return
	# Scan for biome transitions and defer the resulting batch to the main thread.
	var start_msec : int = Time.get_ticks_msec()
	var transitions : Array[BiomeTransitionRecord] = _scan_diff(data, gen)
	if transitions.is_empty() and not _scan_succeeded:
		return
	var diff_msec : int = Time.get_ticks_msec() - start_msec
	_commit_diff.call_deferred(transitions, gen, diff_msec)


## Compares `data` against `_shadow`, updates `_shadow` in place, and returns all valid biome transitions.
func _scan_diff(data : PackedByteArray, _gen : int) -> Array[BiomeTransitionRecord]:
	_scan_succeeded = false
	var transitions : Array[BiomeTransitionRecord] = []
	var texels : PackedInt32Array = data.to_int32_array()
	if texels.size() != _cell_count:
		_on_bootstrap_failed.call_deferred()
		return transitions
	_scan_succeeded = true

	var max_valid : int = Helpers.BIOME_MAX_VALID_ID
	var id_mask : int = Helpers.BIOME_TEXEL_ID_MASK
	var attr_shift : int = Helpers.BIOME_TEXEL_ATTRIBUTION_SHIFT
	var shadow : PackedInt32Array = _shadow

	# Compare each cell's new texel against the shadow copy in ascending cell-index order.
	for i : int in _cell_count:
		var new_texel : int = texels[i]
		var old_texel : int = shadow[i]
		if new_texel == old_texel:
			continue
		var new_id : int = new_texel & id_mask
		var old_id : int = old_texel & id_mask
		# Emit a transition record when both old and new biome IDs are valid and distinct.
		if old_id != new_id and old_id <= max_valid and new_id <= max_valid:
			var rec : BiomeTransitionRecord = BiomeTransitionRecord.new()
			rec.cell_index = i
			rec.old_biome = old_id
			rec.new_biome = new_id
			rec.attribution_bits = (new_texel >> attr_shift) & 0xFFFFFF
			transitions.append(rec)
		# Always update the shadow texel so attribution bits stay current even when the biome ID is unchanged.
		shadow[i] = new_texel
	return transitions


## Emits `transitions_resolved` on the main thread if `gen` matches the active generation and `transitions` is non-empty.
func _commit_diff(transitions : Array[BiomeTransitionRecord], gen : int, diff_msec : int) -> void:
	# Discard stale worker results if the world was rebound before main-thread commit.
	if gen != _diff_generation:
		return
	_last_diff_msec = Time.get_ticks_msec()
	if debug_output and not transitions.is_empty():
		var cycle_ms : int = _last_diff_msec - _last_cycle_msec
		print("[BiomeSnapshotManager] %d transitions (diff %d ms, cycle %d ms) — first: cell %d %d->%d attr 0x%X"
			% [transitions.size(), diff_msec, cycle_ms,
			transitions[0].cell_index, transitions[0].old_biome,
			transitions[0].new_biome, transitions[0].attribution_bits])
	if not transitions.is_empty():
		transitions_resolved.emit(transitions)


## Returns the raw 32-bit `BIOME_TYPE` shadow texel at `cell_index`, or 0 if out of bounds.
func get_shadow_texel(cell_index : int) -> int:
	if cell_index < 0 or cell_index >= _shadow.size():
		return 0
	return _shadow[cell_index]


## Returns the low-byte biome ID (`0..17` or `255`) from the shadow texel at `cell_index`.
func get_shadow_biome(cell_index : int) -> int:
	return get_shadow_texel(cell_index) & Helpers.BIOME_TEXEL_ID_MASK


## Returns a duplicate copy of the entire `_shadow` texel buffer for initial region-graph labeling.
func get_shadow_snapshot() -> PackedInt32Array:
	return _shadow.duplicate()
