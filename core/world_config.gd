extends Resource
## Authoritative configuration resource defining grid dimensions, physical scale
## constants, atomic multipliers, climate/SWE parameters, and compute pass arrays.
class_name WorldConfig

## Pixel resolution of a single terrain chunk along each axis (e.g., 512).
@export var chunk_resolution : int:
	set(value):
		chunk_resolution = value
		setup_derived_vars()
## Number of terrain chunks along the X (longitude) axis.
@export var chunk_grid_x : int:
	set(value): 
		chunk_grid_x = value
		setup_derived_vars()
## Number of terrain chunks along the Y (latitude) axis.
@export var chunk_grid_y : int:
	set(value):
		chunk_grid_y = value
		setup_derived_vars()

## When true, halts simulation execution immediately after world generation completes.
@export var stop_after_bootstrap : bool = true

## Ordered array of runtime `LayerSimulator` compute passes dispatched each simulation step.
@export var sim_layers : Array[LayerSimulator]
## Ordered array of `LayerGenerator` compute passes dispatched during initial world creation.
@export var layer_generators : Array[LayerGenerator]

@export_group("Scale & Geometry")
## Maximum terrain elevation in Height-Units (Hectometers: `1.0 = 100 m`, `200.0 = 20,000 m`),
## shared with `SEDIMENT_HEIGHT`, `WATER_LIQUID_HEIGHT`, and `WATER_ICE_HEIGHT`.
@export var max_elevation: float = 200.0
## Maximum sediment depth in Height-Units (`1.0 = 100 m`) accumulated via hydraulic erosion.
@export var max_sediment_depth: float = 1.0
## Fixed-point `r32ui` multiplier (`100.0`: `1 uint = 0.01` float units / `1 m` depth) for
## `WATER`, `LANDSCAPE`, `ENERGY`, `ATMOSPHERE`, and `FAUNA` atomic layers.
@export var atomic_multiplier: float = 100.0
## High-precision fixed-point `r32ui` multiplier (`1,000,000.0`) used exclusively by `FLORA`
## atomic layers so small per-frame logistic growth deltas do not truncate to zero.
@export var flora_atomic_multiplier: float = 1000000.0
## Planetary diameter in kilometers (default `12,742 km` → ~78 km equatorial cell width at 512×512),
## used on CPU to compute physical cell and region surface areas.
@export var planetary_diameter: float = 12742.0
## Maximum number of full simulation pipeline dispatches executed per rendered frame at the fixed 60 Hz timestep.
@export var max_sim_speed : int = 4


@export_group("Orbital & Solar")
## Number of simulated days in one full seasonal orbital cycle.
@export var days_per_year: float = 360.0
## Maximum planetary axial tilt in radians governing seasonal insolation swings (`0.409 ≈ 23.5°`).
@export var max_axial_tilt: float = 0.409
## Initial orbital season phase angle in radians (`0.0..TAU`) at world creation.
@export var initial_season_phase: float = 0.0
## Normalized peak solar insolation multiplier at the subsolar zenith (`1.0 = 100%`).
@export var base_solar_power: float = 1.0

@export_group("Climate & Temperature")
## Baseline mean sea-level temperature in degrees Celsius at the equator.
@export var equator_temp: float = 35.0
## Baseline mean temperature in degrees Celsius at the poles.
@export var pole_temp: float = -35.0
## Thermal coupling weight (`[0, 1]`) blending ground and air temperatures.
@export var ground_mix_factor: float = 0.4
## Environmental temperature drop in degrees Celsius from sea level to `max_elevation`.
@export var lapse_rate: float = 15.0

@export_group("Atmosphere & Wind")
## Global multiplier scaling planetary Coriolis deflection on horizontal wind vectors.
@export var coriolis_strength: float = 0.75
## Per-step velocity retention factor (`[0, 1]`) for surface wind drag.
@export var wind_friction: float = 0.98
## Multiplier scaling horizontal wind velocity during semi-Lagrangian humidity advection.
@export var wind_advection_scale: float = 1.0

