extends RefCounted
class_name SimulationRegion

## A contiguous geographic province of identical biome type
## (_planning/event_logging_system_plan.md §3.2).

## Permanent unique identifier. Never changes once assigned.
var id : int

## Player-facing name ("The Great Erg of Zephyr"); empty while pending (§5.1).
var region_name : String

## True until the region crosses the christening threshold; pending regions are
## structural members of the graph but carry no name and log no milestones.
var is_pending : bool = true

## Biome ID (0..17 matching the Master Biome Catalog).
var biome_type : int

## Member cell indices (i = y * width + x). Kept in sync with the flat
## cell_to_region lookup owned by RegionGraphManager. Emptied on merge/archive.
var cells : Dictionary = {}

## Incremental centroid accumulators (O(1) maintenance on attach/detach;
## additive on merges §3.3.2). The anchor is derived LAZILY from these when a
## split contest needs it (§3.3.3): the member cell nearest
## (sum_x / count, sum_y / count). Never persisted, never invalidated.
var sum_x : int = 0
var sum_y : int = 0

## Historical metadata.
var founding_year : int = 0
var parent_region_name : String = ""   # set if formed via severing/splitting
var total_cells_peak : int = 0
var last_growth_threshold : int = 0    # highest §5.1 area threshold crossed

func get_cell_count() -> int:
	return cells.size()

## Area in km2. `cell_area_km2` is derived from WorldConfig once at manager
## startup — never hardcoded (plan §3.2). This is the equatorial value;
## per-row cos(latitude) weighting is a possible later refinement.
func get_area_km2(cell_area_km2 : float) -> float:
	return float(cells.size()) * cell_area_km2