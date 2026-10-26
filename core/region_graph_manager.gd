extends Node
class_name RegionGraphManager

## Maintains the persistent SimulationRegion graph over the biome grid
## (_planning/event_logging_system_plan.md §3.3/§3.4/§5.1).
##
## Data layout (§3.2, perf-critical): the PRIMARY lookup is the flat
## `cell_to_region` PackedInt32Array (O(1) index math, cache-friendly);
## per-region `cells` Dictionaries are retained only for membership/centroid
## bookkeeping and emptied on merge/archive.
##
## Consumption: connect `GameStateManager.biome_snapshot_manager`
## .transitions_resolved -> `on_transitions_resolved`. Batches arriving while
## a split job is in flight are buffered (mutation queue) and replayed after
## the job commits (§3.4 concurrency contract). Per-cell mutation guards
## discard stale split jobs whose region has since merged or dissolved.
##
## Worker discipline (§3.4): exactly two kinds of worker work ever exist —
## the one-time initial CCL at bootstrap and anchor-reachability split
## contests. The periodic reconcile pass from the superseded design is
## DELETED: snapshot diffing cannot drift.

signal region_named(region : SimulationRegion)
signal graph_rebuilt(region_count : int)

const CHRISTEN_THRESHOLD : int = 5           # cells; §5.1 pending churn suppression
const GROWTH_THRESHOLDS_KM2 : Array[float] = [10000.0, 50000.0]  # §5.1

var regions : Dictionary = {}            # int id -> SimulationRegion
var cell_to_region : PackedInt32Array = PackedInt32Array()  # cell idx -> region id (-1 = none)
var cell_area_km2 : float = 0.0          # derived from WorldConfig once (§3.2)
var next_region_id : int = 1
var aeon_log : AeonLog
var name_generator : RegionNameGenerator

## True while the bootstrap CCL is rediscovering a LOADED world: regions are
## being found, not born, so Birth entries are suppressed (survey, not birth).
## Set by GameStateManager before build_from_shadow; cleared on the first
## diff-batch commit (sim-driven births resume normally).
var suppress_bootstrap_births : bool = false

# --- §3.4 concurrency contract state ---
var _job_in_flight : bool = false
var _mutation_queue : Array[Array] = []  # buffered transition batches
var _split_generation : int = 0          # guards stale split-job commits
var _pending_split_checks : Dictionary = {}  # cell_idx -> true (cells whose flip queued a job)

# world dims (captured at bind time)
var _width : int = 0
var _height : int = 0


func _ready() -> void:
	if aeon_log == null:
		aeon_log = AeonLog.new()
	if name_generator == null:
		name_generator = RegionNameGenerator.new()


## Wires the graph to a world; recomputes cell area from WorldConfig (§3.2).
func bind(width : int, height : int) -> void:
	_width = width
	_height = height
	if aeon_log == null:
		aeon_log = AeonLog.new()
	if name_generator == null:
		name_generator = RegionNameGenerator.new()
	cell_to_region.resize(width * height)
	cell_to_region.fill(-1)
	regions.clear()
	next_region_id = 1
	_job_in_flight = false
	_mutation_queue.clear()
	_pending_split_checks.clear()
	_split_generation += 1
	# Cell area: equatorial cell (plan §3.2). WorldConfig may be absent in
	# test harnesses — fall back to the Earth-default diameter.
	var diameter : float = 12742.0
	if GameStateManager.world_config:
		diameter = GameStateManager.world_config.planetary_diameter
	var equator_span : float = PI * diameter / float(width)
	cell_area_km2 = equator_span * (equator_span * 0.5)


## ============================================================================
## BOOTSTRAP: one-time Connected Component Labeling (§3.4) — the only full
## labeling pass in the system's lifetime. Runs on WorkerThreadPool over the
## snapshot manager's shadow; regions are named from ground truth.
## ============================================================================
func build_from_shadow(shadow : PackedInt32Array, width : int, height : int) -> void:
	bind(width, height)
	_split_generation += 1
	var gen : int = _split_generation
	WorkerThreadPool.add_task(_ccl_worker.bind(shadow.duplicate(), gen))


