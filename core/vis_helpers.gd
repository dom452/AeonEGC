## Computes `[min, max]` normalization bounds, scales, and offsets for visualizing
## fine float, atomic, and coarse simulation layers in debug and terrain shaders.
class_name VisHelpers
extends RefCounted


## Returns `Vector2(min_val, max_val)` in physical/domain units for a fine float or atomic layer index.
static func get_layer_min_max(absolute_layer_index: int, is_atomic: bool = false) -> Vector2:
	# Resolve the owning `sim_layers` enum and sub-layer offset from the flat texture array index.
	var found_layer : Helpers.sim_layers = Helpers.sim_layers.INVALID
	var found_sub_layer : int = -1
	
	var target_map : Dictionary = GameStateManager.atomic_layer_to_indices_map if is_atomic else GameStateManager.float_layer_to_indices_map
	
	for sim_layer : Helpers.sim_layers in target_map.keys():
		var indices : PackedInt32Array = target_map[sim_layer]
		var idx_pos : int = indices.find(absolute_layer_index)
		if idx_pos != -1:
			found_layer = sim_layer
			found_sub_layer = idx_pos
			break
			
	var min_val : float = 0.0
	var max_val : float = 1.0
	
	# Read temperature extremes from the active WorldConfig for thermal layer normalization.
	var wc : WorldConfig = GameStateManager.world_config
	var p_temp : float = wc.pole_temp if wc else -30.0
	var e_temp : float = wc.equator_temp if wc else 40.0
	var min_temp : float = min(p_temp, e_temp)
	var max_temp : float = max(p_temp, e_temp)
	
	# Select normalization bounds for atomic sub-layers (after multiplier division in the visualizer pass).
	if is_atomic:
		match found_layer:
			Helpers.sim_layers.WATER:
				match found_sub_layer:
					0: # LIQUID_VOLUME (depth in hectometers)
						max_val = wc.max_elevation if wc else 200.0
					1: # ICE_VOLUME (depth in hectometers, up to 2x thermal insulation cap)
						max_val = wc.thermal_ice_influence * 2.0 if wc else 0.1
			Helpers.sim_layers.FLORA:
				match found_sub_layer:
					0: # GRASSES (carrying capacity K = 1.0)
						max_val = 1.0
					1: # SHRUBS (carrying capacity K = 3.0)
						max_val = 3.0
					2: # TREES_CANOPY (carrying capacity K = 5.0)
						max_val = 5.0
					3: # AQUATIC (carrying capacity K = 2.0)
						max_val = 2.0
					4: # FLORA_DETRITUS
						max_val = 1.0
			Helpers.sim_layers.LANDSCAPE:
				match found_sub_layer:
					1: # SOIL_NUTRIENTS
						max_val = 5.0
					3: # BIOME_TYPE (low byte decoded against 0..255)
						max_val = float(Helpers.BIOME_UNCLASSIFIED)
	# Select normalization bounds for fine float sub-layers.
	else:
		match found_layer:
			Helpers.sim_layers.LANDSCAPE:
				match found_sub_layer:
					0: # BEDROCK_HEIGHT (hectometers)
						max_val = wc.max_elevation if wc else 200.0
					3: # SEDIMENT_HEIGHT (hectometers)
						max_val = wc.max_sediment_depth if wc else 1.0
					1, 2: # SLOPE.X, SLOPE.Y
						min_val = -1.0
						max_val = 1.0
					4: # GROUND_TEMP (degrees Celsius)
						min_val = min_temp
						max_val = max_temp
			Helpers.sim_layers.WATER:
				match found_sub_layer:
					0: # WATER_LIQUID_HEIGHT (hectometers; deep basins can approach max_elevation)
						max_val = wc.max_elevation if wc else 200.0
					1: # WATER_ICE_HEIGHT (hectometers; up to 2x thermal insulation cap)
						max_val = wc.thermal_ice_influence * 2.0 if wc else 0.1
					2, 3: # NET_VELOCITY.X, NET_VELOCITY.Y
						var max_flow : float = wc.max_flow_rate if wc else 1.0
						min_val = -max_flow
						max_val = max_flow
					4: # DIVERGENCE
						var max_flow : float = wc.max_flow_rate if wc else 1.0
						min_val = -max_flow
						max_val = max_flow
					5: # TURBULENCE
						var max_flow : float = wc.max_flow_rate if wc else 1.0
						min_val = 0.0
						max_val = max_flow
					6: # WATER_TEMP (degrees Celsius)
						min_val = min_temp
						max_val = max_temp
			Helpers.sim_layers.ENERGY:
				match found_sub_layer:
					0: # SUNLIGHT (normalized insolation [0, 1])
						max_val = 1.0
					1: # TIDAL_FORCE (dimensionless [-1, 1])
						min_val = -1.0
						max_val = 1.0
			Helpers.sim_layers.ATMOSPHERE:
				match found_sub_layer:
					0, 1: # WIND.X, WIND.Y (SWE horizontal velocity in grid-cells/frame)
						min_val = -2.0
						max_val = 2.0 
					2: # AIR_TEMP (degrees Celsius)
						min_val = min_temp
						max_val = max_temp
					3, 4, 5: # HUMIDITY, RAIN, SNOW
						max_val = 1.0
					6: # PRESSURE (SWE column height h; ~1.0 at rest)
						min_val = 0.0
						max_val = 3.0
			Helpers.sim_layers.FLORA:
				match found_sub_layer:
					0, 1: # GROWTH_RATE_MODIFIER, CANOPY_SHADE
						max_val = 1.0
						
	return Vector2(min_val, max_val)


