extends Resource
class_name WorldConfig
## Defines the global scale parameters (grid sizes, seed values, tick rates, and generator arrays).

# CONFIG
## The pixel resolution of a single chunk (e.g. 1024).
@export var chunk_resolution : int:
	set(value):
		chunk_resolution = value
		setup_derived_vars()
## Number of chunks in the X-axis.
@export var chunk_grid_x : int:
	set(value): 
		chunk_grid_x = value
		setup_derived_vars()
## Number of chunks in the Y-axis.
@export var chunk_grid_y : int:
	set(value):
		chunk_grid_y = value
		setup_derived_vars()

## If true, halts simulation logic after world generation.
@export var stop_after_bootstrap : bool = true

## Sequential list of execution passes to run each frame during world simulation.
@export var sim_layers : Array[LayerSimulator]
## Sequential list of generation layers to run iteratively during initial world creation.
@export var layer_generators : Array[LayerGenerator]

@export_group("Scale & Geometry")
## Maximum absolute height of terrain in Height-Units (Hectometers: 1.0 = 100 meters).
## E.g., 200.0 = 20,000 m (Everest-scale). Used by landmass_height_generator as output range,
## and by hydraulic_flow_sim in self_height = bedrock + sediment + liquid + ice (all share this unit).
@export var max_elevation: float = 200.0
## Maximum sediment depth in Height-Units (1.0 = 100 meters). Sediment accumulates in lowlands
## via erosion and contributes to self_height alongside bedrock and water.
@export var max_sediment_depth: float = 1.0
## Atomic multiplier for WATER, LANDSCAPE, ENERGY, and ATMOSPHERE layers.
## 1.0 float Height-Unit (= 100 m depth) = 100.0 atomic uint units.
## Conversion in shaders: float_val = imageAtomicLoad(...) / atomic_multiplier;
## NOT used by FLORA — see flora_atomic_multiplier below.
@export var atomic_multiplier: float = 100.0
## Atomic multiplier for FLORA layers ONLY. 1.0 float biomass unit = 1,000,000 atomic uint units.
## This 10,000× higher precision prevents small per-frame logistic growth deltas from
## truncating to zero when written to r32ui via imageAtomicAdd.
## Conversion in shaders: float_biomass = uint_value / flora_atomic_multiplier;
@export var flora_atomic_multiplier: float = 1000000.0
## Physical diameter of the planet in KILOMETERS. Used to derive grid cell physical size:
##   cell_size_at_equator ≈ (π × planetary_diameter) / texture_resolution
## Default Earth (12,742 km) at 512×512 texture → ~78 km/cell.
## This value does NOT appear directly in shaders — they use normalized grid coordinates.
@export var planetary_diameter: float = 12742.0
## Maximum Simulation speed as a multiplier of pipeline passes per frame.
## Each speed unit = one additional FULL dispatch of every sim layer per frame at the
## fixed 60Hz timestep (see global_scale_SOT.md §1b) — GPU cost scales linearly with
## speed. Cap is 4 to keep visualizer + async readbacks inside the frame budget.
@export var max_sim_speed : int = 4


@export_group("Orbital & Solar")
## How many simulated days constitute a full seasonal cycle. (e.g. 360.0)
@export var days_per_year: float = 360.0
## Maximum orbital tilt in radians, governing seasonal intensity. (e.g. 0.409 = 23.5 deg)
@export var max_axial_tilt: float = 0.409
## Initial season angle in radians (0.0 to 2*PI) at world creation (e.g. 0.0 = Summer Solstice)
@export var initial_season_phase: float = 0.0
## Absolute multiplier for incident solar energy at the zenith (1.0 = 100% normalized sunlight).
@export var base_solar_power: float = 1.0

@export_group("Climate & Temperature")
## Max base temp at equator (e.g. 35.0)
@export var equator_temp: float = 35.0
## Min base temp at poles (e.g. -35.0)
@export var pole_temp: float = -35.0
## Thermal coupling ratio between ground and air temperatures (e.g. 0.4)
@export var ground_mix_factor: float = 0.4
## Atmospheric lapse rate (altitude cooling in deg C per max elevation, e.g. 15.0)
@export var lapse_rate: float = 15.0

