extends Node
## Maintains the contiguous 4-connected `SimulationRegion` graph across the biome
## grid, handling bootstrap Connected Component Labeling, incremental cell transitions,
## seniority merges, anchor-reachability splits, procedural naming, and `AeonLog` milestones.
class_name RegionGraphManager

## Emitted when a pending `SimulationRegion` reaches `CHRISTEN_THRESHOLD` cells and receives a name.
signal region_named(region : SimulationRegion)
## Emitted once bootstrap Connected Component Labeling finishes building the initial region graph.
signal graph_rebuilt(region_count : int)

## Minimum cell count required before a pending region is christened and logged in `AeonLog`.
const CHRISTEN_THRESHOLD : int = 5
## Surface-area milestones in square kilometers that trigger one-shot growth entries in `AeonLog`.
const GROWTH_THRESHOLDS_KM2 : Array[float] = [10000.0, 50000.0]

## Active `SimulationRegion` instances keyed by their permanent integer `id`.
var regions : Dictionary = {}
## Contiguous SoA lookup mapping each flat `cell_index` to its owning `SimulationRegion.id` (`-1` if none).
var cell_to_region : PackedInt32Array = PackedInt32Array()
## Equatorial surface area of a single grid cell in square kilometers, derived from `WorldConfig.planetary_diameter`.
var cell_area_km2 : float = 0.0
## Monotonically increasing counter assigning unique IDs to newly created `SimulationRegion` instances.
var next_region_id : int = 1
## Chronicle instance receiving regional birth, growth, merge, split, and extinction milestones.
var aeon_log : AeonLog
## Procedural name generator minting fresh and derived region names.
var name_generator : RegionNameGenerator

## When true during a loaded-world bootstrap, suppresses `log_birth` entries and seeds `last_growth_threshold` to current area.
var suppress_bootstrap_births : bool = false

## True while an asynchronous split-contest worker task is in flight.
var _job_in_flight : bool = false
## FIFO queue of transition batches buffered while `_job_in_flight` is true.
var _mutation_queue : Array[Array] = []
## Monotonically increasing counter guarding against commits from stale worker tasks.
var _split_generation : int = 0
## Set of cell indices whose detachment queued a pending split check.
var _pending_split_checks : Dictionary = {}

## Bound world grid width in cells.
var _width : int = 0
## Bound world grid height in cells.
var _height : int = 0


## Ensures default `AeonLog` and `RegionNameGenerator` instances exist when entering the scene tree.
func _ready() -> void:
	if aeon_log == null:
		aeon_log = AeonLog.new()
	if name_generator == null:
		name_generator = RegionNameGenerator.new()


## Resets the region graph for a `width * height` grid and computes `cell_area_km2` from `WorldConfig.planetary_diameter`.
func bind(width : int, height : int) -> void:
	# Initialize grid dimensions, default helper instances, and the flat `cell_to_region` SoA lookup.
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
	# Compute single-cell equatorial surface area in square kilometers from planetary diameter.
	var diameter : float = 12742.0
	if GameStateManager.world_config:
		diameter = GameStateManager.world_config.planetary_diameter
	var equator_span : float = PI * diameter / float(width)
	cell_area_km2 = equator_span * (equator_span * 0.5)


## Binds the graph to `width * height` and dispatches the one-time Connected Component Labeling worker on `shadow`.
func build_from_shadow(shadow : PackedInt32Array, width : int, height : int) -> void:
	bind(width, height)
	_split_generation += 1
	var gen : int = _split_generation
	WorkerThreadPool.add_task(_ccl_worker.bind(shadow.duplicate(), gen))