## Returns the multiplicative scale factor `1.0 / (max - min)` that maps a fine layer's range to `[0, 1]`.
static func get_scale_for_layer(absolute_layer_index: int, is_atomic: bool = false) -> float:
	var bounds : Vector2 = get_layer_min_max(absolute_layer_index, is_atomic)
	var range_val : float = bounds.y - bounds.x
	if range_val == 0.0: return 1.0
	return 1.0 / range_val


## Returns the additive offset `-min` applied before scaling to normalize a fine layer to `[0, 1]`.
static func get_offset_for_layer(absolute_layer_index: int, is_atomic: bool = false) -> float:
	var bounds : Vector2 = get_layer_min_max(absolute_layer_index, is_atomic)
	return -bounds.x


## Returns `Vector2(min_val, max_val)` in physical/domain units for a coarse dynamics grid layer (`Helpers.coarse_layers`).
static func get_coarse_layer_min_max(coarse_layer_idx: int) -> Vector2:
	# Read temperature and elevation bounds from the active WorldConfig.
	var wc : WorldConfig = GameStateManager.world_config
	var p_temp : float = wc.pole_temp if wc else -30.0
	var e_temp : float = wc.equator_temp if wc else 40.0
	var min_temp : float = min(p_temp, e_temp)
	var max_temp : float = max(p_temp, e_temp)
	var max_elev : float = wc.max_elevation if wc else 200.0

	# Return the expected display range for the requested coarse SWE layer.
	match coarse_layer_idx:
		Helpers.coarse_layers.H_UPPER:
			return Vector2(0.0, 2.0)
		Helpers.coarse_layers.WIND_UPPER_X, Helpers.coarse_layers.WIND_UPPER_Y:
			return Vector2(-3.0, 3.0)
		Helpers.coarse_layers.H_LOWER:
			return Vector2(0.0, 2.0)
		Helpers.coarse_layers.WIND_LOWER_X, Helpers.coarse_layers.WIND_LOWER_Y:
			return Vector2(-2.0, 2.0)
		Helpers.coarse_layers.AIR_TEMP:
			return Vector2(min_temp, max_temp)
		Helpers.coarse_layers.TERRAIN:
			return Vector2(0.0, max_elev)
		Helpers.coarse_layers.ROUGHNESS:
			return Vector2(0.0, 30.0)
	return Vector2(0.0, 1.0)


## Returns the multiplicative scale factor `1.0 / (max - min)` that maps a coarse layer's range to `[0, 1]`.
static func get_coarse_scale_for_layer(coarse_layer_idx: int) -> float:
	var bounds : Vector2 = get_coarse_layer_min_max(coarse_layer_idx)
	var range_val : float = bounds.y - bounds.x
	if range_val == 0.0: return 1.0
	return 1.0 / range_val


## Returns the additive offset `-min` applied before scaling to normalize a coarse layer to `[0, 1]`.
static func get_coarse_offset_for_layer(coarse_layer_idx: int) -> float:
	var bounds : Vector2 = get_coarse_layer_min_max(coarse_layer_idx)
	return -bounds.x