## Reference sea-level pressure anomaly in normalized units (`0.0 = 1013.25 hPa`).
@export var base_pressure_sea_level: float = 0.0
## Amplitude of latitudinal Hadley/Ferrel/Polar circulation pressure bands in normalized units.
@export var latitude_pressure_amp: float = 0.08
## Hydrostatic pressure drop per unit of terrain height in normalized pressure units.
@export var altitude_lapse_rate: float = 0.00012
## Thermal-to-pressure coupling coefficient (negative so warm air lowers local surface pressure).
@export var thermal_pressure_coef: float = -0.003

## Gravitational acceleration `g` for the fine-grid Shallow Water Equations (SWE) pressure-wind solver.
@export var swe_gravity: float = 0.25
## Reference atmospheric column height `h0` at rest (`1.0` normalized) for the fine-grid SWE solver.
@export var swe_reference_height: float = 1.0
## Thermal expansion coefficient scaling SWE column height forcing per degree from `swe_global_mean_temp`.
@export var swe_thermal_alpha: float = 0.15
## Reference global mean temperature in degrees Celsius for SWE thermal mass forcing.
@export var swe_global_mean_temp: float = 15.0
## Linear per-second wind friction rate (`exp(-friction * dt)`) controlling cross-isobar Ekman flow in SWE.
@export var swe_wind_friction: float = 0.03
## Relaxation rate pulling SWE column height `h` toward thermal equilibrium.
@export var swe_relax_strength: float = 12.0

@export_group("Coarse Dynamics")
## Pixel resolution of the coarse atmospheric dynamics grid along each axis (`64 = 1/8` of `512`).
@export var coarse_resolution: int = 64
## Gravitational acceleration `g` for the two-layer coarse SWE solver, tuned for CFL stability at 60 Hz.
@export var coarse_swe_gravity: float = 5.0
## Column-height relaxation rate bounding `h` in the coarse SWE solver.
@export var coarse_swe_relax_strength: float = 10.0
## Boundary-layer drag coefficient scaling lower-layer wind friction by sub-grid terrain roughness.
@export var coarse_orographic_drag: float = 0.15
## Density ratio (`rho_upper / rho_lower`) coupling the upper and lower atmospheric layers in coarse SWE.
@export var coarse_density_ratio: float = 0.7

@export_group("Water & Ice")
## Initial ocean depth as a fraction of `max_elevation` (`initial_depth = max_elevation * sea_level_ratio`).
@export var sea_level_ratio: float = 0.0135
## Maximum volumetric water transfer rate per simulation step in normalized flow units.
@export var max_flow_rate: float = 1.0
## Temperature in degrees Celsius below which liquid water begins freezing into ice.
@export var freeze_threshold: float = -2.0
## Temperature in degrees Celsius at which all remaining liquid water freezes solid in a single step.
@export var total_freeze_temp: float = -400.0
## Exponent shaping the freezing curve between `freeze_threshold` and `total_freeze_temp`.
@export var total_freeze_curve: float = 0.04
## Maximum ice sheet thickness cap in Height-Units (`0.04 = 4 m`).
@export var max_ice_thickness: float = 0.04
## Ice depth in Height-Units (`0.05 = 5 m`) at which ice fully insulates ground from air heat exchange.
@export var thermal_ice_influence: float = 0.05
## Fraction of surface liquid water evaporated into atmospheric humidity per frame when above freezing.
@export var evaporation_rate: float = 0.05
## Fraction of excess atmospheric humidity condensed into rain or snow precipitation per frame.
@export var precipitation_rate: float = 0.05
## Game-scale thermal energy coefficient exchanged during liquid-vapor evaporation and condensation.
@export var latent_heat_vaporization: float = 10.0
## Per-frame water depth injected at `ARTESIAN_SOURCES` cells in atomic uint units (`÷ atomic_multiplier` for Height-Units).
@export var artesian_flow_rate: float = 0.01
## Fraction of `SOIL_NUTRIENTS` entrained and transported by surface water runoff per frame (`[0, 1]`).
@export var nutrient_erosion_rate: float = 0.05
## Peak-to-trough tidal surface elevation offset in Height-Units (`0.1 = 10 m`).
@export var tidal_amplitude: float = 0.1