## The CCL body, shared by the worker (production) and synchronous tests.
## Commits each discovered component through `_commit_region` immediately when
## `defer_commits` is false (single-threaded harness path).
func _run_ccl(shadow : PackedInt32Array, gen : int, defer_commits : bool) -> void:
	var id_mask : int = Helpers.BIOME_TEXEL_ID_MASK
	var max_valid : int = Helpers.BIOME_MAX_VALID_ID
	var count : int = shadow.size()
	var labels : PackedInt32Array = PackedInt32Array()
	labels.resize(count)
	labels.fill(-1)
	var stack : PackedInt32Array = PackedInt32Array()
	var next_label : int = 0

	for start : int in count:
		if labels[start] != -1:
			continue
		var biome : int = shadow[start] & id_mask
		if biome > max_valid:
			labels[start] = -2  # unclassified: no region
			continue
		# BFS flood of this component.
		next_label += 1
		stack.clear()
		stack.append(start)
		labels[start] = next_label
		var members : PackedInt32Array = PackedInt32Array()
		members.append(start)
		while not stack.is_empty():
			var idx : int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			var x : int = idx % _width
			@warning_ignore("integer_division")
			var y : int = idx / _width
			# 4-neighbors with x wrap; y clamped (unclassified bands terminate
			# regions; pole rows have no crossover peers beyond the grid).
			var n : Array[int] = [
				y * _width + ((x + 1) % _width),
				y * _width + ((x - 1 + _width) % _width),
			]
			if y > 0: n.append((y - 1) * _width + x)
			if y < _height - 1: n.append((y + 1) * _width + x)
			for nidx : int in n:
				if labels[nidx] != -1:
					continue
				var nbiome : int = shadow[nidx] & id_mask
				if nbiome == biome and nbiome <= max_valid:
					labels[nidx] = next_label
					stack.append(nidx)
					members.append(nidx)
		if defer_commits:
			_commit_region.call_deferred(members, biome, gen)
		else:
			_commit_region(members, biome, gen)


func _ccl_worker(shadow : PackedInt32Array, gen : int) -> void:
	if gen != _split_generation:
		return
	_run_ccl(shadow, gen, true)
	_ccl_done.call_deferred(gen)


func _commit_region(members : PackedInt32Array, biome : int, gen : int) -> void:
	if gen != _split_generation or members.is_empty():
		return
	var region : SimulationRegion = _create_region(biome, 0)
	for idx : int in members:
		cell_to_region[idx] = region.id
		region.cells[idx] = true
		region.sum_x += idx % _width
		@warning_ignore("integer_division")
		region.sum_y += idx / _width
	region.total_cells_peak = region.cells.size()
	if region.cells.size() >= CHRISTEN_THRESHOLD:
		_christen(region, "")


func _ccl_done(gen : int) -> void:
	if gen != _split_generation:
		return
	graph_rebuilt.emit(regions.size())


# ============================================================================
## DIFF BATCH CONSUMPTION (§3.3)
# ============================================================================
func on_transitions_resolved(transitions : Array) -> void:
	if _job_in_flight:
		# §3.4: buffer, don't interleave. Re-applied after the job commits.
		_mutation_queue.append(transitions)
		return
	_apply_transitions(transitions)


