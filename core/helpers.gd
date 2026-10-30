extends RefCounted
## Authoritative registry of simulation domain enums, VRAM sub-layer names,
## `std430` SSBO byte layouts, auxiliary uniform bindings, and biome catalog IDs.
class_name Helpers

## Simulation domain categories indexing the fine float, atomic, and SSBO layer maps.
enum sim_layers {
	LANDSCAPE = 0,
	WATER = 1,
	ENERGY = 2,
	ATMOSPHERE = 3,
	FLORA = 4,
	FAUNA = 5,
	CIVILISATION = 6,
	PLAYER_ACTIONS = 7,
	SMOKETEST = 8,
	INVALID = -1
}

## High-level execution pipeline categories grouping compute passes in `WorldConfig`.
enum system_names {
	TOPOGRAPHY_GENERATION = 0,
	THERMODYNAMICS = 1,
	FLUID_DYNAMICS = 2,
	ECOLOGY_BASELINE = 3,
	FAUNA_BEHAVIOR = 4,
	CIVILIZATION_BEHAVIOR = 5,
	PLAYER_ACTIONS = 6
}

## Layer indices for the 64×64×9 `r32f` coarse atmospheric dynamics texture array.
enum coarse_layers {
	H_UPPER = 0,         # Upper layer column height (stratosphere)
	WIND_UPPER_X = 1,    # Upper layer eastward velocity (jet stream)
	WIND_UPPER_Y = 2,    # Upper layer southward velocity
	H_LOWER = 3,         # Lower layer column height (troposphere)
	WIND_LOWER_X = 4,    # Lower layer eastward velocity (surface wind)
	WIND_LOWER_Y = 5,    # Lower layer southward velocity
	AIR_TEMP = 6,        # Downsampled fine air_temp (thermal forcing on lower layer)
	TERRAIN = 7,         # Downsampled area-weighted mean terrain (Audusse well-balanced SWE)
	ROUGHNESS = 8,       # Sub-grid terrain variance / roughness (orographic boundary drag)
	COUNT
}

## Ordered sub-layer names per `sim_layers` domain in the 512×512 `r16f` Fine Float Grid (Bindings 0/1).
## Physical units: heights/depths (`BEDROCK_HEIGHT`, `SEDIMENT_HEIGHT`, `WATER_LIQUID_HEIGHT`, `WATER_ICE_HEIGHT`)
## are in Hectometers (`1.0 = 100 m`); temperatures are in `°C`; `SUNLIGHT`, `HUMIDITY`, `RAIN`, `SNOW`,
## `GROWTH_RATE_MODIFIER`, and `CANOPY_SHADE` are normalized ratios; `PRESSURE` is SWE column height `h`.
const float_sub_layer_names : Dictionary [sim_layers, PackedStringArray] = {
	sim_layers.LANDSCAPE: [
		"BEDROCK_HEIGHT", 
		"SLOPE.X", 
		"SLOPE.Y", 
		"SEDIMENT_HEIGHT", 
		"GROUND_TEMP"
		],
	sim_layers.WATER: [
		"WATER_LIQUID_HEIGHT", 
		"WATER_ICE_HEIGHT", 
		"NET_VELOCITY.X", 
		"NET_VELOCITY.Y", 
		"DIVERGENCE", 
		"TURBULENCE", 
		"WATER_TEMP"
		],
	sim_layers.ENERGY: [
		"SUNLIGHT",
		"TIDAL_FORCE"
		], 
	sim_layers.ATMOSPHERE: [
		"WIND.X", 
		"WIND.Y", 
		"AIR_TEMP", 
		"HUMIDITY", 
		"RAIN",
		"SNOW", 
		"PRESSURE"
		],
	sim_layers.FLORA: [
		"GROWTH_RATE_MODIFIER", 
		"CANOPY_SHADE"
		],
	sim_layers.FAUNA: [		
		"SCENT_HUNT_INSECT", 
		"SCENT_HUNT_SMALL", 
		"SCENT_HUNT_MED", 
		"SCENT_HUNT_LARGE", 
		"SCENT_HUNT_MEGA", 
		"SCENT_MUSK_HERB", 
		"SCENT_MUSK_CARN", 
		"SCENT_DECAY", 
		"SCENT_WASTE", 
		"SCENT_FLORA_GRASSES", 
		"SCENT_FLORA_SHRUBS", 
		"SCENT_FLORA_TREES", 
		"SCENT_FLORA_FRUITS", 
		"SCENT_FLORA_FUNGHI", 
		"SCENT_MOISTURE", 
		"SCENT_ARCANE", 
		"SCENT_FEAR"
	],
	sim_layers.CIVILISATION: [],
	sim_layers.PLAYER_ACTIONS: [],
	sim_layers.SMOKETEST: [
		"SMOKETEST.U", 
		"SMOKETEST.V"
		],
	sim_layers.INVALID: ["INVALID"]
}