## Floods 4-connected same-biome components across `shadow` and commits each discovered region.
func _run_ccl(shadow : PackedInt32Array, gen : int, defer_commits : bool) -> void:
	var id_mask : int = Helpers.BIOME_TEXEL_ID_MASK
	var max_valid : int = Helpers.BIOME_MAX_VALID_ID
	var count : int = shadow.size()
	var labels : PackedInt32Array = PackedInt32Array()
	labels.resize(count)
	labels.fill(-1)
	var stack : PackedInt32Array = PackedInt32Array()
	var next_label : int = 0

	# Scan every cell and launch a 4-connected BFS flood for each unvisited classified cell.
	for start : int in count:
		if labels[start] != -1:
			continue
		var biome : int = shadow[start] & id_mask
		if biome > max_valid:
			labels[start] = -2
			continue
		next_label += 1
		stack.clear()
		stack.append(start)
		labels[start] = next_label
		var members : PackedInt32Array = PackedInt32Array()
		members.append(start)
		# Expand across East/West wrapped and North/South clamped orthogonal neighbors of the same biome.
		while not stack.is_empty():
			var idx : int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			var x : int = idx % _width
			@warning_ignore("integer_division")
			var y : int = idx / _width
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
		# Commit the discovered component either deferred to the main thread or immediately in synchronous tests.
		if defer_commits:
			_commit_region.call_deferred(members, biome, gen)
		else:
			_commit_region(members, biome, gen)


## Worker entry point that runs `_run_ccl` and defers `_ccl_done` to the main thread.
func _ccl_worker(shadow : PackedInt32Array, gen : int) -> void:
	if gen != _split_generation:
		return
	_run_ccl(shadow, gen, true)
	_ccl_done.call_deferred(gen)


## Registers a labeled component's cells into a new `SimulationRegion` and christens it if at least `CHRISTEN_THRESHOLD` cells.
func _commit_region(members : PackedInt32Array, biome : int, gen : int) -> void:
	if gen != _split_generation or members.is_empty():
		return
	# Create the region, populate `cell_to_region` and centroid sums, and christen if large enough.
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


## Emits `graph_rebuilt` on the main thread once all bootstrap CCL regions have been committed.
func _ccl_done(gen : int) -> void:
	if gen != _split_generation:
		return
	graph_rebuilt.emit(regions.size())


## Applies `transitions` immediately or buffers them in `_mutation_queue` if a split worker is currently in flight.
func on_transitions_resolved(transitions : Array) -> void:
	if _job_in_flight:
		_mutation_queue.append(transitions)
		return
	_apply_transitions(transitions)


## Detaches each transitioned cell from its old region, attaches it to its new biome region, and schedules split checks.
func _apply_transitions(transitions : Array) -> void:
	suppress_bootstrap_births = false
	var split_candidates : Dictionary = {}
	for transition : BiomeTransitionRecord in transitions:
		var cell_index : int = transition.cell_index
		var new_biome : int = transition.new_biome
		var old_region_id : int = cell_to_region[cell_index]

		# Detach the cell from its previous region and mark the region extinct or a split candidate.
		if old_region_id != -1 and regions.has(old_region_id):
			var old_region : SimulationRegion = regions[old_region_id]
			_detach_cell(old_region, cell_index)
			if old_region.cells.is_empty():
				_extinct_region(old_region)
			elif not _job_in_flight and _needs_split_check(old_region, cell_index):
				split_candidates[old_region_id] = true

		# Attach the cell to an adjacent matching region or seed a new pending region.
		_attach_cell(cell_index, new_biome)

	# Evaluate split candidates that survived all merges and detachments in this batch.
	for region_id : int in split_candidates:
		if not regions.has(region_id):
			continue
		var region : SimulationRegion = regions[region_id]
		if region.cells.is_empty():
			continue
		_maybe_enqueue_split(region)

	_flush_growth_milestones()


## Removes `cell_index` from `region`, decrements its centroid accumulators, and clears `cell_to_region[cell_index]`.
func _detach_cell(region : SimulationRegion, cell_index : int) -> void:
	region.cells.erase(cell_index)
	region.sum_x -= cell_index % _width
	@warning_ignore("integer_division")
	region.sum_y -= cell_index / _width
	cell_to_region[cell_index] = -1