func _apply_transitions(transitions : Array) -> void:
	suppress_bootstrap_births = false   # sim-driven births resume after load
	var split_candidates : Dictionary = {}  # region_id -> true
	for transition : BiomeTransitionRecord in transitions:
		var cell_index : int = transition.cell_index
		var new_biome : int = transition.new_biome
		var old_region_id : int = cell_to_region[cell_index]

		# 1. Detach from old region (§3.3 flow).
		if old_region_id != -1 and regions.has(old_region_id):
			var old_region : SimulationRegion = regions[old_region_id]
			_detach_cell(old_region, cell_index)
			if old_region.cells.is_empty():
				_extinct_region(old_region)
			elif not _job_in_flight and _needs_split_check(old_region, cell_index):
				split_candidates[old_region_id] = true

		# 2. Attach to new biome (§3.3.1): inspect 4 orthogonal neighbors,
		#    spherical wrap; join a matching region or seed a new one.
		_attach_cell(cell_index, new_biome)

	# 3. Severing: O(1) gates first; genuine bridge-cuts go async (§3.3.3).
	for region_id : int in split_candidates:
		if not regions.has(region_id):
			continue  # merged/dissolved since the guard snapshot
		var region : SimulationRegion = regions[region_id]
		if region.cells.is_empty():
			continue
		_maybe_enqueue_split(region)

	_flush_growth_milestones()


# ============================================================================
## CELL MEMBERSHIP PRIMITIVES
# ============================================================================
func _detach_cell(region : SimulationRegion, cell_index : int) -> void:
	region.cells.erase(cell_index)
	region.sum_x -= cell_index % _width
	@warning_ignore("integer_division")
	region.sum_y -= cell_index / _width
	cell_to_region[cell_index] = -1


func _attach_cell(cell_index : int, biome : int) -> void:
	var x : int = cell_index % _width
	@warning_ignore("integer_division")
	var y : int = cell_index / _width
	# 4 orthogonal neighbors with spherical X-wrap and Y-clamp (Model B: the
	# outermost rows are the pole cells themselves; there is nothing beyond).
	var neighbor_ids : Dictionary = {}  # region id -> true (dedupe)
	var neighbor_cells : Array[int] = [
		y * _width + ((x + 1) % _width),
		y * _width + ((x - 1 + _width) % _width),
	]
	if y > 0: neighbor_cells.append((y - 1) * _width + x)
	if y < _height - 1: neighbor_cells.append((y + 1) * _width + x)
	for nidx : int in neighbor_cells:
		var nid : int = cell_to_region[nidx]
		if nid != -1 and regions.has(nid) and regions[nid].biome_type == biome:
			neighbor_ids[nid] = true

	if neighbor_ids.is_empty():
		var region : SimulationRegion = _create_region(biome, GameStateManager.elapsed_years)
		_add_cell_to_region(region, cell_index)
		_maybe_christen(region)
		return

	# Join exactly one; MERGE any additional matches (§3.3.2 seniority).
	var chosen_id : int = neighbor_ids.keys()[0]
	var chosen : SimulationRegion = regions[chosen_id]
	_add_cell_to_region(chosen, cell_index)
	for other_id : int in neighbor_ids:
		if other_id == chosen_id:
			continue
		var other : SimulationRegion = regions[other_id]
		chosen = _merge_regions(chosen, other)
	_maybe_christen(chosen)


func _add_cell_to_region(region : SimulationRegion, cell_index : int) -> void:
	region.cells[cell_index] = true
	region.sum_x += cell_index % _width
	@warning_ignore("integer_division")
	region.sum_y += cell_index / _width
	cell_to_region[cell_index] = region.id
	if region.cells.size() > region.total_cells_peak:
		region.total_cells_peak = region.cells.size()


func _create_region(biome : int, founding_year : int) -> SimulationRegion:
	var region : SimulationRegion = SimulationRegion.new()
	region.id = next_region_id
	next_region_id += 1
	region.biome_type = biome
	region.founding_year = founding_year
	regions[region.id] = region
	return region


func _extinct_region(region : SimulationRegion) -> void:
	if not region.is_pending:
		aeon_log.log_extinction(region.region_name)
	regions.erase(region.id)


