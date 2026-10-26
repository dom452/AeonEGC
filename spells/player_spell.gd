class_name PlayerSpell
extends Resource

## A data-only resource describing a single spell/ability the player can cast on the globe.
##
## Assigned to `SphereCursorPicker.spell`. When set, a mouse click on the sphere emits the
## `cell_clicked` signal carrying the spell's action bit pattern and cost — which
## `PushConstant_PlayerAction` resources then relay into a PLAYER_ACTIONS compute shader's
## push-constant block for a single dispatch frame.
##
## The actual GPU-side effect (setting/clearing the spell's bit in
## `PLAYER_ACTIONS.ACTION_KEY`) is performed by the PLAYER_ACTIONS compute shader, not by
## this resource.
##
## The full definition (effect_type/magnitude/radius/duration) is mirrored into the
## SpellBook aux SSBO (binding 10) at load by SpellbookManager for spells in its
## `spells` array — see _planning/spell_system_tech_plan.md §2.2/§5. The grid only stores
## presence (ACTION_KEY bitmask); magnitude and behavior live off-grid in the spellbook.
## Dispel tools (is_dispel) are exempt: their action is the bit-clear itself.

## Human-readable display name shown in spell-selection UI.
@export var spell_name: String = ""

## Short flavour / mechanical description for tooltips.
@export var description: String = ""

## Icon used in the spell-selection UI.
@export var icon: Texture2D

## Resource cost of casting this spell (e.g. mana). Relayed to the shader as `action_value`
## (sign only matters there for dispels — see is_dispel).
@export var cost: int = 0

## SLOT INDEX into the SpellBook SSBO (0..31), derived from the spell's position in
## SpellbookManager.spells at load — NOT authored. The ACTION_KEY grid stores one bitmask
## per cell (1u << slot), so 32 slots is the hard capacity of one u32 word. The click
## relay encodes the slot as (1u << slot_index) before sending to the GPU, so the wire
## value 0 unambiguously means "no click this frame". "No spell selected" is represented
## by `SphereCursorPicker.spell == null` (no click is emitted at all).
var slot_index: int = -1

## Bit pattern (1u << slot_index) for this spell's bit in the ACTION_KEY bitmask.
## WIPE_ALL is the dispel sentinel: all 32 bits set (0xFFFFFFFF) — a wipe-all click
## clears every placed spell on the cell. Travels as a negative int32 on the
## push-constant wire; player_actions_sim.glsl reinterprets it as uint.
const WIPE_ALL : int = 0xFFFFFFFF

## Effect enum consumed by spell-effects passes in GLSL. Keep in sync with the
## EFFECT_* constants declared in spell_effects_sim.glsl / the SpellBook docs.
enum EffectType {
	GEOTHERMAL_SOURCE = 0, ## Writes magnitude to PLAYER_ACTIONS.SPELL_GEOTHERMAL (heat source).
}

## Full definition mirrored into the SpellBook SSBO at load. Editing this
## post-load (level-up) re-uploads the affected SSBO slice.
@export var effect_type: EffectType = EffectType.GEOTHERMAL_SOURCE

## Spell magnitude in FLOAT units of the target layer. For GEOTHERMAL_SOURCE this is the
## normalized heating coefficient written to SPELL_GEOTHERMAL (× atomic_multiplier=100 on
## the wire): magnitude 500.0 → 50000 uint, heating ≈ +4.8 °C/s at the default
## geothermal_heating_rate.
@export var magnitude: float = 0.0

## Area-of-effect radius in cells (0 = single cell). Radius > 0 is a future enhancement;
## the current spell-effects pass treats every spell as single-cell.
@export var radius: float = 0.0

## Lifetime in seconds; -1.0 = permanent. Decaying spells are a future enhancement —
## the current spell-effects pass keeps the source active while bit is set.
@export var duration: float = -1.0

## If true, this is a dispel TOOL, not a placed spell: it is excluded from the
## SpellBook SSBO (no slot is consumed) and a click clears presence bits instead of
## setting one. See target_spell for selective vs whole-cell dispel.
@export var is_dispel : bool = false

## For dispel tools: which placed spell's bit gets cleared. If null, the tool clears
## the WHOLE cell (all ACTION_KEY bits). Ignored for placement spells (is_dispel = false).
@export var target_spell : PlayerSpell


## Returns the ACTION_KEY bitmask pattern this spell's click relays on the wire:
##   - Placement spell: 1u << slot_index (the spell's own presence bit).
##   - Selective dispel: the TARGET's bit (we are clearing it, not setting ours).
##   - Dispel-all tool:  WIPE_ALL (0xFFFFFFFF — all bits set).
## The returned int is sign-safe for the int32 push-constant wire (never negative).
func get_action_bit_pattern() -> int:
	if not is_dispel:
		return 1 << slot_index
	if target_spell != null and target_spell.slot_index >= 0:
		return 1 << target_spell.slot_index
	return WIPE_ALL