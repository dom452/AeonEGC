## Data resource defining a player-castable globe spell or dispel tool, mirrored
## into the `SpellBook` auxiliary SSBO (Binding 10) for placement spells.
class_name PlayerSpell
extends Resource

## Human-readable display name shown in the spell-selection UI.
@export var spell_name: String = ""

## Short mechanical or flavor description displayed in UI tooltips.
@export var description: String = ""

## Icon texture displayed in the spell-selection UI.
@export var icon: Texture2D

## Casting cost relayed via `action_value` (non-negative for placements, negated for dispels).
@export var cost: int = 0

## Derived slot index (`0..31`) in `SpellbookManager.spells`, encoding cell presence as `1 << slot_index` in `ACTION_KEY`.
var slot_index: int = -1

## Sentinel bitmask (`0xFFFFFFFF`) clearing all 32 spell presence bits on a cell when cast by a whole-cell dispel tool.
const WIPE_ALL : int = 0xFFFFFFFF

## GPU spell effect category consumed by `spell_effects_sim.glsl`.
enum EffectType {
	## Writes `magnitude` into `PLAYER_ACTIONS.SPELL_GEOTHERMAL` as a persistent heat source.
	GEOTHERMAL_SOURCE = 0,
}

## GPU effect category mirrored into the `SpellBook` SSBO at `slot_index`.
@export var effect_type: EffectType = EffectType.GEOTHERMAL_SOURCE

## Effect strength in target-layer float units (for `GEOTHERMAL_SOURCE`, scaled by `atomic_multiplier` into `SPELL_GEOTHERMAL`).
@export var magnitude: float = 0.0

## Area-of-effect radius in grid cells (`0.0` = single target cell).
@export var radius: float = 0.0

## Spell duration in seconds (`-1.0` = permanent while the presence bit remains set).
@export var duration: float = -1.0

## When true, acts as a slotless dispel tool that clears `ACTION_KEY` bits instead of occupying a `SpellBook` SSBO slot.
@export var is_dispel : bool = false

## Specific placement `PlayerSpell` whose bit is cleared by a selective dispel tool; when null, clears all bits (`WIPE_ALL`).
@export var target_spell : PlayerSpell


## Returns the 32-bit `ACTION_KEY` bitmask relayed on click (`1 << slot_index` for placements,
## `1 << target_spell.slot_index` for selective dispels, or `WIPE_ALL` for whole-cell dispels).
func get_action_bit_pattern() -> int:
	# Return the spell's own slot bit when placing a spell.
	if not is_dispel:
		return 1 << slot_index
	# Return the target spell's slot bit for selective dispels, or `WIPE_ALL` to clear all bits.
	if target_spell != null and target_spell.slot_index >= 0:
		return 1 << target_spell.slot_index
	return WIPE_ALL