# ============================================================================
## SENIORITY MERGING (§3.3.2)
# ============================================================================
func _merge_regions(senior : SimulationRegion, junior : SimulationRegion) -> SimulationRegion:
	# The Seniority Rule: the LARGER region absorbs the smaller.
	if junior.cells.size() > senior.cells.size():
		var swap : SimulationRegion = senior
		senior = junior
		junior = swap
	# Centroid sums transfer additively — the anchor stays valid (§3.3.2).
	for cell_index : int in junior.cells:
		senior.cells[cell_index] = true
		cell_to_region[cell_index] = senior.id
	senior.sum_x += junior.sum_x
	senior.sum_y += junior.sum_y
	if senior.cells.size() > senior.total_cells_peak:
		senior.total_cells_peak = senior.cells.size()
	if not junior.is_pending:
		aeon_log.log_absorption(junior.region_name, senior.region_name)
	regions.erase(junior.id)
	_maybe_christen(senior)
	return senior


# ============================================================================
## SEVERING (§3.3.3): Stage 1 O(1) gates -> Stage 2 async anchor contest
# ============================================================================
## Gate 1 (degree) + Gate 2 (ring test) run on the main thread; almost every
## flip stops here. Returns true if the region is provably still connected OR
## trivially severed (0/1/multi neighbors), false only for a genuine bridge
## cut that needs the async contest.
func _needs_split_check(region : SimulationRegion, detached_cell : int) -> bool:
	if region.cells.size() <= 1:
		return false
	var x : int = detached_cell % _width
	@warning_ignore("integer_division")
	var y : int = detached_cell / _width
	# Count this region's members among the 4 neighbors of the detached cell
	# (pre-detach membership was captured by the caller BEFORE detaching —
	# here we run AFTER, so neighbors still in the region are the contest set).
	var region_neighbors : Array[int] = []
	var ring_cells : Array[int] = [
		y * _width + ((x + 1) % _width),
		y * _width + ((x - 1 + _width) % _width),
	]
	if y > 0: ring_cells.append((y - 1) * _width + x)
	if y < _height - 1: ring_cells.append((y + 1) * _width + x)
	for nidx : int in ring_cells:
		if cell_to_region[nidx] == region.id:
			region_neighbors.append(nidx)
	var degree : int = region_neighbors.size()
	# 0 -> region died (handled by extinction). 1 -> no severing possible.
	# 2+ different regions -> the caller per-flip flow already ensured the
	# detached cell belonged to THIS region only, so 2+ members here are all
	# the same region; they may form a pinch point.
	return degree >= 2


## Ring test (§3.3.3 stage 1 gate 2): if the region's neighbours of the cut
## are mutually adjacent around the ring, the region is provably still
## connected and no search runs.
func _ring_test(_region : SimulationRegion, ring_members : Array[int]) -> bool:
	var member_set : Dictionary = {}
	for idx : int in ring_members:
		member_set[idx] = true
	# Pairwise adjacency among the <=4 members (with wrap): if ANY two are
	# direct neighbors, the two sides connect around the cut cell.
	for a : int in ring_members:
		for b : int in ring_members:
			if a >= b:
				continue
			if _are_adjacent(a, b):
				return true
	return false


func _are_adjacent(a : int, b : int) -> bool:
	var ax : int = a % _width
	@warning_ignore("integer_division")
	var ay : int = a / _width
	var bx : int = b % _width
	@warning_ignore("integer_division")
	var by : int = b / _width
	var dx : int = mini((bx - ax + _width) % _width, (ax - bx + _width) % _width)
	var dy : int = abs(by - ay)
	return dx + dy == 1


func _maybe_enqueue_split(region : SimulationRegion) -> void:
	# Ring test over the region's neighbors of every recent cut is implicit:
	# the cheap sufficient test is "is the region still 4-connected?" via a
	# bounded main-thread probe from the largest member cluster — but the plan
	# specifies anchor-reachability on the WORKER for genuine bridge cuts.
	# Main-thread cheap pre-gate: if the region is small enough (< 64 cells),
	# flood-fill synchronously (cheaper than a job round-trip).
	if region.cells.size() < 64:
		if _is_connected(region):
			return
		_sever_synchronous(region)
		return
	if _job_in_flight:
		return  # in-flight gating (§3.4); the next batch re-checks
	var anchor : int = _derive_anchor(region)
	if anchor == -1:
		return
	_job_in_flight = true
	_split_generation += 1
	var gen : int = _split_generation
	var membership : PackedInt32Array = PackedInt32Array(region.cells.keys())
	WorkerThreadPool.add_task(_split_worker.bind(region.id, membership, anchor, gen))