@export_group("Atmosphere & Wind")
## Global Coriolis force magnitude scale (e.g. 1.0)
@export var coriolis_strength: float = 0.75
## Planetary air drag coefficient (e.g. 0.98)
@export var wind_friction: float = 0.98
## Limits/scales WIND vectors when fetching Semi-Lagrangian HUMIDITY origins (e.g. 1.0)
@export var wind_advection_scale: float = 1.0

# --- Pressure System Parameters ---
## Reference sea-level pressure as normalized anomaly; 0.0 = standard 1013.25 hPa (e.g. 0.0)
@export var base_pressure_sea_level: float = 0.0
## Amplitude of latitudinal Hadley/Ferrel/Polar cell pressure variation (e.g. 0.08)
@export var latitude_pressure_amp: float = 0.08
## Hydrostatic pressure drop per unit terrain height ≈12 hPa/km in normalized units (e.g. 0.00012)
@export var altitude_lapse_rate: float = 0.00012
## Thermal-to-pressure coupling coefficient; warm air lowers local pressure, so negative (e.g. -0.003)
@export var thermal_pressure_coef: float = -0.003

# --- SWE (Shallow Water Equations) Parameters ---
## Gravitational acceleration for SWE. Game-scale tuned: sqrt(g * h0) ≈ 5x max wind speed.
## With h0=1.0 and max_wind=0.1, g=0.25 gives sqrt(0.25)=0.5 = 5x wind. (e.g. 0.25)
@export var swe_gravity: float = 0.25
## Reference column height for SWE (normalized; pressure ∝ g*h). (e.g. 1.0)
@export var swe_reference_height: float = 1.0
## Thermal expansion coefficient for SWE pressure forcing.
## Humidity-modulated: dry air responds at full alpha, moist air is buffered.
@export var swe_thermal_alpha: float = 0.15
## Target global mean temperature (°C) for SWE thermal forcing.
## Warm regions (T > T_mean) gain mass (high pressure); cold regions lose mass (low pressure).
@export var swe_global_mean_temp: float = 15.0
## Linear wind friction (per-second decay rate). exp(-friction*dt) for stability.
## Applied per-substep inside the SWE loop for numerical stability.
## Controls the Ekman number (friction / 2*Coriolis) — higher = more cross-isobar
## flow = more mass transport = more pressure evolution = more dynamic weather.
## 0.2 = e-folding 5s, Ekman ~0.14 at mid-latitudes. Compromise: visible wind
## that crosses isobars enough to drive pressure evolution.
## 0.1 = wind too geostrophic (flows along isobars, static lock-in)
## 0.5+ = wind too damped (local noise, no large-scale organization)
@export var swe_wind_friction: float = 0.03
@export var swe_relax_strength: float = 12.0

@export_group("Coarse Dynamics")
## Pixel resolution of the coarse dynamics grid along each axis (default 64, i.e. 1/8th of 512).
@export var coarse_resolution: int = 64
## Gravitational acceleration for the coarse SWE (default 5.0).
## Ensures CFL stability (<=0.5) across 30-60 FPS while resolving the planetary Rossby radius.
@export var coarse_swe_gravity: float = 5.0
## Column height relaxation strength bounding h in the coarse SWE (default 10.0).
@export var coarse_swe_relax_strength: float = 10.0
## Drag coefficient scaling boundary layer friction by sub-grid elevation variance / roughness (default 0.15).
@export var coarse_orographic_drag: float = 0.15
## Density ratio between upper and lower atmospheric layers (Phase 2 reference, default 0.7).
@export var coarse_density_ratio: float = 0.7