## Joins `cell_index` to an orthogonal neighbor region of matching `biome` (merging multiple matches by seniority) or seeds a new region.
func _attach_cell(cell_index : int, biome : int) -> void:
	var x : int = cell_index % _width
	@warning_ignore("integer_division")
	var y : int = cell_index / _width
	# Collect distinct orthogonal neighbor region IDs that share `biome`.
	var neighbor_ids : Dictionary = {}
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

	# Seed a new region when no orthogonal neighbor shares `biome`.
	if neighbor_ids.is_empty():
		var region : SimulationRegion = _create_region(biome, GameStateManager.elapsed_years)
		_add_cell_to_region(region, cell_index)
		_maybe_christen(region)
		return

	# Attach the cell to the first matching neighbor region and merge any additional matching neighbors into it.
	var chosen_id : int = neighbor_ids.keys()[0]
	var chosen : SimulationRegion = regions[chosen_id]
	_add_cell_to_region(chosen, cell_index)
	for other_id : int in neighbor_ids:
		if other_id == chosen_id:
			continue
		var other : SimulationRegion = regions[other_id]
		chosen = _merge_regions(chosen, other)
	_maybe_christen(chosen)


## Adds `cell_index` to `region`, updates `cell_to_region` and centroid sums, and updates `total_cells_peak`.
func _add_cell_to_region(region : SimulationRegion, cell_index : int) -> void:
	region.cells[cell_index] = true
	region.sum_x += cell_index % _width
	@warning_ignore("integer_division")
	region.sum_y += cell_index / _width
	cell_to_region[cell_index] = region.id
	if region.cells.size() > region.total_cells_peak:
		region.total_cells_peak = region.cells.size()


## Allocates and registers a new pending `SimulationRegion` with a unique `id`.
func _create_region(biome : int, founding_year : int) -> SimulationRegion:
	var region : SimulationRegion = SimulationRegion.new()
	region.id = next_region_id
	next_region_id += 1
	region.biome_type = biome
	region.founding_year = founding_year
	regions[region.id] = region
	return region


## Logs extinction in `aeon_log` if `region` was christened and removes it from `regions`.
func _extinct_region(region : SimulationRegion) -> void:
	if not region.is_pending:
		aeon_log.log_extinction(region.region_name)
	regions.erase(region.id)


## Absorbs the smaller region into the larger region by cell count, transferring cells and centroid sums additively.
func _merge_regions(senior : SimulationRegion, junior : SimulationRegion) -> SimulationRegion:
	# Swap references if `junior` has more cells so `senior` is always the larger surviving region.
	if junior.cells.size() > senior.cells.size():
		var swap : SimulationRegion = senior
		senior = junior
		junior = swap
	# Transfer all member cells and centroid accumulators from `junior` into `senior`.
	for cell_index : int in junior.cells:
		senior.cells[cell_index] = true
		cell_to_region[cell_index] = senior.id
	senior.sum_x += junior.sum_x
	senior.sum_y += junior.sum_y
	if senior.cells.size() > senior.total_cells_peak:
		senior.total_cells_peak = senior.cells.size()
	# Log absorption if the absorbed region was already christened, then remove it from `regions`.
	if not junior.is_pending:
		aeon_log.log_absorption(junior.region_name, senior.region_name)
	regions.erase(junior.id)
	_maybe_christen(senior)
	return senior


## Returns true if `detached_cell` had at least two orthogonal neighbors belonging to `region`, indicating a potential pinch point.
func _needs_split_check(region : SimulationRegion, detached_cell : int) -> bool:
	if region.cells.size() <= 1:
		return false
	var x : int = detached_cell % _width
	@warning_ignore("integer_division")
	var y : int = detached_cell / _width
	# Count how many of `detached_cell`'s 4 orthogonal neighbors still belong to `region`.
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
	return degree >= 2


## Returns true if any pair of cells in `ring_members` is directly adjacent on the grid.
func _ring_test(_region : SimulationRegion, ring_members : Array[int]) -> bool:
	var member_set : Dictionary = {}
	for idx : int in ring_members:
		member_set[idx] = true
	# Check pairwise adjacency across the ring subset.
	for a : int in ring_members:
		for b : int in ring_members:
			if a >= b:
				continue
			if _are_adjacent(a, b):
				return true
	return false