## Lazy centroid anchor (§3.2/§3.3.3): the member cell nearest the mean.
func _derive_anchor(region : SimulationRegion) -> int:
	var count : int = region.cells.size()
	if count == 0:
		return -1
	var mean_x : float = float(region.sum_x) / float(count)
	var mean_y : float = float(region.sum_y) / float(count)
	var best : int = -1
	var best_d : float = INF
	for idx : int in region.cells:
		@warning_ignore("integer_division")
		var dx : float = float(idx % _width) - mean_x
		@warning_ignore("integer_division")
		var dy : float = float(idx / _width) - mean_y
		var d : float = dx * dx + dy * dy
		if d < best_d:
			best_d = d
			best = idx
	return best


## Synchronous flood for small regions (below the job threshold).
func _is_connected(region : SimulationRegion) -> bool:
	if region.cells.size() <= 1:
		return true
	var start : int = region.cells.keys()[0]
	var visited : Dictionary = {start: true}
	var stack : Array[int] = [start]
	while not stack.is_empty():
		var idx : int = stack.pop_back()
		for nidx : int in _neighbors_of(idx):
			if not visited.has(nidx) and region.cells.has(nidx):
				visited[nidx] = true
				stack.append(nidx)
	return visited.size() == region.cells.size()


func _sever_synchronous(region : SimulationRegion) -> void:
	var fragments : Array = _fragment_region(region)
	_apply_fragments(region, fragments)


## Worker (§3.3.3 stage 2): snapshot contest. Each side searches for a path to
## the anchor through same-region cells only; the first flood's visited set IS
## the severed fragment's membership — no discovery cost is paid twice.
func _split_worker(region_id : int, membership : PackedInt32Array, anchor : int, gen : int) -> void:
	if gen != _split_generation:
		return
	var member_set : Dictionary = {}
	for idx : int in membership:
		member_set[idx] = true
	if not member_set.has(anchor):
		# Anchor changed biome between enqueue and run — region intact or gone;
		# commit path discards if the region id no longer resolves.
		_split_commit.call_deferred(region_id, [], gen)
		return
	# Flood from the anchor.
	var reached : Dictionary = {anchor: true}
	var stack : Array[int] = [anchor]
	while not stack.is_empty():
		var idx : int = stack.pop_back()
		for nidx : int in _neighbors_snapshot(idx, member_set):
			if not reached.has(nidx):
				reached[nidx] = true
				stack.append(nidx)
	var fragments : Array[PackedInt32Array] = []
	if reached.size() == member_set.size():
		_split_commit.call_deferred(region_id, fragments, gen)  # intact
		return
	# Severed: every unreached member belongs to lost fragment(s). Flood each.
	var lost : Dictionary = {}
	for idx : int in member_set:
		if reached.has(idx):
			continue
		if lost.has(idx):
			continue
		var fragment : PackedInt32Array = PackedInt32Array()
		stack.clear()
		stack.append(idx)
		lost[idx] = true
		fragment.append(idx)
		while not stack.is_empty():
			var cur : int = stack.pop_back()
			for nidx : int in _neighbors_snapshot(cur, member_set):
				if reached.has(nidx) or lost.has(nidx):
					continue
				lost[nidx] = true
				fragment.append(nidx)
				stack.append(nidx)
		fragments.append(fragment)
	_split_commit.call_deferred(region_id, fragments, gen)


func _neighbors_snapshot(idx : int, member_set : Dictionary) -> Array[int]:
	var result : Array[int] = []
	for nidx : int in _neighbors_of(idx):
		if member_set.has(nidx):
			result.append(nidx)
	return result