@export_group("Water & Ice")
## Initial sea level as ratio of max_elevation. Determines water depth in Height-Units:
##   initial_depth = max_elevation × sea_level_ratio (e.g., 200.0 × 0.135 = 27.0 = 2,700 m)
@export var sea_level_ratio: float = 0.0135
## Max volumetric water transfer scale per simulation step (dimensionless).
@export var max_flow_rate: float = 1.0
## Temperature (°C) at which ice begins forming gradually.
@export var freeze_threshold: float = -2.0
## Temperature (°C) at which ALL remaining liquid water instantaneously freezes solid.
@export var total_freeze_temp: float = -400.0
## Exponent for freezing curve shape between freeze_threshold and total_freeze_temp.
@export var total_freeze_curve: float = 0.04
## Max ice thickness cap in Height-Units (1.0 = 100m). Default 0.04 = 4 meters.
@export var max_ice_thickness: float = 0.04
## Ice depth (Height-Units) at which insulation_factor = 0.0 (full thermal block).
## Formula: insulation = clamp(1 - ice / thermal_ice_influence, 0, 1)
## Default 0.05 → 5m ice = complete ground-to-air insulation.
@export var thermal_ice_influence: float = 0.05
## Fraction of liquid water → humidity per frame. Applied where T > freeze_threshold.
## NOW ALSO DRIVES PRESSURE: evaporation adds atmospheric mass (vapor has weight!).
## Oceans (high evap) → higher pressure → outflow. Deserts (no evap) → lower pressure.
@export var evaporation_rate: float = 0.05
## Fraction of excess humidity → precipitation per frame.
## NOW ALSO DRIVES PRESSURE: precipitation removes atmospheric mass (rain leaves column).
## Storm systems (high precip) → low pressure → draws in surrounding air.
@export var precipitation_rate: float = 0.05
## Tunable thermal energy coefficient for water phase changes (liquid ↔ vapor).
## NOT real latent heat (2260 kJ/kg) — this is a game-scale arbitrary unit.
@export var latent_heat_vaporization: float = 10.0
## Per-frame injection into ARTESIAN_SOURCES in atomic uint units.
## Actual depth added = artesian_flow_rate / atomic_multiplier per frame.
@export var artesian_flow_rate: float = 0.01
## Fraction of soil nutrients eroded by water flow per frame (dimensionless [0,1]).
@export var nutrient_erosion_rate: float = 0.05
## Tidal amplitude in Height-Units. Applied as: self_height -= tidal_force * tidal_amplitude.
## Default 0.05 = 5m peak-to-trough water surface variation.
@export var tidal_amplitude: float = 0.1

@export_group("Thermodynamics")
## Heat transfer rate between air/ground/water per frame (dimensionless coupling).
@export var heat_transfer_rate: float = 0.40
## Global thermal diffusion speed across grid neighbors (dimensionless).
@export var thermal_diffusion_rate: float = 0.5
## Tunable energy coefficient for water phase changes (same scale as latent_heat_vaporization).
@export var latent_heat_capacity: float = 10.0
## Solar → ground heating rate. Multiplied against SUNLIGHT float value (dimensionless [0,1]).
## With radiative cooling present, this should be ~1.0–5.0 (100–500× old 0.01).
## Calibrate so equilibrium at equatorial noon ≈ equator_temp.
## Increased 4× from 2.0 → 8.0 so sunlight dominates over geothermal.
@export var solar_heating_rate: float = 24.0
## Geothermal → ground heating rate. Multiplied against GEOTHERMAL atomic value
## (after ÷ atomic_multiplier conversion). Default 0.01 means full geothermal (1.0 float)
## adds +0.01 °C/frame. This is a tunable rate, not real thermodynamics.
@export var geothermal_heating_rate: float = 0.01
## Ground→air convection strength multiplier (dimensionless).
## Controls how strongly ground temperature drives air temperature.
## Increased from implicit 0.1 to provide stronger thermal coupling.
@export var ground_to_air_convection: float = 1.0
## Emissivity for Stefan-Boltzmann radiative cooling [0, 1].
## 1.0 = perfect blackbody; Earth-like ≈ 0.6–0.8 with atmosphere.
@export var emissivity: float = 0.7
## Scaled Stefan-Boltzmann constant for game-scale radiative cooling.
## Real σ = 5.67e-8 W/(m²·K⁴); this is scaled to game temperature/time units.
## When auto_calibrate_stefan = true, this is OVERWRITTEN at sim init by calibrate_stefan_scale()
## to balance solar input vs radiation for the target global mean temp. Set auto_calibrate_stefan = false
## to tune manually. Previous 2.0e-7 was 168× too strong (cooled to 0K in <1s).
@export var stefan_scale: float = 1.0e-9
## Effective space temperature (Kelvin) for radiative equilibrium.
## Real deep space ≈ 2.7 K; higher values reduce night cooling.
@export var T_space: float = 3.0
## Target global mean temperature (°C) for auto-calibration of stefan_scale.
## The calibrate_stefan_scale() function solves the global energy balance equation
## (solar_in = radiation_out) for this target, so the sim settles near this mean.
@export var target_global_mean_temp: float = 15.0
## Estimated average global humidity [0, 1] used by calibrate_stefan_scale().
## Affects cloud albedo (more humidity → more sunlight reflected) and greenhouse (more humidity →
## more radiation retained). If the sim runs consistently too hot/cold after auto-calibration,
## adjust this estimate: higher humidity → slightly less solar but much less radiation → needs higher
## stefan_scale → check the printed value and tune.
@export var estimated_avg_humidity: float = 0.5
## When true, stefan_scale is auto-computed at sim init from the energy balance formula.
## When false, the manually-set stefan_scale @export value is used.
@export var auto_calibrate_stefan: bool = true
## Correction multiplier for systematic biases in the auto-calibration formula (default 0.85).
## The formula has known biases it can't model analytically: canopy shade (reduces solar more than
## cloud albedo alone), air sitting above ground (air radiates more than the formula assumes), and
## humidity estimate uncertainty. Lower = less radiation = warmer. If the sim runs cold, lower this
## (e.g. 0.75); if too hot, raise it (e.g. 0.95).
@export var calibration_correction: float = 0.85

