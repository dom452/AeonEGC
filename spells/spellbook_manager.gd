class_name SpellbookManager
extends Resource

## Owns the ordered registry of PlayerSpell resources and mirrors it into the SpellBook
## aux SSBO (binding 10) at load. A Resource (not RefCounted) so it is savable and its
## spells array is inspectable/editable/configurable in the editor.
##
## DERIVED IDENTITY — the single source of truth for spell identity is ARRAY ORDER:
##   - The position of a spell in `spells` IS its SSBO slot (slot_index 0..31).
##   - The spell's presence bit in the ACTION_KEY grid bitmask is (1u << slot_index).
##   - PlayerSpell.slot_index is written back at load (never authored in .tres files).
## Dispel tools (is_dispel = true) sit OUTSIDE the array: they consume no slot and are
## never mirrored into the SSBO.
##
## CAPACITY: one u32 presence word per cell caps the book at 32 placed spells
## (Helpers.aux_ssbo_counts). When the book outgrows that, add a second bitmask
## sub-layer (ACTION_KEY_EXT) per _planning/spell_system_tech_plan.md §2.3 — slots and
## effect dispatch are orthogonal, so nothing else changes.
##
## SAVE-STABILITY NOTE: saves that store ACTION_KEY bitmasks decode correctly only
## against the same array order. The save system is currently non-functional; when it
## is revived, persisting this resource (or its slot mapping) alongside the bitmask
## restores portability across spellbook edits.
##
## Byte layout (std430, 32-byte stride — MUST stay in sync with
## Helpers.SPELL_DEFINITION_BYTE_SIZE and the SpellDefinition block in the GLSL
## consumers, e.g. spell_effects_sim.glsl):
##   uint  spell_id     @ 0   (== slot_index)
##   uint  effect_type  @ 4
##   float magnitude    @ 8
##   float radius       @ 12
##   float duration     @ 16
##   uint  _pad0        @ 20
##   uint  _pad1        @ 24  (explicit padding keeps the std430 stride at 32)
##   uint  _pad2        @ 28

## The ordered spell registry. Order is identity: array position == SSBO slot ==
## ACTION_KEY bit. Reordering changes what stored bitmasks mean.
## Dispel tools must NOT be added here (they are slotless by design).
@export var spells : Array[PlayerSpell] = [
	preload("res://spells/geothermal_vent_spell.tres"),
]


## Derives slot indices from array order, validates, packs, and uploads the spellbook.
## Safe to call repeatedly (full re-upload). Call once from GameStateManager init.
func load_spellbook() -> void:
	var ws : GpuWorldState = GameStateManager.current_world_state
	if not ws or not ws.aux_ssbo_buffers.has(Helpers.sim_layers.PLAYER_ACTIONS):
		# In headless/no-RD boots GpuWorldState cannot allocate buffers — skip quietly.
		return
	_assign_slots()
	ws.upload_aux_ssbo_data(Helpers.sim_layers.PLAYER_ACTIONS, build_spellbook_bytes())


## Writes slot_index back onto every placed spell (array position order). Pure CPU-side
## state derivation — safe in editor and headless runs.
func _assign_slots() -> void:
	for i : int in spells.size():
		var spell : PlayerSpell = spells[i]
		if spell == null:
			continue
		if spell.is_dispel:
			push_error("SpellbookManager: dispel tool '%s' must not be in the spells array — it consumes no slot. Skipping." % spell.spell_name)
			continue
		spell.slot_index = i


## Packs the spellbook byte array from array order. Pure function (no GpuWorldState
## access) so the layout is unit-testable headlessly.
func build_spellbook_bytes() -> PackedByteArray:
	var count : int = Helpers.aux_ssbo_counts[Helpers.sim_layers.PLAYER_ACTIONS]
	var stride : int = Helpers.SPELL_DEFINITION_BYTE_SIZE
	var data : PackedByteArray = PackedByteArray()
	data.resize(count * stride)
	data.fill(0)

	if spells.size() > count:
		push_error("SpellbookManager: %d spells exceeds the %d-slot capacity of one u32 presence word. The first %d are mirrored; add a second bitmask sub-layer for more." % [spells.size(), count, count])

	for i : int in mini(spells.size(), count):
		var spell : PlayerSpell = spells[i]
		if spell == null or spell.is_dispel:
			continue
		if spell.slot_index != i:
			# build_spellbook_bytes may be called before load_spellbook (tests) —
			# derive on the fly so packing never disagrees with array order.
			spell.slot_index = i

		var base : int = i * stride
		data.encode_u32(base + 0, i)
		data.encode_u32(base + 4, spell.effect_type)
		data.encode_float(base + 8, spell.magnitude)
		data.encode_float(base + 12, spell.radius)
		data.encode_float(base + 16, spell.duration)
		# Offsets 20..28 stay zero (reserved / explicit padding).

	return data


## Re-uploads a single spell's 32-byte slice (level-up path: edit the PlayerSpell,
## then call this with its slot). No-op if the world state is unavailable.
func upload_spell_slice(slot : int) -> void:
	var ws : GpuWorldState = GameStateManager.current_world_state
	if not ws or not ws.aux_ssbo_buffers.has(Helpers.sim_layers.PLAYER_ACTIONS):
		push_error("SpellbookManager: no aux SSBO buffer — cannot upload spell slice.")
		return
	if slot < 0 or slot >= spells.size():
		push_error("SpellbookManager: slot %d out of range (0..%d)." % [slot, spells.size() - 1])
		return

	var spell : PlayerSpell = spells[slot]
	if spell == null:
		return

	var stride : int = Helpers.SPELL_DEFINITION_BYTE_SIZE
	var data : PackedByteArray = PackedByteArray()
	data.resize(stride)
	data.fill(0)
	data.encode_u32(0, slot)
	data.encode_u32(4, spell.effect_type)
	data.encode_float(8, spell.magnitude)
	data.encode_float(12, spell.radius)
	data.encode_float(16, spell.duration)
	ws.upload_aux_ssbo_region(Helpers.sim_layers.PLAYER_ACTIONS, data, slot * stride)