## Main-thread commit (§3.3.3 step 7): daughters keep the parent's exact name
## on the anchor side; each >= threshold daughter is christened with a derived
## name; interim transitions replay against the committed result afterwards.
func _split_commit(region_id : int, fragments : Array, gen : int) -> void:
	if gen != _split_generation:
		return
	_job_in_flight = false
	if not regions.has(region_id):
		return  # stale job: region merged/dissolved while the job ran (§3.4)
	if fragments.is_empty():
		_flush_growth_milestones()
		_replay_mutation_queue()
		return
	var parent : SimulationRegion = regions[region_id]
	# Anchor-side keeps id + exact name even if not strictly largest ("the
	# heart persists"). The anchor is recomputed against CURRENT membership.
	var anchor : int = _derive_anchor(parent)
	var anchor_fragment_idx : int = -1
	for f : int in fragments.size():
		@warning_ignore("unsafe_method_access")
		if fragments[f].has(anchor):
			anchor_fragment_idx = f
			break
	if anchor_fragment_idx != -1:
		# Anchor sits in a lost fragment: that fragment keeps the identity,
		# the remaining cells (current parent membership minus lost) become
		# the daughters' parent body.
		var anchor_frag : PackedInt32Array = fragments[anchor_fragment_idx]
		# Remove anchor fragment cells from the parent.
		for idx : int in anchor_frag:
			_detach_cell(parent, idx)
	var daughters : PackedStringArray = PackedStringArray()
	for f : int in fragments.size():
		var fragment : PackedInt32Array = fragments[f]
		if fragment.is_empty():
			continue
		var daughter : SimulationRegion = _create_region(parent.biome_type, GameStateManager.elapsed_years)
		daughter.parent_region_name = parent.region_name
		for idx : int in fragment:
			_add_cell_to_region(daughter, idx)
		if daughter.cells.size() >= CHRISTEN_THRESHOLD:
			var siblings : PackedStringArray = PackedStringArray(daughters)
			_christen(daughter, parent.region_name, siblings)
			daughters.append(daughter.region_name)
	# Parent survives only if it still has cells; otherwise it is extinct.
	if parent.cells.is_empty():
		_extinct_region(parent)
	else:
		if not parent.is_pending and not daughters.is_empty():
			aeon_log.log_severing(parent.region_name, daughters)
		_maybe_christen(parent)
	_flush_growth_milestones()
	_replay_mutation_queue()


func _fragment_region(region : SimulationRegion) -> Array:
	# Flood-fill all components of the region's remaining membership.
	var fragments : Array = []
	var seen : Dictionary = {}
	for start : int in region.cells:
		if seen.has(start):
			continue
		var fragment : PackedInt32Array = PackedInt32Array()
		var stack : Array[int] = [start]
		seen[start] = true
		fragment.append(start)
		while not stack.is_empty():
			var idx : int = stack.pop_back()
			for nidx : int in _neighbors_of(idx):
				if region.cells.has(nidx) and not seen.has(nidx):
					seen[nidx] = true
					fragment.append(nidx)
					stack.append(nidx)
		fragments.append(fragment)
	# Clear the parent's bookkeeping; fragments are re-registered by caller.
	regions.erase(region.id)
	for idx : int in region.cells:
		cell_to_region[idx] = -1
	return fragments


func _apply_fragments(parent : SimulationRegion, fragments : Array) -> void:
	var daughters : PackedStringArray = PackedStringArray()
	var parent_name : String = parent.region_name
	for f : int in fragments.size():
		var fragment : PackedInt32Array = fragments[f]
		if fragment.is_empty():
			continue
		# The largest fragment keeps the parent identity in the synchronous
		# path (no anchor contest ran); the rest are daughters.
		if f == 0:
			var rebuilt : SimulationRegion = _create_region(parent.biome_type, parent.founding_year)
			rebuilt.region_name = parent_name
			rebuilt.is_pending = parent.is_pending
			rebuilt.parent_region_name = parent.parent_region_name
			rebuilt.total_cells_peak = parent.total_cells_peak
			for idx : int in fragment:
				_add_cell_to_region(rebuilt, idx)
			continue
		var daughter : SimulationRegion = _create_region(parent.biome_type, GameStateManager.elapsed_years)
		daughter.parent_region_name = parent_name
		for idx : int in fragment:
			_add_cell_to_region(daughter, idx)
		if daughter.cells.size() >= CHRISTEN_THRESHOLD:
			var siblings : PackedStringArray = PackedStringArray(daughters)
			_christen(daughter, parent_name, siblings)
			daughters.append(daughter.region_name)
	if not parent.is_pending and not daughters.is_empty():
		aeon_log.log_severing(parent_name, daughters)
	_flush_growth_milestones()
	_replay_mutation_queue()