## Auto-calibrates stefan_scale so the global energy balance settles near target_global_mean_temp.
## At equilibrium: solar_in = radiation_out. Solving for stefan_scale:
##   σ = solar_in × correction / [ε × (avg_T⁴ − T_space⁴) × bracket]
## Key correction: avg(T⁴) > (avg T)⁴ by Jensen's inequality (T⁴ is convex, so hot regions radiate
## disproportionately more). Computed analytically assuming a sinusoidal latitude temperature profile:
##   avg(T⁴) = T_mean⁴ + 2·T_mean²·ΔT² + ΔT⁴/5   (ΔT = (equator_temp − pole_temp)/2)
## NOTE: shader constants (AIR_SOLAR_ABSORPTION etc.) are duplicated here — keep in sync with
## thermodynamics_sim.glsl. The /4 factor is the geometric average of sunlight over a sphere.
func calibrate_stefan_scale() -> void:
	# Shader constants — MUST match thermodynamics_sim.glsl const float declarations
	const AIR_SOLAR_ABSORPTION : float = 0.40
	const AIR_RADIATION_FRACTION : float = 0.70
	const CLOUD_ALBEDO_MAX : float = 0.35
	const CLOUD_ALBEDO_RATE : float = 4.0
	const GREENHOUSE_BASE : float = 0.40
	const GREENHOUSE_HUMIDITY_FACTOR : float = 0.40

	var T_target_K : float = target_global_mean_temp + 273.15
	var T_space4 : float = T_space * T_space * T_space * T_space

	# Jensen correction: avg(T⁴) > (avg T)⁴ because T⁴ is convex (hot regions dominate radiation).
	# Assumes a sinusoidal latitude temperature profile: T(θ) = T_mean + ΔT·cos(θ).
	# On a sphere: avg(cos²θ)=1/3, avg(cos⁴θ)=1/5, odd powers vanish.
	# Result: avg(T⁴) = T_mean⁴ + 2·T_mean²·ΔT² + ΔT⁴/5
	var delta_T : float = (equator_temp - pole_temp) * 0.5
	var avg_T4 : float = T_target_K * T_target_K * T_target_K * T_target_K  # (avg T)⁴
	avg_T4 += 2.0 * T_target_K * T_target_K * delta_T * delta_T       # + 2·T²·ΔT²
	avg_T4 += pow(delta_T, 4.0) / 5.0                                  # + ΔT⁴/5
	var jensen_ratio : float = avg_T4 / (T_target_K * T_target_K * T_target_K * T_target_K)

	# Average cloud albedo (saturating exponential, same formula as the shader)
	var avg_cloud_albedo : float = CLOUD_ALBEDO_MAX * (1.0 - exp(-estimated_avg_humidity * CLOUD_ALBEDO_RATE))
	# Average greenhouse factor
	var avg_greenhouse : float = clampf(GREENHOUSE_BASE + estimated_avg_humidity * GREENHOUSE_HUMIDITY_FACTOR, 0.0, 0.95)
	# Radiation bracket: ground-to-space + air-to-space fractions
	var bracket : float = (1.0 - avg_greenhouse) + AIR_RADIATION_FRACTION * (1.0 - avg_greenhouse * 0.5)

	# Average solar absorbed (ground at full rate + air at AIR_SOLAR_ABSORPTION fraction)
	# The /4 is the geometric average of max(0, cos_zenith) over a sphere (day/night + latitudes)
	var avg_sunlight : float = base_solar_power / 4.0
	var solar_in : float = avg_sunlight * (1.0 - avg_cloud_albedo) * solar_heating_rate * (1.0 + AIR_SOLAR_ABSORPTION)

	# Solve for stefan_scale: solar_in = ε × σ × (avg_T⁴ − T_space⁴) × bracket / correction
	# The calibration_correction accounts for remaining biases (canopy shade, air>ground gap, humidity uncertainty)
	stefan_scale = solar_in * calibration_correction / (emissivity * (avg_T4 - T_space4) * bracket)

	print("WorldConfig Auto-calibrated stefan_scale = %.14f (target=%.0f°C, base_solar=%.1f, jensen=%.1f%%, correction=%.2f, solar_in=%.3f, bracket=%.3f)"
		% [stefan_scale, target_global_mean_temp, base_solar_power, (jensen_ratio - 1.0) * 100.0, calibration_correction, solar_in, bracket])