@export_group("Thermodynamics")
## Per-frame conductive heat transfer rate (`[0, 1]`) between ground, water, and air layers.
@export var heat_transfer_rate: float = 0.40
## Lateral thermal diffusion rate (`[0, 1]`) across adjacent grid cells.
@export var thermal_diffusion_rate: float = 0.5
## Game-scale latent heat energy coefficient for liquid-ice phase transitions.
@export var latent_heat_capacity: float = 10.0
## Heating rate multiplier converting normalized `SUNLIGHT` (`[0, 1]`) into ground temperature gain.
@export var solar_heating_rate: float = 24.0
## Heating rate multiplier converting normalized `GEOTHERMAL` energy into ground temperature gain (`°C/frame`).
@export var geothermal_heating_rate: float = 0.01
## Convective coupling multiplier scaling upward heat transfer from ground to air.
@export var ground_to_air_convection: float = 1.0
## Surface radiative emissivity (`[0, 1]`) for Stefan-Boltzmann outgoing longwave cooling.
@export var emissivity: float = 0.7
## Game-scale Stefan-Boltzmann radiative cooling constant (`σ`), overwritten at init when `auto_calibrate_stefan` is true.
@export var stefan_scale: float = 1.0e-9
## Effective deep-space background temperature in Kelvin (`K`) for radiative cooling equilibrium.
@export var T_space: float = 3.0
## Target global mean surface temperature in degrees Celsius solved for by `calibrate_stefan_scale()`.
@export var target_global_mean_temp: float = 15.0
## Assumed global mean humidity (`[0, 1]`) used by `calibrate_stefan_scale()` to estimate cloud albedo and greenhouse retention.
@export var estimated_avg_humidity: float = 0.5
## When true, recomputes `stefan_scale` at startup via `calibrate_stefan_scale()` to match `target_global_mean_temp`.
@export var auto_calibrate_stefan: bool = true
## Empirical correction factor applied in `calibrate_stefan_scale()` to account for canopy shade and vertical air-ground offset.
@export var calibration_correction: float = 0.85