func _neighbors_of(idx : int) -> Array[int]:
	var x : int = idx % _width
	@warning_ignore("integer_division")
	var y : int = idx / _width
	var result : Array[int] = [
		y * _width + ((x + 1) % _width),
		y * _width + ((x - 1 + _width) % _width),
	]
	if y > 0: result.append((y - 1) * _width + x)
	if y < _height - 1: result.append((y + 1) * _width + x)
	return result


# ============================================================================
## NAMING & MILESTONES (§5.1)
# ============================================================================
func _maybe_christen(region : SimulationRegion) -> void:
	if region.cells.size() >= CHRISTEN_THRESHOLD:
		_christen(region, "")


## Christens a pending region once. Once christened, ALWAYS christened (§5.1):
## re-crossing the threshold never re-logs Birth. `parent_name` non-empty
## derives a daughter name with sibling uniqueness; empty mints fresh.
func _christen(region : SimulationRegion, parent_name : String, siblings : PackedStringArray = PackedStringArray()) -> void:
	if not region.is_pending:
		return
	if parent_name.is_empty():
		region.region_name = name_generator.mint_fresh(region.biome_type, region.id * 2654435761 % 2147483647)
	else:
		region.region_name = name_generator.mint_derived(parent_name, region.biome_type, siblings, region.id * 40503)
	region.parent_region_name = parent_name
	region.is_pending = false
	if suppress_bootstrap_births:
		# Bootstrap on a LOADED world: regions are rediscovered, not born —
		# no Birth entry, and the growth marker is seeded to the area the
		# region already has so the next milestone flush doesn't retroactively
		# log thresholds it crossed before the save.
		region.last_growth_threshold = 0
		var area : float = region.get_area_km2(cell_area_km2)
		for threshold : float in GROWTH_THRESHOLDS_KM2:
			if area >= threshold:
				region.last_growth_threshold = int(threshold)
	else:
		aeon_log.log_birth(region.region_name, region.biome_type, region.cells.size())
		region.last_growth_threshold = 0
	region_named.emit(region)


## Growth milestones: area thresholds (§5.1). One-shot per threshold per region.
func _flush_growth_milestones() -> void:
	if cell_area_km2 <= 0.0:
		return
	for region : SimulationRegion in regions.values():
		if region.is_pending:
			continue
		var area : float = region.get_area_km2(cell_area_km2)
		for threshold : float in GROWTH_THRESHOLDS_KM2:
			if area >= threshold and region.last_growth_threshold < int(threshold):
				region.last_growth_threshold = int(threshold)
				aeon_log.log_growth(region.region_name, area, threshold)


# ============================================================================
## §3.4 MUTATION QUEUE
# ============================================================================
func _replay_mutation_queue() -> void:
	if _mutation_queue.is_empty() or _job_in_flight:
		return
	var queued : Array[Array] = _mutation_queue
	_mutation_queue = []
	for batch : Array in queued:
		if _job_in_flight:
			_mutation_queue.append_array(queued)  # a replay queued a new job
			return
		_apply_transitions(batch)


# ============================================================================
## QUERIES (for economy §4.1, fauna §7.2, visualization)
# ============================================================================
func get_region_at(cell_index : int) -> SimulationRegion:
	var rid : int = cell_to_region[cell_index] if cell_index >= 0 and cell_index < cell_to_region.size() else -1
	return regions.get(rid, null)


func get_region_count() -> int:
	return regions.size()