## Returns true if flat cell indices `a` and `b` are 4-connected neighbors (with East-West wrapping).
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


## Runs a synchronous connectivity check for small regions (`< 64` cells) or dispatches `_split_worker` for larger regions.
func _maybe_enqueue_split(region : SimulationRegion) -> void:
	# Handle small regions synchronously on the main thread to avoid worker task overhead.
	if region.cells.size() < 64:
		if _is_connected(region):
			return
		_sever_synchronous(region)
		return
	# Dispatch an asynchronous anchor-reachability contest for larger regions if no worker is in flight.
	if _job_in_flight:
		return
	var anchor : int = _derive_anchor(region)
	if anchor == -1:
		return
	_job_in_flight = true
	_split_generation += 1
	var gen : int = _split_generation
	var membership : PackedInt32Array = PackedInt32Array(region.cells.keys())
	WorkerThreadPool.add_task(_split_worker.bind(region.id, membership, anchor, gen))


## Returns the member cell index in `region` closest to its `(sum_x / count, sum_y / count)` centroid, or `-1` if empty.
func _derive_anchor(region : SimulationRegion) -> int:
	var count : int = region.cells.size()
	if count == 0:
		return -1
	# Compute the mean coordinate and find the member cell with minimum squared Euclidean distance.
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


## Returns true if all cells in `region` belong to a single 4-connected component.
func _is_connected(region : SimulationRegion) -> bool:
	if region.cells.size() <= 1:
		return true
	# Flood-fill from the first member cell and verify every member cell is reached.
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


## Splits a disconnected small `region` synchronously into connected fragments and registers daughter regions.
func _sever_synchronous(region : SimulationRegion) -> void:
	var fragments : Array = _fragment_region(region)
	_apply_fragments(region, fragments)


## Floods `membership` from `anchor` on a worker thread, collects any unreached disconnected fragments, and defers `_split_commit`.
func _split_worker(region_id : int, membership : PackedInt32Array, anchor : int, gen : int) -> void:
	if gen != _split_generation:
		return
	var member_set : Dictionary = {}
	for idx : int in membership:
		member_set[idx] = true
	if not member_set.has(anchor):
		_split_commit.call_deferred(region_id, [], gen)
		return
	# Flood-fill all member cells reachable from `anchor`.
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
		_split_commit.call_deferred(region_id, fragments, gen)
		return
	# Flood-fill each disconnected component among the unreached member cells.
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


## Returns the 4-connected neighbors of `idx` that are present in `member_set`.
func _neighbors_snapshot(idx : int, member_set : Dictionary) -> Array[int]:
	var result : Array[int] = []
	for nidx : int in _neighbors_of(idx):
		if member_set.has(nidx):
			result.append(nidx)
	return result


## Commits an asynchronous split on the main thread, creating daughter regions for severed fragments and replaying `_mutation_queue`.
func _split_commit(region_id : int, fragments : Array, gen : int) -> void:
	if gen != _split_generation:
		return
	_job_in_flight = false
	if not regions.has(region_id):
		return
	if fragments.is_empty():
		_flush_growth_milestones()
		_replay_mutation_queue()
		return
	var parent : SimulationRegion = regions[region_id]
	# Detach severed fragments from `parent` and create daughter regions for each fragment.
	var anchor : int = _derive_anchor(parent)
	var anchor_fragment_idx : int = -1
	for f : int in fragments.size():
		@warning_ignore("unsafe_method_access")
		if fragments[f].has(anchor):
			anchor_fragment_idx = f
			break
	if anchor_fragment_idx != -1:
		var anchor_frag : PackedInt32Array = fragments[anchor_fragment_idx]
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
	# Mark `parent` extinct if empty, or log the severing milestone and replay queued transition batches.
	if parent.cells.is_empty():
		_extinct_region(parent)
	else:
		if not parent.is_pending and not daughters.is_empty():
			aeon_log.log_severing(parent.region_name, daughters)
		_maybe_christen(parent)
	_flush_growth_milestones()
	_replay_mutation_queue()