## Ordered sub-layer names per `sim_layers` domain in the 512×512 `r32ui` Atomic Grid (Binding 2).
## Mass-conserved quantities use `atomic_multiplier = 100.0` (`1 uint = 0.01` float units / `1 m` depth),
## except `FLORA` (`flora_atomic_multiplier = 1,000,000.0`), `ACTION_KEY` (32-bit spell bitmask), and
## `BIOME_TYPE` (low byte `[0..7]` = biome ID `0..17` or `255`, upper bits `[8..31]` = 24-bit attribution mask).
const atomic_sub_layer_names : Dictionary [sim_layers, PackedStringArray] = {
	sim_layers.LANDSCAPE: [
		"MINERALS", 
		"SOIL_NUTRIENTS", 
		"MAGIC_SATURATION", 
		"BIOME_TYPE"
		],
	sim_layers.WATER: [
		"LIQUID_VOLUME", 
		"ICE_VOLUME", 
		"ARTESIAN_SOURCES", 
		"SALINITY",
		"MAGIC_SATURATION"
		],
	sim_layers.ENERGY: [
		"MAGIC_MAGNITUDE", 
		"MAGIC_TYPE", 
		"GEOTHERMAL"
		],
	sim_layers.ATMOSPHERE: [
		"POLLUTION_DENSITY", 
		"MAGIC_SATURATION"
		],
	sim_layers.FLORA: [
		"GRASSES", 
		"SHRUBS", 
		"TREES_CANOPY", 
		"AQUATIC", 
		"FLORA_DETRITUS", 
		"MAGIC_SATURATION"
		],
	sim_layers.FAUNA: [
		"CARRION", 
		"ANIMAL_WASTE", 
		],
	sim_layers.CIVILISATION: [],
	sim_layers.PLAYER_ACTIONS: ["ACTION_KEY", "ACTION_VALUE", "FEEDBACK", "SPELL_GEOTHERMAL"],
	sim_layers.SMOKETEST: [],
	sim_layers.INVALID: ["INVALID"]
}

## Maximum number of Lagrangian `PopulationCluster` elements allocated in the SSBO (Bindings 3/4) per domain.
const ssbo_layer_to_max_clusters : Dictionary [sim_layers, int] = {
	sim_layers.LANDSCAPE: 0, 
	sim_layers.WATER: 0, 
	sim_layers.ENERGY: 0, 
	sim_layers.ATMOSPHERE: 0, 
	sim_layers.FLORA: 0,
	sim_layers.FAUNA: 1000000, 
	sim_layers.CIVILISATION: 100000, 
	sim_layers.PLAYER_ACTIONS: 1, 
	sim_layers.SMOKETEST: 0, 
	sim_layers.INVALID: 0 
}

## Symbolic SSBO sub-layer names per `sim_layers` domain for debug inspection and push constant binding.
const ssbo_sub_layer_names : Dictionary [sim_layers, PackedStringArray] = {
	sim_layers.LANDSCAPE: [],
	sim_layers.WATER: [],
	sim_layers.ENERGY: [],
	sim_layers.ATMOSPHERE: [],
	sim_layers.FLORA: [],
	sim_layers.FAUNA: ["ANIMAL_CLUSTERS"],
	sim_layers.CIVILISATION: ["CIV_CLUSTERS"],
	sim_layers.PLAYER_ACTIONS: ["PLAYER_ACTIONS"],
	sim_layers.SMOKETEST: [],
	sim_layers.INVALID: []
}

