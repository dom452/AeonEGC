extends Node
class_name BiomeSnapshotManager

## CPU-side snapshot/diff pipeline for the biome classification system
## (_planning/event_logging_system_plan.md §3.1 — Option C: the CPU derives
## transitions from full-state diffing, never from an event stream).
##
## Cycle (every `snapshot_interval` real seconds while the sim runs):
##   1. REQUEST — `RenderingDevice.texture_get_data_async()` of the BIOME_TYPE
##      layer of the atomic texture. Gated by an in-flight flag: never two
##      readbacks of the same layer at once.
##   2. DIFF — the callback hands the raw bytes to a WorkerThreadPool task; a
##      linear scan compares each texel's biome byte against the shadow copy
##      and emits one BiomeTransitionRecord per mismatch. The shadow is then
##      updated to the read-back state inside the same worker task (the task
##      exclusively owns both arrays; the main thread never touches them
##      between request and commit).
##   3. APPLY — on the main thread the transition batch is emitted via
##      `transitions_resolved` (RegionGraphManager consumes it in Phase 3)
##      and the first-diff bootstrap signal fires once after generation.
##
## Semantics (plan §2.6):
##   - A texel whose biome byte is 255 (or otherwise > BIOME_MAX_VALID_ID) is
##     UNCLASSIFIED: mismatches involving it are no-ops (no record).
##   - Attribution-bit-only changes (same biome) are ignored by the graph but
##     still refresh the shadow so causation data stays current.
##
## Bootstrap: `initialize_shadow_from_gpu()` performs the first readback and,
## on success, emits `shadow_ready` exactly once — the Phase 3 hook point for
## the initial CCL (§3.4). Until that fires, periodic diffing is suppressed.

## Real-time seconds between BIOME_TYPE readbacks (plan default: 1 Hz).
@export var snapshot_interval : float = 1.0

## Opt-in debug output. The plan (§3.1) forbids replicating the frozen POC's
## auto-generated HUD label; this prints to the console only.
@export var debug_output : bool = false

## Emitted on the main thread with the batch of transitions derived from one
## diff. Order within the batch follows ascending cell index (the diff is a
## linear scan), which RegionGraphManager may rely on for determinism.
signal transitions_resolved(transitions : Array[BiomeTransitionRecord])

## Emitted once after the first successful full readback + shadow
## initialization (used by Phase 3 to run the one-time initial CCL).
signal shadow_ready

## True once the shadow holds a real GPU snapshot (after generation or load).
var has_shadow : bool = false

var _world_state : GpuWorldState
var _biome_layer_index : int = -1
var _shadow : PackedInt32Array = PackedInt32Array()  # one entry per cell: full texel
var _in_flight : bool = false
var _accum : float = 0.0
var _diff_generation : int = 0  # guards against stale worker commits
var _shadow_ready_emitted : bool = false
var _cell_count : int = 0
var _last_diff_msec : int = 0
var _last_cycle_msec : int = 0


func _ready() -> void:
	set_process(false)


## Wires the manager to the live GPU state and arms the cadence. Call after
## generation completes or after a save load. `first_diff_is_bootstrap`
## controls whether the next full diff emits transitions (true after a
## load with no saved graph: the initial CCL fallback owns that diff).
func bind_world_state(ws : GpuWorldState) -> void:
	_world_state = ws
	_biome_layer_index = GameStateManager.atomic_layer_to_indices_map[Helpers.sim_layers.LANDSCAPE][3]
	_cell_count = GameStateManager.world_config.world_width * GameStateManager.world_config.world_height
	_shadow.resize(_cell_count)
	_shadow.fill(0)
	has_shadow = false
	_shadow_ready_emitted = false
	_in_flight = false
	_accum = 0.0
	_diff_generation += 1  # invalidate any in-flight worker from a previous world
	set_process(true)


## Stops the cadence and drops the shadow (used on world unload/teardown).
func unbind() -> void:
	_diff_generation += 1
	_world_state = null
	has_shadow = false
	set_process(false)


## Performs the first full readback and initializes the shadow; emits
## `shadow_ready` once on success. Called by GameStateManager on
## `on_generation_complete` (§2.5 CPU handoff) or on the legacy-load path.
func initialize_shadow_from_gpu() -> void:
	if _world_state == null or _world_state.rd == null:
		push_error("BiomeSnapshotManager: initialize_shadow_from_gpu() called before bind_world_state().")
		return
	if _in_flight:
		push_warning("BiomeSnapshotManager: bootstrap readback requested while one is in flight; ignoring.")
		return
	_in_flight = true
	# Pending-generation marker: the worker will emit shadow_ready instead of
	# a transition batch for this cycle (mode flag captured by the bind below).
	var rd : RenderingDevice = _world_state.rd
	var err : Error = rd.texture_get_data_async(
		_world_state.atomic_state_texture,
		_biome_layer_index,
		_on_snapshot_received.bind(true)
	)
	if err != OK:
		push_error("BiomeSnapshotManager: bootstrap texture_get_data_async failed (err %d)." % err)
		_in_flight = false


func _process(delta : float) -> void:
	if _in_flight or not has_shadow or _world_state == null:
		# In-flight gating: never two readbacks at once (plan §3.1 step 1).
		# Also self-throttles while a diff worker is committing.
		return
	_accum += delta
	if _accum < snapshot_interval:
		return
	_accum = 0.0
	_request_snapshot(false)


func _request_snapshot(is_bootstrap : bool) -> void:
	if _world_state == null or _world_state.rd == null:
		return
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