## Partitions all cells of `region` into 4-connected `PackedInt32Array` components and clears `region` from the graph.
func _fragment_region(region : SimulationRegion) -> Array:
	# Flood-fill every connected component among `region.cells`.
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
	# Remove the original region registration before the caller rebuilds fragments.
	regions.erase(region.id)
	for idx : int in region.cells:
		cell_to_region[idx] = -1
	return fragments


## Rebuilds the first fragment in `fragments` with `parent`'s identity and creates daughter regions for remaining fragments.
func _apply_fragments(parent : SimulationRegion, fragments : Array) -> void:
	var daughters : PackedStringArray = PackedStringArray()
	var parent_name : String = parent.region_name
	for f : int in fragments.size():
		var fragment : PackedInt32Array = fragments[f]
		if fragment.is_empty():
			continue
		# Preserve `parent`'s name and metadata on the primary fragment.
		if f == 0:
			var rebuilt : SimulationRegion = _create_region(parent.biome_type, parent.founding_year)
			rebuilt.region_name = parent_name
			rebuilt.is_pending = parent.is_pending
			rebuilt.parent_region_name = parent.parent_region_name
			rebuilt.total_cells_peak = parent.total_cells_peak
			for idx : int in fragment:
				_add_cell_to_region(rebuilt, idx)
			continue
		# Register subsequent fragments as daughter regions and christen those meeting `CHRISTEN_THRESHOLD`.
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


## Returns the 4 orthogonal neighbor cell indices of `idx` with East-West wrapping and North-South pole clamping.
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


## Christens `region` with a fresh procedural name if it has reached `CHRISTEN_THRESHOLD` cells.
func _maybe_christen(region : SimulationRegion) -> void:
	if region.cells.size() >= CHRISTEN_THRESHOLD:
		_christen(region, "")


## Assigns a fresh or derived procedural name to a pending `region`, logs its birth in `aeon_log`, and emits `region_named`.
func _christen(region : SimulationRegion, parent_name : String, siblings : PackedStringArray = PackedStringArray()) -> void:
	if not region.is_pending:
		return
	# Mint a fresh name for seed regions or a relational daughter name for split fragments.
	if parent_name.is_empty():
		region.region_name = name_generator.mint_fresh(region.biome_type, region.id * 2654435761 % 2147483647)
	else:
		region.region_name = name_generator.mint_derived(parent_name, region.biome_type, siblings, region.id * 40503)
	region.parent_region_name = parent_name
	region.is_pending = false
	# Suppress birth logging during loaded-world bootstrap and seed `last_growth_threshold` to current area.
	if suppress_bootstrap_births:
		region.last_growth_threshold = 0
		var area : float = region.get_area_km2(cell_area_km2)
		for threshold : float in GROWTH_THRESHOLDS_KM2:
			if area >= threshold:
				region.last_growth_threshold = int(threshold)
	else:
		aeon_log.log_birth(region.region_name, region.biome_type, region.cells.size())
		region.last_growth_threshold = 0
	region_named.emit(region)


## Checks all christened regions against `GROWTH_THRESHOLDS_KM2` and logs newly crossed area milestones in `aeon_log`.
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


## Replays buffered transition batches from `_mutation_queue` in FIFO order until empty or a new split job is enqueued.
func _replay_mutation_queue() -> void:
	if _mutation_queue.is_empty() or _job_in_flight:
		return
	var queued : Array[Array] = _mutation_queue
	_mutation_queue = []
	for batch : Array in queued:
		if _job_in_flight:
			_mutation_queue.append_array(queued)
			return
		_apply_transitions(batch)


## Returns the `SimulationRegion` owning `cell_index`, or `null` if out of bounds or unassigned.
func get_region_at(cell_index : int) -> SimulationRegion:
	var rid : int = cell_to_region[cell_index] if cell_index >= 0 and cell_index < cell_to_region.size() else -1
	return regions.get(rid, null)


## Returns the total number of active `SimulationRegion` instances currently tracked in `regions`.
func get_region_count() -> int:
	return regions.size()