## Display names for each slice of the 64×64×9 `r32f` Coarse Dynamics Grid (Bindings 6/7).
const coarse_sub_layer_names : Dictionary[coarse_layers, String] = {
	coarse_layers.H_UPPER: "H_UPPER",
	coarse_layers.WIND_UPPER_X: "WIND_UPPER_X",
	coarse_layers.WIND_UPPER_Y: "WIND_UPPER_Y",
	coarse_layers.H_LOWER: "H_LOWER",
	coarse_layers.WIND_LOWER_X: "WIND_LOWER_X",
	coarse_layers.WIND_LOWER_Y: "WIND_LOWER_Y",
	coarse_layers.AIR_TEMP: "AIR_TEMP",
	coarse_layers.TERRAIN: "TERRAIN",
	coarse_layers.ROUGHNESS: "ROUGHNESS"
}

## Field identifiers for the 96-byte `std430` `PopulationCluster` struct in Bindings 3/4.
enum population_cluster_params {
	## Continuous world space coordinates (Float grid relative).
	WORLD_POSITION,
	## Current movement direction and momentum.
	MIGRATION_VECTOR,
	## Base taxonomy ID locking biological trait bounds.
	ARCHETYPE_ID,
	## Total mass/population of the cluster; splits when exceeding capacity.
	BIOMASS,
	## Short-term stamina/hunger burned by metabolism and replenished by feeding.
	ENERGY,
	## 0.0 (slow/ectothermic) to 1.0 (fast/endothermic) metabolic rate.
	METABOLIC_RATE,
	## `(Plant, Meat, Carrion)` feeding efficiency weights.
	DIET_SPECTRUM,
	## 0.0 (micro/insect) to 1.0 (megafauna) body mass scale.
	SIZE_MASS,
	## 0.0 (solitary/territorial) to 1.0 (herd/swarm) merging affinity.
	SOCIAL_COHESION,
	## 0.0 (flight) to 1.0 (fight) combat and predation drive.
	AGGRESSION,
	## Relative mass differential required to trigger fleeing behavior.
	FEAR_THRESHOLD,
	## 0.0 (site-faithful) to 1.0 (nomadic) exploratory wandering weight.
	CURIOSITY,
	## 0.0 to 1.0 probability of detecting stimuli within the local 3×3 neighborhood.
	PERCEPTIVENESS,
	## 0.0 (r-selection) to 1.0 (K-selection) reproductive investment strategy.
	OFFSPRING_INVEST,
	## Optimal environmental temperature in degrees Celsius before thermal stress drain.
	TEMP_OPTIMUM,
	## Trait variance magnitude applied when a cluster splits into offspring.
	MUTATION_RATE,
	## 0.0 to 1.0+ accumulated arcane energy concentration.
	MAGIC_SATURATION,
	## Categorical magic alignment ID for mutated clusters.
	MAGIC_MUTATION_TYPE,
	## 0.0 to 1.0 expression strength of mutated magical traits.
	MAGIC_MUTATION_MAGNITUDE
}

## Byte offsets for each field in `population_cluster_params` matching `std430` alignment rules.
const population_cluster_param_offsets : Dictionary[population_cluster_params, int] = {
	population_cluster_params.WORLD_POSITION: 0,      # vec2 (8 bytes, align 8)
	population_cluster_params.MIGRATION_VECTOR: 8,    # vec2 (8 bytes, align 8)
	population_cluster_params.ARCHETYPE_ID: 16,       # uint (4 bytes, align 4)
	population_cluster_params.BIOMASS: 20,            # float (4 bytes, align 4)
	population_cluster_params.ENERGY: 24,             # float (4 bytes, align 4)
	population_cluster_params.METABOLIC_RATE: 28,     # float (4 bytes, align 4)
	population_cluster_params.DIET_SPECTRUM: 32,      # vec3 (12 bytes, align 16)
	population_cluster_params.SIZE_MASS: 44,          # float (4 bytes, align 4)
	population_cluster_params.SOCIAL_COHESION: 48,    # float (4 bytes, align 4)
	population_cluster_params.AGGRESSION: 52,         # float (4 bytes, align 4)
	population_cluster_params.FEAR_THRESHOLD: 56,     # float (4 bytes, align 4)
	population_cluster_params.CURIOSITY: 60,          # float (4 bytes, align 4)
	population_cluster_params.PERCEPTIVENESS: 64,     # float (4 bytes, align 4)
	population_cluster_params.OFFSPRING_INVEST: 68,   # float (4 bytes, align 4)
	population_cluster_params.TEMP_OPTIMUM: 72,       # float (4 bytes, align 4)
	population_cluster_params.MUTATION_RATE: 76,      # float (4 bytes, align 4)
	population_cluster_params.MAGIC_SATURATION: 80,   # float (4 bytes, align 4)
	population_cluster_params.MAGIC_MUTATION_TYPE: 84,      # int (4 bytes, align 4)
	population_cluster_params.MAGIC_MUTATION_MAGNITUDE: 88  # float (4 bytes, align 4)
}

