extends RefCounted
class_name BiomeEconomy

## Impact Currency payouts from biome transitions
## (_planning/event_logging_system_plan.md §4.1/§4.2 — Phase 5 final form).
##
## Currency = TierMultiplier(new_biome) x CausationBonus(attribution), awarded
## as an instantaneous lump-sum bounty on FORWARD ecological colonization.
##
## Guardrails (§4.2):
##   1. AFK immunity: currency is edge-triggered on TRANSITION — a settled vent
##      pays nothing.
##   2. Reverse-dispel: Tier(new) <= Tier(old) pays 0 — equal tiers included
##      (the plan's explicit tie resolution: equal-tier transitions pay 0).
##   3. Cycle farming: per-cell diminishing returns — payout scales by
##      0.5^(years since last payout), floored at 0, so repeated place-dispel
##      cycles converge to zero income.
##
## Causation (§4.1): the attribution snapshot rides in the BIOME_TYPE texel's
## upper 24 bits (captured by the GPU at classification time). 1.0x if the
## cell's own bits are non-zero; 0.5x if an orthogonal NEIGHBOR's bits are
## non-zero (free — the diff already owns the full layer copy); 0.0x natural.

signal currency_gained(amount : int, cell : Vector2i, new_biome : int)

## Explicit tier ordering (§4.2 guardrail 3's requirement). Ties pay 0.
##   0 = barren baselines, 1 = pioneer, 2 = advanced, 3 = climax/complex.
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

## Currency per tier (§4.1 TierMultiplier).
const TIER_CURRENCY : PackedInt32Array = [0, 10, 35, 75]

## Diminishing-return half-life in years (§4.2 guardrail 3): payout scales by
## 0.5^(years since the cell's last payout). A forward re-attempt inside the
## SAME year consumes one extra half-life per repeat — 0.5^(years-since) alone
## cannot decay a same-year place-dispel loop (years_since stays 0), and the
## plan's guardrail requires cycle income to converge to zero.
const PAYOUT_HALF_LIFE_YEARS : float = 1.0

## The player's wallet.
var currency : int = 0

## cell_index -> year of last payout (diminishing returns bookkeeping).
var _last_paid_year : Dictionary = {}

## cell_index -> cumulative payout attempts (cycle-farm decay exponent).
var _last_paid_repeats : Dictionary = {}

var _cell_count : int = 0


func bind(cell_count : int) -> void:
	_cell_count = cell_count
	_last_paid_year.clear()
	_last_paid_repeats.clear()


## Processes one transition batch (wired to the snapshot manager's signal).
## `shadow_provider` is a Callable(int) -> int returning the shadow texel for
## neighbor-attribution lookups (§4.1 implementation note: free, the diff owns
## the copy). `world_width`/`world_height` resolve neighbor indices.
func process_batch(transitions : Array, shadow_provider : Callable, world_width : int, world_height : int) -> void:
	for t : BiomeTransitionRecord in transitions:
		var cell_index : int = t.cell_index
		var old_biome : int = t.old_biome
		var new_biome : int = t.new_biome
		var attribution : int = t.attribution_bits

		# §4.2 guardrail 2: no reversion bounty (and equal tiers pay 0).
		# NOTE: a reversal does NOT touch the payout clock — §4.2 tracks the
		# last-PAID year, and only real payouts advance it. Refreshing on
		# dispel would reset the decay curve and re-open the farm loop.
		var tier_old : int = _tier_of(old_biome)
		var tier_new : int = _tier_of(new_biome)
		if tier_new <= tier_old:
			continue

		var base : int = TIER_CURRENCY[tier_new]
		if base <= 0:
			continue

		# §4.1 CausationBonus from the texel bits.
		var causation : float = 0.0
		if attribution != 0:
			causation = 1.0
		else:
			var neighbor_bits : int = _neighbor_attribution(cell_index, shadow_provider, world_width, world_height)
			if neighbor_bits != 0:
				causation = 0.5
		if causation <= 0.0:
			continue  # natural fluctuation pays nothing (§4.2 guardrail 1)

		# §4.2 guardrail 3: per-cell diminishing returns. A cell that has never
		# paid pays in full. The exponent is (years since last payout) + (the
		# cell's cumulative payout-attempt count), so EVERY forward attempt —
		# same-year farm loops AND annual re-colonization churn — compounds
		# the decay monotonically toward zero income (the plan's guardrail).
		# Natural one-time colonization is unaffected (first attempt decays 0
		# half-lives); a cell that flips every year decays as 35, 8, 2, 0...
		var first_attempt : bool = not _last_paid_year.has(cell_index)
		var last_paid : int = _last_paid_year.get(cell_index, GameStateManager.elapsed_years)
		var attempts : int = _last_paid_repeats.get(cell_index, 0)
		var years_since : float = maxf(float(GameStateManager.elapsed_years - last_paid), 0.0)
		var exponent : float = (0.0 if first_attempt else (years_since / PAYOUT_HALF_LIFE_YEARS + 1.0)) + float(attempts)
		var decay : float = pow(0.5, exponent)
		var payout : float = float(base) * causation * decay
		var amount : int = floori(payout)
		_last_paid_year[cell_index] = GameStateManager.elapsed_years
		_last_paid_repeats[cell_index] = attempts + 1
		if amount <= 0:
			continue

		currency += amount
		_last_paid_year[cell_index] = GameStateManager.elapsed_years
		@warning_ignore("integer_division")
		currency_gained.emit(amount, Vector2i(cell_index % world_width, cell_index / world_width), new_biome)


func _tier_of(biome_id : int) -> int:
	if biome_id < 0 or biome_id >= TIERS.size():
		return 0
	return TIERS[biome_id]


## ORs the attribution bits of the cell's 4 orthogonal neighbors from the
## snapshot shadow (§4.1: downstream cascade detection).
func _neighbor_attribution(cell_index : int, shadow_provider : Callable, world_width : int, world_height : int) -> int:
	var x : int = cell_index % world_width
	@warning_ignore("integer_division")
	var y : int = cell_index / world_width
	var bits : int = 0
	var neighbors : Array[int] = [
		y * world_width + ((x + 1) % world_width),
		y * world_width + ((x - 1 + world_width) % world_width),
	]
	if y > 0: neighbors.append((y - 1) * world_width + x)
	if y < world_height - 1: neighbors.append((y + 1) * world_width + x)
	for nidx : int in neighbors:
		var texel : int = shadow_provider.call(nidx)
		bits |= (texel >> Helpers.BIOME_TEXEL_ATTRIBUTION_SHIFT) & 0xFFFFFF
	return bits