## Solves the global radiative energy balance (`solar_in = radiation_out`) with Jensen's `T^4` latitude
## correction and updates `stefan_scale` so global mean temperature settles near `target_global_mean_temp`.
func calibrate_stefan_scale() -> void:
	# Mirror the atmospheric absorption, cloud albedo, and greenhouse constants from `thermodynamics_sim.glsl`.
	const AIR_SOLAR_ABSORPTION : float = 0.40
	const AIR_RADIATION_FRACTION : float = 0.70
	const CLOUD_ALBEDO_MAX : float = 0.35
	const CLOUD_ALBEDO_RATE : float = 4.0
	const GREENHOUSE_BASE : float = 0.40
	const GREENHOUSE_HUMIDITY_FACTOR : float = 0.40

	# Convert target temperature to Kelvin and compute deep-space `T^4` baseline.
	var T_target_K : float = target_global_mean_temp + 273.15
	var T_space4 : float = T_space * T_space * T_space * T_space

	# Apply Jensen's inequality (`avg(T^4) = T_mean^4 + 2*T_mean^2*dT^2 + dT^4/5`) for a sinusoidal latitude profile.
	var delta_T : float = (equator_temp - pole_temp) * 0.5
	var avg_T4 : float = T_target_K * T_target_K * T_target_K * T_target_K
	avg_T4 += 2.0 * T_target_K * T_target_K * delta_T * delta_T
	avg_T4 += pow(delta_T, 4.0) / 5.0
	var jensen_ratio : float = avg_T4 / (T_target_K * T_target_K * T_target_K * T_target_K)

	# Compute mean cloud albedo, greenhouse retention, and the net outgoing radiation bracket.
	var avg_cloud_albedo : float = CLOUD_ALBEDO_MAX * (1.0 - exp(-estimated_avg_humidity * CLOUD_ALBEDO_RATE))
	var avg_greenhouse : float = clampf(GREENHOUSE_BASE + estimated_avg_humidity * GREENHOUSE_HUMIDITY_FACTOR, 0.0, 0.95)
	var bracket : float = (1.0 - avg_greenhouse) + AIR_RADIATION_FRACTION * (1.0 - avg_greenhouse * 0.5)

	# Compute spherical-mean absorbed solar flux (`base_solar_power / 4.0` across day/night and latitudes).
	var avg_sunlight : float = base_solar_power / 4.0
	var solar_in : float = avg_sunlight * (1.0 - avg_cloud_albedo) * solar_heating_rate * (1.0 + AIR_SOLAR_ABSORPTION)

	# Solve `solar_in = emissivity * stefan_scale * (avg_T4 - T_space4) * bracket / calibration_correction`.
	stefan_scale = solar_in * calibration_correction / (emissivity * (avg_T4 - T_space4) * bracket)

	print("WorldConfig Auto-calibrated stefan_scale = %.14f (target=%.0f°C, base_solar=%.1f, jensen=%.1f%%, correction=%.2f, solar_in=%.3f, bracket=%.3f)"
		% [stefan_scale, target_global_mean_temp, base_solar_power, (jensen_ratio - 1.0) * 100.0, calibration_correction, solar_in, bracket])

@export_group("Ecology & Succession")
## Grass biomass ramp `Vector2(min_threshold, full_rate_biomass)` enabling shrub succession.
@export var succ_grass_to_shrub : Vector2 = Vector2(0.1, 0.5)
## Shrub biomass ramp `Vector2(min_threshold, full_rate_biomass)` enabling tree canopy succession.
@export var succ_shrub_to_tree : Vector2 = Vector2(0.1, 0.5)
## Shrub shading competition `Vector2(onset_biomass, max_penalty_biomass)` suppressing grass growth.
@export var shrub_competition : Vector2 = Vector2(0.1, 0.5)
## Tree canopy shading competition `Vector2(onset_biomass, max_penalty_biomass)` suppressing understory growth.
@export var tree_competition : Vector2 = Vector2(0.25, 1.0)

@export_group("Generation Properties")
## Deterministic PRNG seed used by procedural noise and world generation passes.
@export var world_seed : int = 0

## Normalized 2D equatorial rotation direction vector.
var planet_rotation_vector: Vector2 = Vector2(0.0, 1.0)


## Total fine-grid width in texels (`chunk_resolution * chunk_grid_x`).
var world_width : int
## Total fine-grid height in texels (`chunk_resolution * chunk_grid_y`).
var world_height : int
## Total number of fine-grid cells (`world_width * world_height`).
var world_size : int
## Derived coarse-grid width in texels (`world_width / 8`).
var coarse_width : int
## Derived coarse-grid height in texels (`world_height / 8`).
var coarse_height : int


## Recomputes `world_width`, `world_height`, `world_size`, `coarse_width`, and `coarse_height` when chunk dimensions change.
func setup_derived_vars() -> void:
	# Multiply chunk counts by chunk resolution and derive 1/8th coarse grid dimensions.
	world_width = chunk_grid_x * chunk_resolution
	world_height = chunk_grid_y * chunk_resolution
	world_size = world_width * world_height
	coarse_width = int(world_width / 8.0)
	coarse_height = int(world_height / 8.0)