## Total byte stride (`96 B`, 92 bytes padded to 16-byte alignment) of one `PopulationCluster` in `std430`.
const POPULATION_CLUSTER_BYTE_SIZE : int = 96

## Byte stride (`16 B`: `uint source_id, uint packed_data, vec2 world_pos`) of a single `EventData` record.
const EVENT_DATA_BYTE_SIZE : int = 16

## Byte stride (`32 B` with explicit `_pad1`/`_pad2` fields in `std430`) of a `SpellDefinition` in Binding 10.
const SPELL_DEFINITION_BYTE_SIZE : int = 32

## Byte stride (`176 B`) of a `SpeciesArchetype` trait-bounds record in Binding 11.
const SPECIES_ARCHETYPE_BYTE_SIZE : int = 176

## Byte size (`256 B`) of one double-buffered `ImpactCurrency` SSBO half at Binding 12.
const IMPACT_CURRENCY_BYTE_SIZE : int = 256

## Maximum event capacity of a single `EventBuffer` half.
const event_buffer_max_events : int = 10000

## Total byte size of one `EventBuffer` half (`16 B` aligned header + `event_buffer_max_events * 16 B`).
const event_buffer_byte_size : int = 16 + (event_buffer_max_events * EVENT_DATA_BYTE_SIZE)

## Alias for `IMPACT_CURRENCY_BYTE_SIZE` (`256 B`) used by buffer allocation helpers.
const impact_currency_byte_size : int = IMPACT_CURRENCY_BYTE_SIZE

## Maps a `sim_layers` domain to the `std430` struct byte stride of its auxiliary SSBO.
const aux_ssbo_struct_sizes : Dictionary = {
	sim_layers.PLAYER_ACTIONS: SPELL_DEFINITION_BYTE_SIZE,  # binding 10: SpellBook
	sim_layers.FAUNA: SPECIES_ARCHETYPE_BYTE_SIZE,           # binding 11: ArchetypeLimits
}

## Maps a `sim_layers` domain to the maximum element count allocated in its auxiliary SSBO.
const aux_ssbo_counts : Dictionary = {
	sim_layers.PLAYER_ACTIONS: 32,   # 32 spell bits
	sim_layers.FAUNA: 200,           # max archetypes
}

## Fixed Set 0 uniform binding numbers for opt-in auxiliary SSBOs on `LayerSimulator`.
const aux_ssbo_bindings : Dictionary = {
	"SPELLBOOK": 10,          # Single-buffered, read-only at runtime (PLAYER_ACTIONS)
	"ARCHETYPE_LIMITS": 11,   # Single-buffered, read-only at runtime (FAUNA)
	"IMPACT_CURRENCY": 12,    # Double-buffered ping-pong, GPU-write / CPU-read
}

## Bit shift (`8`) separating the low-byte biome ID from the 24-bit spell attribution mask in `BIOME_TYPE`.
const BIOME_TEXEL_ATTRIBUTION_SHIFT : int = 8
## Bitmask (`0xFFFFFF00`) selecting the upper 24-bit `ACTION_KEY` attribution snapshot in a `BIOME_TYPE` texel.
const BIOME_TEXEL_ATTRIBUTION_MASK : int = 0xFFFFFF00
## Bitmask (`0xFF`) selecting the low-byte catalog biome ID in a `BIOME_TYPE` texel.
const BIOME_TEXEL_ID_MASK : int = 0xFF

