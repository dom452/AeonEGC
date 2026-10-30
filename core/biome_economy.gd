extends RefCounted
## Awards diminishing-return Impact Currency bounties when player-attributed or
## neighbor-cascaded cells transition to a strictly higher ecological biome tier.
class_name BiomeEconomy

## Emitted when a cell transition awards a positive Impact Currency payout.
signal currency_gained(amount : int, cell : Vector2i, new_biome : int)

## Ecological succession tier (0 = barren, 1 = pioneer, 2 = advanced, 3 = climax)
## indexed by biome ID (0..17). Equal or lower tier transitions pay 0.
const TIERS : PackedInt32Array = [
	0,  # 0  Glacial Ice Sheet      — barren
	1,  # 1  Polar Tundra           — pioneer
	2,  # 2  Boreal Taiga           — advanced
	1,  # 3  Alpine Meadow          — pioneer
	2,  # 4  Temperate Forest       — advanced
	1,  # 5  Temperate Grassland    — pioneer
	2,  # 6  Temperate Rainforest   — advanced
	1,  # 7  Mediterranean Scrub    — pioneer
	0,  # 8  Subtropical Desert     — barren
	2,  # 9  Semi-Arid Savanna      — advanced
	3,  # 10 Tropical Rainforest    — climax
	3,  # 11 Thermal Oasis          — climax
	3,  # 12 Freshwater Wetland     — climax
	3,  # 13 Mangrove Estuary       — climax
	1,  # 14 Freshwater Lake        — pioneer
	0,  # 15 Sea Ice / Frozen Sea   — barren
	1,  # 16 Shallow Coastal Shelf  — pioneer
	1,  # 17 Pelagic Deep Ocean     — pioneer
]

## Base Impact Currency bounty indexed by succession tier (0..3).
const TIER_CURRENCY : PackedInt32Array = [0, 10, 35, 75]

## Half-life in elapsed simulation years for per-cell repeat payout decay.
const PAYOUT_HALF_LIFE_YEARS : float = 1.0

## Current total Impact Currency held in the player's wallet.
var currency : int = 0

## Maps flat `cell_index` to the simulation year of its most recent payout.
var _last_paid_year : Dictionary[int, int] = {}

## Maps flat `cell_index` to its cumulative forward payout-attempt count.
var _last_paid_repeats : Dictionary[int, int] = {}

## Total cell count of the bound simulation grid.
var _cell_count : int = 0


## Initializes the economy tracker for a grid of `cell_count` cells and resets
## per-cell payout decay history.
func bind(cell_count : int) -> void:
	# Store the active grid size and clear prior cell payout records.
	_cell_count = cell_count
	_last_paid_year.clear()
	_last_paid_repeats.clear()


## Evaluates a batch of `BiomeTransitionRecord`s, awarding diminishing-return
## Impact Currency for player-caused or neighbor-cascaded upgrades to a higher
## biome tier and emitting `currency_gained` for each positive payout.
func process_batch(transitions : Array, shadow_provider : Callable, world_width : int, world_height : int) -> void:
	for t : BiomeTransitionRecord in transitions:
		var cell_index : int = t.cell_index
		var old_biome : int = t.old_biome
		var new_biome : int = t.new_biome
		var attribution : int = t.attribution_bits

		# Skip reversions and lateral equal-tier transitions without advancing the cell's decay clock.
		var tier_old : int = _tier_of(old_biome)
		var tier_new : int = _tier_of(new_biome)
		if tier_new <= tier_old:
			continue

		# Skip target tiers that carry zero base bounty.
		var base : int = TIER_CURRENCY[tier_new]
		if base <= 0:
			continue

		# Assign 1.0x causation for direct cell attribution, 0.5x for orthogonal neighbor cascade, or 0.0x for natural shifts.
		var causation : float = 0.0
		if attribution != 0:
			causation = 1.0
		else:
			var neighbor_bits : int = _neighbor_attribution(cell_index, shadow_provider, world_width, world_height)
			if neighbor_bits != 0:
				causation = 0.5
		if causation <= 0.0:
			continue

		# Look up the cell's prior payout history; first-time colonizations suffer zero decay.
		var first_attempt : bool = not _last_paid_year.has(cell_index)
		var last_paid : int = _last_paid_year.get(cell_index, GameStateManager.elapsed_years)
		var attempts : int = _last_paid_repeats.get(cell_index, 0)
		var years_since : float = maxf(float(GameStateManager.elapsed_years - last_paid), 0.0)

		# Compound half-life decay across both elapsed years and cumulative attempts so
		# same-year place-dispel loops and annual re-colonization churn both decay to zero.
		var exponent : float = (0.0 if first_attempt else (years_since / PAYOUT_HALF_LIFE_YEARS + 1.0)) + float(attempts)
		var decay : float = pow(0.5, exponent)
		var amount : int = floori(float(base) * causation * decay)

		# Record the payout attempt on the cell's decay clock before checking if the floored payout reached zero.
		_last_paid_year[cell_index] = GameStateManager.elapsed_years
		_last_paid_repeats[cell_index] = attempts + 1
		if amount <= 0:
			continue

		# Credit the player's wallet and notify listeners of the cell's payout.
		currency += amount
		@warning_ignore("integer_division")
		currency_gained.emit(amount, Vector2i(cell_index % world_width, cell_index / world_width), new_biome)


## Returns the ecological succession tier (0 = barren .. 3 = climax) for `biome_id`,
## or 0 if the ID is out of range.
func _tier_of(biome_id : int) -> int:
	# Guard against out-of-range biome IDs.
	if biome_id < 0 or biome_id >= TIERS.size():
		return 0
	return TIERS[biome_id]


## Returns the bitwise OR of the 24-bit spell-attribution masks across the 4
## orthogonal neighbors of `cell_index` (with East-West wrapping and clamped poles).
func _neighbor_attribution(cell_index : int, shadow_provider : Callable, world_width : int, world_height : int) -> int:
	# Convert flat cell index to 2D grid coordinates.
	var x : int = cell_index % world_width
	@warning_ignore("integer_division")
	var y : int = cell_index / world_width
	var bits : int = 0
	# Collect East/West wrapped neighbors and North/South pole-clamped neighbors.
	var neighbors : Array[int] = [
		y * world_width + ((x + 1) % world_width),
		y * world_width + ((x - 1 + world_width) % world_width),
	]
	if y > 0: neighbors.append((y - 1) * world_width + x)
	if y < world_height - 1: neighbors.append((y + 1) * world_width + x)
	# Unpack and accumulate the upper 24-bit spell attribution mask from each neighbor texel.
	for nidx : int in neighbors:
		var texel : int = shadow_provider.call(nidx)
		bits |= (texel >> Helpers.BIOME_TEXEL_ATTRIBUTION_SHIFT) & 0xFFFFFF
	return bits
