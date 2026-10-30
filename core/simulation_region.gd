extends RefCounted
## Represents a contiguous 4-connected geographic province of identical biome
## type tracked by `RegionGraphManager`.
class_name SimulationRegion

## Permanent unique identifier assigned when the region is created.
var id : int

## Player-facing procedural name (e.g., "The Great Erg of Zephyr"); empty while `is_pending` is true.
var region_name : String

## True until the region reaches `RegionGraphManager.CHRISTEN_THRESHOLD` cells and receives a name.
var is_pending : bool = true

## Catalog biome ID (`0..17`) shared by all member cells in this region.
var biome_type : int

## Set of flat member cell indices (`cell_index -> true`), kept in sync with `RegionGraphManager.cell_to_region`.
var cells : Dictionary = {}

## Running sum of member cell X coordinates for O(1) incremental centroid updates.
var sum_x : int = 0
## Running sum of member cell Y coordinates for O(1) incremental centroid updates.
var sum_y : int = 0

## Simulation year in which this region was first created.
var founding_year : int = 0
## Name of the parent region if this region was formed by a split; empty otherwise.
var parent_region_name : String = ""
## Historical high-water mark of member cell count reached by this region.
var total_cells_peak : int = 0
## Highest surface-area milestone threshold (in km²) already logged for this region.
var last_growth_threshold : int = 0


## Returns the current number of grid cells belonging to this region.
func get_cell_count() -> int:
	return cells.size()


## Returns the region's total surface area in square kilometers given the area of one grid cell.
func get_area_km2(cell_area_km2 : float) -> float:
	return float(cells.size()) * cell_area_km2