## Async callback (verified main-thread by the Phase 2 gate harness).
## `is_bootstrap` distinguishes the shadow-init cycle from a diff cycle.
func _on_snapshot_received(data : PackedByteArray, is_bootstrap : bool) -> void:
	_in_flight = false
	if _world_state == null or _world_state.rd == null:
		return  # world torn down mid-flight; drop the stale bytes

	var expected_bytes : int = _cell_count * 4  # R32_UINT: 4 bytes per cell
	if data.size() != expected_bytes:
		push_error("BiomeSnapshotManager: readback size mismatch — expected %d bytes, got %d."
			% [expected_bytes, data.size()])
		return
	
	var gen : int = _diff_generation

	if not has_shadow:
		# Bootstrap semantics regardless of which entry point requested it.
		# The full-copy + shadow-init runs on a worker; ~1 MB memcpy + zeroing.
		_diff_generation += 1
		gen = _diff_generation
		WorkerThreadPool.add_task(_bootstrap_worker.bind(data, gen))
		return

	# Periodic diff cycle.
	_diff_generation += 1
	gen = _diff_generation
	_last_cycle_msec = Time.get_ticks_msec()
	WorkerThreadPool.add_task(_diff_worker.bind(data, gen, is_bootstrap))


## Worker: initializes the shadow from the first full snapshot.
func _bootstrap_worker(data : PackedByteArray, gen : int) -> void:
	if gen != _diff_generation:
		return  # superseded by a newer world/bind; discard
	var texels : PackedInt32Array = data.to_int32_array()
	if texels.size() != _cell_count:
		# to_int32_array() size surprise would indicate a driver layout break;
		# refuse to corrupt the shadow (gate harness covers byte layout).
		_on_bootstrap_failed.call_deferred()
		return
	_shadow = texels.duplicate()
	has_shadow = true
	_on_shadow_ready.call_deferred()


func _on_bootstrap_failed() -> void:
	push_error("BiomeSnapshotManager: bootstrap readback produced an unexpected layout; shadow NOT initialized.")


func _on_shadow_ready() -> void:
	if _shadow_ready_emitted:
		return
	_shadow_ready_emitted = true
	_last_diff_msec = Time.get_ticks_msec()
	if debug_output:
		print("[BiomeSnapshotManager] shadow initialized (%d cells, %d KiB)."
			% [_cell_count, float(_shadow.size()) * 4.0 / 1024.0])
	shadow_ready.emit()


## Worker: linear-scan diff of snapshot vs shadow. Both arrays are exclusively
## owned by this task until commit (the main thread never touches them while
## `_in_flight` or the generation guard holds).
func _diff_worker(data : PackedByteArray, gen : int, _is_bootstrap : bool) -> void:
	if gen != _diff_generation:
		return  # superseded; discard (e.g. unbind() mid-diff)
	var start_msec : int = Time.get_ticks_msec()
	var transitions : Array[BiomeTransitionRecord] = _scan_diff(data, gen)
	if transitions.is_empty() and not _scan_succeeded:
		return  # layout failure already reported by the seam
	var diff_msec : int = Time.get_ticks_msec() - start_msec
	_commit_diff.call_deferred(transitions, gen, diff_msec)


## The diff loop proper: compare `data` against `_shadow`, emit one record per
## classified biome change, refresh the shadow to the snapshot state. Shared
## by the worker thread (production) and synchronous tests (verification).
var _scan_succeeded : bool = false

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
	var shadow : PackedInt32Array = _shadow  # worker-exclusive until commit (generation guard)

	for i : int in _cell_count:
		var new_texel : int = texels[i]
		var old_texel : int = shadow[i]
		if new_texel == old_texel:
			continue
		var new_id : int = new_texel & id_mask
		var old_id : int = old_texel & id_mask
		# Shadow refresh happens for EVERY mismatched cell (below); transition
		# records only for real biome changes between two classified states
		# (255 on either side is a no-op per plan §2.6).
		if old_id != new_id and old_id <= max_valid and new_id <= max_valid:
			var rec : BiomeTransitionRecord = BiomeTransitionRecord.new()
			rec.cell_index = i
			rec.old_biome = old_id
			rec.new_biome = new_id
			rec.attribution_bits = (new_texel >> attr_shift) & 0xFFFFFF
			transitions.append(rec)
		shadow[i] = new_texel
	return transitions


## Main-thread commit: emit the batch (RegionGraphManager applies it in
## Phase 3) and update debug stats. `transitions` is passed by reference from
## the worker — the generation guard makes cross-world staleness impossible.
func _commit_diff(transitions : Array[BiomeTransitionRecord], gen : int, diff_msec : int) -> void:
	if gen != _diff_generation:
		return  # superseded between worker finish and commit
	_last_diff_msec = Time.get_ticks_msec()
	if debug_output and not transitions.is_empty():
		var cycle_ms : int = _last_diff_msec - _last_cycle_msec
		print("[BiomeSnapshotManager] %d transitions (diff %d ms, cycle %d ms) — first: cell %d %d->%d attr 0x%X"
			% [transitions.size(), diff_msec, cycle_ms,
			transitions[0].cell_index, transitions[0].old_biome,
			transitions[0].new_biome, transitions[0].attribution_bits])
	if not transitions.is_empty():
		transitions_resolved.emit(transitions)


## Direct access for systems that need the raw texel view (economy §4.1
## neighbor-attribution lookups). Read-only: the CPU never writes BIOME_TYPE.
func get_shadow_texel(cell_index : int) -> int:
	if cell_index < 0 or cell_index >= _shadow.size():
		return 0
	return _shadow[cell_index]


func get_shadow_biome(cell_index : int) -> int:
	return get_shadow_texel(cell_index) & Helpers.BIOME_TEXEL_ID_MASK


## Full read-only copy of the shadow texels (the initial CCL's input, §3.4).
func get_shadow_snapshot() -> PackedInt32Array:
	return _shadow.duplicate()