@export_group("Ecology & Succession")
## X = Min grass biomass (e.g. 0.1) to allow shrubs, Y = Max grass biomass (e.g. 0.5) for 100% shrub growth rate.
@export var succ_grass_to_shrub : Vector2 = Vector2(0.1, 0.5)
## X = Min shrub biomass (e.g. 0.1) to allow trees, Y = Max shrub biomass (e.g. 0.5) for 100% tree growth rate.
@export var succ_shrub_to_tree : Vector2 = Vector2(0.1, 0.5)
## X = Shrub biomass where grass starts being shaded out (e.g. 0.1), Y = Max shrub penalty (e.g. 0.5). Penalty multiplier scales to 0.5.
@export var shrub_competition : Vector2 = Vector2(0.1, 0.5)
## X = Tree biomass where understory shading begins (e.g. 0.25), Y = Max tree penalty (e.g. 1.0). Penalty multiplier scales to 0.25.
@export var tree_competition : Vector2 = Vector2(0.25, 1.0)

@export_group("Generation Properties")
## The PRNG seed for deterministic procedural generation.
@export var world_seed : int = 0

## DEPRECATED. Internal vector for the equator's normal direction, derived from planet_rotation_angle.
var planet_rotation_vector: Vector2 = Vector2(0.0, 1.0)


# GLOBALS
## Derived width (chunk_resolution * chunk_grid_x).
var world_width : int
## Derived height (chunk_resolution * chunk_grid_y).
var world_height : int
## Total Eulerian cells in the world (width * height).
var world_size : int
## Derived coarse width (world_width / 8).
var coarse_width : int
## Derived coarse height (world_height / 8).
var coarse_height : int

## Invoked by setgets to automatically recalculate bounding width, height, and total cell size on parameter mutation.
func setup_derived_vars() -> void:
	world_width = chunk_grid_x * chunk_resolution
	world_height = chunk_grid_y * chunk_resolution
	world_size = world_width * world_height
	coarse_width = int(world_width / 8.0)
	coarse_height = int(world_height / 8.0)