## Sentinel biome ID (`255`) indicating an uninitialized or legacy-repaired cell awaiting classification.
const BIOME_UNCLASSIFIED : int = 255

## Highest valid biome ID (`17`, `PELAGIC_DEEP_OCEAN`) in the Master Biome Catalog.
const BIOME_MAX_VALID_ID : int = 17

## Master Biome Catalog mapping canonical biome names to their integer IDs (`0..17`).
const biome_catalog_ids : Dictionary = {
	"GLACIAL_ICE_SHEET": 0,
	"POLAR_TUNDRA": 1,
	"BOREAL_TAIGA": 2,
	"ALPINE_MEADOW": 3,
	"TEMPERATE_FOREST": 4,
	"TEMPERATE_GRASSLAND": 5,
	"TEMPERATE_RAINFOREST": 6,
	"MEDITERRANEAN_SCRUB": 7,
	"SUBTROPICAL_DESERT": 8,
	"SEMI_ARID_SAVANNA": 9,
	"TROPICAL_RAINFOREST": 10,
	"THERMAL_OASIS": 11,
	"FRESHWATER_WETLAND": 12,
	"MANGROVE_ESTUARY": 13,
	"FRESHWATER_LAKE": 14,
	"SEA_ICE_FROZEN_SEA": 15,
	"SHALLOW_COASTAL_SHELF": 16,
	"PELAGIC_DEEP_OCEAN": 17,
}


## Builds the mapping from `sim_layers` domains to their flat slice indices in the Fine Float Grid.
static func create_float_layer_indices_map() -> Dictionary[sim_layers, PackedInt32Array]:
	return _build_map_from_names(float_sub_layer_names)


## Builds the mapping from `sim_layers` domains to their flat slice indices in the Atomic Grid.
static func create_atomic_layer_indices_map() -> Dictionary[sim_layers, PackedInt32Array]:
	return _build_map_from_names(atomic_sub_layer_names)


## Builds the identity mapping from `coarse_layers` enum values to their slice indices in the Coarse Grid.
static func create_coarse_layer_indices_map() -> Dictionary[coarse_layers, int]:
	# Map each valid coarse layer enum value (`0..COUNT-1`) to its integer slice index.
	var map : Dictionary[coarse_layers, int] = {}
	for cl : int in coarse_layers.values():
		if cl == coarse_layers.COUNT:
			continue
		map[cl as coarse_layers] = cl
	return map


## Builds the mapping from `sim_layers` domains to their `[start_offset, max_clusters]` bounds in the SSBO.
static func create_ssbo_layer_indices_map() -> Dictionary[sim_layers, PackedInt32Array]:
	var map : Dictionary[sim_layers, PackedInt32Array]
	var current_offset : int = 0
	# Assign contiguous `[offset, capacity]` ranges across all domains with non-zero cluster capacity.
	for sl : int in sim_layers.values():
		if sl < 0 : continue
		var max_clusters : int = ssbo_layer_to_max_clusters[sl]
		if max_clusters > 0:
			map[sl] = PackedInt32Array([current_offset, max_clusters])
			current_offset += max_clusters
		else:
			map[sl] = PackedInt32Array()
	return map


## Assigns sequential flat texture-array slice indices to each domain's sub-layer list in `names_dict`.
static func _build_map_from_names(names_dict: Dictionary) -> Dictionary[sim_layers, PackedInt32Array]:
	var map : Dictionary[sim_layers, PackedInt32Array]
	if not names_dict is Dictionary[sim_layers, PackedStringArray]:
		push_error("Cannot build map from names_dict in Helpers.gd - names_dict is not [sim_layers, PackedStringArray]")
		return {sim_layers.INVALID:[]}
	# Walk domains in enum order and assign monotonically increasing slice indices.
	var count : int = 0
	for sl : int in sim_layers.values():
		if sl < 0 : continue
		map[sl] = []
		@warning_ignore("unsafe_method_access")
		var layers_needed : int = names_dict[sl].size()
		map[sl].resize(layers_needed)
		for i : int in layers_needed:
			map[sl][i] = count
			count += 1
	return map
	
	
