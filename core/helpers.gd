extends RefCounted
class_name Helpers

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

enum system_names {
	TOPOGRAPHY_GENERATION = 0,
	THERMODYNAMICS = 1,
	FLUID_DYNAMICS = 2,
	ECOLOGY_BASELINE = 3,
	FAUNA_BEHAVIOR = 4,
	CIVILIZATION_BEHAVIOR = 5,
	PLAYER_ACTIONS = 6
}

enum coarse_layers {
	H_UPPER = 0,         # Upper layer column height (stratosphere)
	WIND_UPPER_X = 1,    # Upper layer eastward velocity (jet stream)
	WIND_UPPER_Y = 2,    # Upper layer southward velocity
	H_LOWER = 3,         # Lower layer column height (troposphere)
	WIND_LOWER_X = 4,    # Lower layer eastward velocity (surface wind)
	WIND_LOWER_Y = 5,    # Lower layer southward velocity
	AIR_TEMP = 6,        # Downsampled fine air_temp (thermal forcing on lower layer)
	TERRAIN = 7,         # Downsampled area-weighted mean terrain (for Audusse well-balanced)
	ROUGHNESS = 8,       # Sub-grid terrain variance / roughness (orographic boundary drag)
	COUNT
}

# ==========================================
## ARRAY A: THE FLOAT GRID (r16f)
## Used for fast physics & read-only environment data.
## Note: Variables like WATER_LIQUID_HEIGHT are cached floats. 
## The absolute Source of Truth for mass remains the Atomic grid. 
## Floats are used here only to optimize neighbor-sampling in shaders.
##
## --- GLOBAL PHYSICAL & SYSTEM UNIT SCALES ---
## Grid Cell Size (Horizontal): Variable — derived from planetary_diameter ÷ texture_resolution.
##   Default config (Earth-like): diameter=12,742 km, texture=512×512 → ~78 km/cell at equator.
##   The shaders operate entirely in normalized grid space; cell size never appears in formulae.
##   DO NOT assume 100m×100m — that was an error. Compute from WorldConfig if you need physical area.
##
## LANDSCAPE (Height-Units ≡ Hectometers):
##   - BEDROCK_HEIGHT, SEDIMENT_HEIGHT: 1.0 float unit = 100 meters of height/depth.
##     (a.k.a. "hectometers"; max peak 200.0 = 20,000 m = Everest-scale)
##   - GROUND_TEMP: Degrees Celsius (°C). Phase-change lock at 0°C.
##   - SLOPE.X/Y: Height-units per grid-cell gradient (dimensionless; range ≈ [-1, 1])
##
## WATER (same Height-Unit system as landscape — proven by hydraulic self_height sum):
##   - WATER_LIQUID_HEIGHT, WATER_ICE_HEIGHT: 1.0 float unit = 100 meters of equivalent depth.
##     These are DEPTH values, NOT volumes. The hydraulic shader adds them directly to bedrock:
##       self_height = bedrock + sediment + liquid_mass + ice_mass
##     All four terms share the same hectometer unit. Volume would require cell area (see above).
##   - WATER_TEMP: Degrees Celsius (°C). Same phase-change logic as ground_temp.
##   - NET_VELOCITY.X/Y: Abstract flow rate units (scaled by max_flow_rate).
##   - DIVERGENCE, TURBULENCE: Dimensionless flow derivatives.
##
## ENERGY:
##   - SUNLIGHT: Normalized Lambertian insolation [0.0, 1.0]. 1.0 = zenith on equator.
##   - TIDAL_FORCE: Cosine-based tidal oscillator ∈ [-1, 1]. Dimensionless.
##
## ATMOSPHERE:
##   - AIR_TEMP: Degrees Celsius (°C). Driven by equator/pole latitudinal gradient ± orographic effects.
##   - WIND.X/Y: Horizontal wind velocity from the SWE (Shallow Water Equations) dynamical core.
##     SWE co-evolves wind and pressure (column height h) in a conservative finite-volume update.
##     Dimensionless grid-cells/frame. Terrain-aware (air flows around mountains via Audusse source).
##   - WIND.Z: Diagnosed vertical wind from horizontal divergence: -div(h*u)/h.
##     Positive = updraft, negative = subsidence. Used by cloud parameterization and fauna.
##   - HUMIDITY: Specific humidity normalized ratio. Advection + evap - precip, clamped [~0.03, ~1.5].
##   - RAIN, SNOW: Precipitation rate normalized to [0, 1] via clamp(rate * 50, 0, 1).
##   - PRESSURE: SWE column height h (pressure ∝ g*h). Primary conserved field. Hydrostatic.
##   - PRESSURE_L1/L2: Diagnosed upper-layer pressures from lapse rate: h * exp(-z/H_scale).
##     Used for vis (cloud caps, jet stream) and orographic cloud logic.
##
## FLORA:
##   - GROWTH_RATE_MODIFIER: Dimensionless multiplier [0, 1] from temperature/moisture suitability.
##   - CANOPY_SHADE: Dimensionless light reduction factor from tree canopy coverage.
##
## FAUNA:
##   - SCENT_* fields: Olfactory signal intensities. Dimensionless concentration values.
##     Decayed each frame; used for agent navigation and territory marking.
# ==========================================
const float_sub_layer_names : Dictionary [sim_layers, PackedStringArray] = {
	sim_layers.LANDSCAPE: [
		"BEDROCK_HEIGHT", 
		"SLOPE.X", 
		"SLOPE.Y", 
		"SEDIMENT_HEIGHT", 
		"GROUND_TEMP"
		],
	sim_layers.WATER: [
		# Cached from Atomic LIQUID_VOLUME and ICE_VOLUME
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

# ==========================================
## ARRAY B: THE ATOMIC GRID (r32ui / r32i)
## Used exclusively for consumable, interactive resources via imageAtomicAdd
##
## --- GLOBAL PHYSICAL & SYSTEM UNIT SCALES ---
## Grid Cell Size (Horizontal): Same as Float Grid — see Array A header above.
##   Default config: ~78 km/cell at equator. NOT 100m×100m.
##
## ATOMIC MULTIPLIERS (from WorldConfig push constants):
##   - atomic_multiplier = 100.0       → Used by WATER, LANDSCAPE, ENERGY, ATMOSPHERE layers
##   - flora_atomic_multiplier = 1,000,000.0 → Used ONLY by FLORA layer (10,000× more precision)
##
## WATER (atomic_multiplier = 100.0):
##   - LIQUID_VOLUME, ICE_VOLUME: 1 uint unit = 0.01 height-units = 1 meter of equivalent depth.
##     Conversion in shaders: float_depth = uint_value / atomic_multiplier (= ÷ 100).
##     Example: 5000 uint → 50.0 float → 5,000 m depth.
##     NOTE: These are DEPTH units (same hectometer system as bedrock), NOT volume (GL).
##           Volume would require multiplying by cell area (~78km × 78km ≈ 6,100 km² default).
##   - ARTESIAN_SOURCES: Same depth units; injected each frame at artesian_flow_rate.
##   - SALINITY: Dimensionless concentration ratio [0, atomic_multiplier cap].
##
## LANDSCAPE (atomic_multiplier = 100.0):
##   - MINERALS, SOIL_NUTRIENTS: Dimensionless abundance scales.
##     1 uint = 0.01 "nutrient units". Interpretation is layer-specific.
##   - MAGIC_SATURATION: Arcane concentration. Game mechanic, not physical.
##   - BIOME_TYPE: Packed 32-bit classification texel (NOT a plain multiplier-scaled
##     quantity — never imageAtomicAdd, never divide by atomic_multiplier):
##       [0..7]   biome ID  — 0..17 valid catalog IDs; 255 = BIOME_UNCLASSIFIED.
##       [8..31]  attribution snapshot — 24-bit ACTION_KEY spell-presence bitmask
##                captured at classification time. All-zero = natural transition.
##     Single-writer discipline: only biome_seeding_generator.glsl (world-gen
##     bootstrap) and biome_classifier_sim.glsl (runtime) write it, via plain
##     imageStore of the full 32-bit texel. CPU never writes back.
##     Plan: _planning/event_logging_system_plan.md §2.1.
##
## ENERGY (atomic_multiplier = 100.0):
##   - GEOTHERMAL: 1 uint = 0.01 normalized heating coefficient.
##     Conversion: float_heat = uint_value / atomic_multiplier (= ÷ 100).
##     Applied as: ground_temp += geothermal * geothermal_heating_rate * deltaTime.
##     With defaults (geothermal_heating_rate=0.01): 100 uint → 1.0 float → +0.01 °C/frame.
##     This is a tunable heating rate, NOT real thermodynamics (no latent heat, no mass involved).
##     The old comment claiming "GL heat energy equivalent" was fictional — removed.
##   - MAGIC_MAGNITUDE, MAGIC_TYPE: Game mechanics, not physical units.
##
## ATMOSPHERE (atomic_multiplier = 100.0):
##   - POLLUTION_DENSITY: Dimensionless concentration. Affects air quality / visibility if implemented.
##   - MAGIC_SATURATION: Game mechanic.
##
## FLORA (flora_atomic_multiplier = 1,000,000.0 — separate from all other layers!):
##   - GRASSES, SHRUBS, TREES_CANOPY, AQUATIC: Population biomass in fixed-point notation.
##     Conversion: float_biomass = uint_value / flora_atomic_multiplier (= ÷ 1,000,000).
##     Carrying capacities (K): grass ≤ 1.0, shrub ≤ 3.0, tree ≤ 5.0, aquatic ≤ 2.0.
##     High multiplier prevents small per-frame growth deltas from truncating to zero in r32ui.
##     Example: 500,000 uint → 0.5 float biomass → 50% of grass carrying capacity.
##   - FLORA_DETRITUS: Dead organic matter pool. Same multiplier and dimensionless biomass scale.
##   - MAGIC_SATURATION: Game mechanic.
##
## FAUNA (atomic_multiplier = 100.0):
##   - CARRION, ANIMAL_WASTE: Detritus pools for scavenger/decomposer food chains.
# ==========================================
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
	# PLAYER INTERACTION HERE in MAGIC ONLY
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

# ==========================================
## ARRAY C: THE SSBO CLUSTERS
## Used for Lagrangian agents and populations
# ==========================================
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

# ==========================================
## ARRAY D: THE COARSE GRID (r32f)
## Used for large-scale dynamics (SWE atmosphere)
# ==========================================
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

enum population_cluster_params {
	## Continuous world space coordinates (Float grid relative).
	WORLD_POSITION,
	## Current movement direction and momentum.
	MIGRATION_VECTOR,
	## Base taxonomy ID. Locks absolute biological limits (e.g. max size) to prevent absurd cross-mutations.
	ARCHETYPE_ID,
	## Total mass/population of the cluster. Grows when energy is surplus; cluster splits if too large.
	BIOMASS,
	## Short-term stamina/hunger. Burned by actions and metabolism. Replenished by successful feeding.
	ENERGY,
	
	# === Mutable / Evolvable Traits (The Genome) ===
	
	## 0.0 (Reptilian/Slow) to 1.0 (Avian/Fast). High rate burns energy quickly but acts/recovers faster.
	METABOLIC_RATE,
	## (Plant, Meat, Carrion) efficiency. (1,0,0) = Strict Herbivore, (0,1,0) = Apex Predator, (0,0,1) = Scavenger.
	DIET_SPECTRUM,
	## 0.0 (Insect/Rodent) to 1.0 (Megafauna). Affects overall baseline energy cost, combat survival, and speed.
	SIZE_MASS,
	## 0.0 (Solitary/Territorial) to 1.0 (Swarm/Herd). Determines willingness to merge with similar clusters.
	SOCIAL_COHESION,
	## 0.0 (Flight) to 1.0 (Fight). Determines reaction and hunting drive when encountering foreign species.
	AGGRESSION,
	## Mass differential required to flee. 0.0 = panics at everything, 1.0 = fearless even against titans.
	FEAR_THRESHOLD,
	## 0.0 (Static/Territorial) to 1.0 (Nomadic). Drives random wandering logic in the migration vector.
	CURIOSITY,
	## 0.0 to 1.0. Replaces sensory radius. Detection of things in local 9-cells is chance-based on this float.
	PERCEPTIVENESS,
	## 0.0 (r-selection: splits often, weak offspring) to 1.0 (K-selection: splits rarely, huge offspring).
	OFFSPRING_INVEST,
	## Preferred climate. Environmental temperature divergence from this causes a continuous energy drain penalty.
	TEMP_OPTIMUM,
	## Variance applied to traits upon splitting. Low = stable species, High = rapid chaotic evolution.
	MUTATION_RATE,
	## 0.0 to 1.0+. Concentration of arcane energy. 
	MAGIC_SATURATION,
	## Integer representing the specific elemental or categorical magic alignment (e.g., Fire, Decay, Arcane).
	MAGIC_MUTATION_TYPE,
	## 0.0 to 1.0. How strongly this cluster exhibits its mutated magical traits.
	MAGIC_MUTATION_MAGNITUDE
}

# Byte offsets structured to perfectly align with GLSL std430 packing rules
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

const POPULATION_CLUSTER_BYTE_SIZE : int = 96 # Padded to 16-byte alignment boundary (92 bytes rounded up)

# ==========================================
# AUXILIARY SSBO STRUCT SIZES & REGISTRY
# Per-domain lookup tables with custom struct layouts, bound at bindings 8–12.
# Binding contract: _planning/event_logging_system_plan.md §2.7 (binding 8 is the
# frozen geothermal POC's exclusively — no new writers; supersedes the retired
# aux_ssbo_binding_impact_plan.md).
# ==========================================

## EventData struct (binding 8). 16 bytes per event. RETAINED for reference:
## the EventBuffer itself was decommissioned with the geothermal POC at plan
## §8.4 (biome causation rides in the BIOME_TYPE texel); if a future system
## genuinely needs event-stream semantics, it re-derives this layout.
## Layout: uint source_id, uint packed_data, vec2 world_pos.
## std430: alignment 8 (from vec2), size 16 → array stride 16, no padding needed.
const EVENT_DATA_BYTE_SIZE : int = 16

## SpellDefinition struct (binding 10). 32-byte array stride.
## Layout: uint spell_id, uint effect_type, float magnitude, float radius, float duration,
## uint _pad0 (reserved), uint _pad1, uint _pad2 (explicit padding).
## NOTE: std430 does NOT round struct strides up to 16 — that is the std140 rule.
## An all-scalar struct has natural std430 alignment 4 → array stride 24. The 32-byte
## stride only holds because the GLSL struct DECLARES _pad1/_pad2 (the same explicit-
## padding standard PopulationCluster follows). Keep GLSL and this constant in sync.
const SPELL_DEFINITION_BYTE_SIZE : int = 32

## SpeciesArchetype struct (binding 11). Placeholder until the Designer finalizes the trait min/max layout.
## Estimated ~160 bytes. Update this constant when the struct is finalized.
const SPECIES_ARCHETYPE_BYTE_SIZE : int = 176

## ImpactCurrency buffer half (binding 12). Small fixed buffer for the atomic
## currency counter + future fields. Two halves are allocated (ping-pong).
const IMPACT_CURRENCY_BYTE_SIZE : int = 256

## Maximum number of events the EventBuffer could hold before CPU extraction.
## Historical (POC); retained alongside EVENT_DATA_BYTE_SIZE for reference.
const event_buffer_max_events : int = 10000

## Total byte size of one EventBuffer half: 16-byte header (uint counter + explicit
## uint _header_pad[3] in GLSL so events[] starts at offset 16, not the natural
## std430 offset 8) + events array.
const event_buffer_byte_size : int = 16 + (event_buffer_max_events * EVENT_DATA_BYTE_SIZE)

## Total byte size of the ImpactCurrency buffer.
const impact_currency_byte_size : int = IMPACT_CURRENCY_BYTE_SIZE

# Maps a sim_layers domain to its aux SSBO struct size in bytes.
const aux_ssbo_struct_sizes : Dictionary = {
	sim_layers.PLAYER_ACTIONS: SPELL_DEFINITION_BYTE_SIZE,  # binding 10: SpellBook
	sim_layers.FAUNA: SPECIES_ARCHETYPE_BYTE_SIZE,           # binding 11: ArchetypeLimits
}

# Maps a sim_layers domain to the number of elements in its aux SSBO.
const aux_ssbo_counts : Dictionary = {
	sim_layers.PLAYER_ACTIONS: 32,   # 32 spell bits
	sim_layers.FAUNA: 200,           # max archetypes (designer-configurable)
}

# Fixed binding numbers for auxiliary SSBOs. Referenced by GpuWorldState during uniform creation
# and by GLSL shaders via layout(std430, set = 0, binding = N).
# NOTE: binding 8 (EventBuffer) was decommissioned with the geothermal POC at
# plan §8.4 — biome causation travels in the BIOME_TYPE texel's attribution
# bits (§2.1), not through an event stream. Binding 9's ping-pong-partner
# reservation is likewise retired; binding 8/9 are free for future aux SSBOs.
const aux_ssbo_bindings : Dictionary = {
	"SPELLBOOK": 10,          # Single-buffered, read-only at runtime (PLAYER_ACTIONS)
	"ARCHETYPE_LIMITS": 11,   # Single-buffered, read-only at runtime (FAUNA)
	"IMPACT_CURRENCY": 12,    # Double-buffered ping-pong, GPU-write / CPU-read (EVENT_LOGGING §2.7)
}

# ==========================================
# MASTER BIOME CATALOG (LANDSCAPE.BIOME_TYPE)
# Index into these tables == biome ID written to the BIOME_TYPE texel's low byte
# and baked into the shared GLSL centroid include (_assets/biome_globals.gdshaderinc).
# The GLSL tables and these GPU-facing arrays describe the same 18 rows; the smoke
# test (tests/test_biome_classification.gd) verifies the sync.
# Plan: _planning/event_logging_system_plan.md §2.1/§2.3.
# ==========================================

## Texel format (r32ui, one per cell):
##   bits [0..7]   biome ID (0..17 valid; 255 = BIOME_UNCLASSIFIED sentinel)
##   bits [8..31]  attribution snapshot — 24-bit ACTION_KEY spell-presence bitmask
##                 captured at classification time (0 = natural transition)
const BIOME_TEXEL_ATTRIBUTION_SHIFT : int = 8
const BIOME_TEXEL_ATTRIBUTION_MASK : int = 0xFFFFFF00  # upper 24 bits
const BIOME_TEXEL_ID_MASK : int = 0xFF                 # low byte

## Sentinel: "not yet evaluated". Written ONLY as a deliberate repair fill
## (legacy saves, §7.7); a healthy bootstrapped world contains only 0..17.
## Any runtime read outside 0..17 is treated as unclassified and reclassified
## immediately (no hysteresis).
const BIOME_UNCLASSIFIED : int = 255

## Highest valid biome ID in the catalog (BIOME_PELAGIC_DEEP_OCEAN).
const BIOME_MAX_VALID_ID : int = 17

## Biome IDs by catalog order (index == ID). Names kept beside the IDs for
## AeonLog/naming work in Phase 3.
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

# ==========================================
# MAPPING GENERATORS
# ==========================================

static func create_float_layer_indices_map() -> Dictionary[sim_layers, PackedInt32Array]:
	return _build_map_from_names(float_sub_layer_names)

static func create_atomic_layer_indices_map() -> Dictionary[sim_layers, PackedInt32Array]:
	return _build_map_from_names(atomic_sub_layer_names)

static func create_coarse_layer_indices_map() -> Dictionary[coarse_layers, int]:
	var map : Dictionary[coarse_layers, int] = {}
	for cl : int in coarse_layers.values():
		if cl == coarse_layers.COUNT:
			continue
		map[cl as coarse_layers] = cl
	return map
	
static func create_ssbo_layer_indices_map() -> Dictionary[sim_layers, PackedInt32Array]:
	var map : Dictionary[sim_layers, PackedInt32Array]
	var current_offset : int = 0
	for sl : int in sim_layers.values():
		if sl < 0 : continue
		var max_clusters : int = ssbo_layer_to_max_clusters[sl]
		if max_clusters > 0:
			# Storing [offset, capacity] for SSBOs instead of individual element indices
			map[sl] = PackedInt32Array([current_offset, max_clusters])
			current_offset += max_clusters
		else:
			map[sl] = PackedInt32Array()
	return map

static func _build_map_from_names(names_dict: Dictionary) -> Dictionary[sim_layers, PackedInt32Array]:
	var map : Dictionary[sim_layers, PackedInt32Array]
	if not names_dict is Dictionary[sim_layers, PackedStringArray]:
		push_error("Cannot build map from names_dict in Helpers.gd - names_dict is not [sim_layers, PackedStringArray]")
		return {sim_layers.INVALID:[]}
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
	
	
