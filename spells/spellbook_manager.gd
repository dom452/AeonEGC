## Owns the ordered registry of placement `PlayerSpell` resources, assigns their
## `slot_index` (`0..31`), and packs/uploads their 32-byte `std430` `SpellDefinition`
## structs into the `SpellBook` auxiliary SSBO (Binding 10).
class_name SpellbookManager
extends Resource

## Ordered array of placement `PlayerSpell` resources where array index equals SSBO slot (`0..31`)
## and `ACTION_KEY` bit position (`1 << slot_index`); slotless dispel tools must not be added here.
@export var spells : Array[PlayerSpell] = [
	preload("res://spells/geothermal_vent_spell.tres"),
]


## Assigns `slot_index` from array order and uploads the packed `SpellBook` byte buffer to `GpuWorldState`.
func load_spellbook() -> void:
	# Skip upload when running headlessly without an allocated GPU auxiliary SSBO.
	var ws : GpuWorldState = GameStateManager.current_world_state
	if not ws or not ws.aux_ssbo_buffers.has(Helpers.sim_layers.PLAYER_ACTIONS):
		return
	_assign_slots()
	ws.upload_aux_ssbo_data(Helpers.sim_layers.PLAYER_ACTIONS, build_spellbook_bytes())


## Writes each placement spell's array index into its `slot_index` property, logging an error if a dispel tool is present.
func _assign_slots() -> void:
	# Assign `slot_index = i` for every valid placement spell in `spells`.
	for i : int in spells.size():
		var spell : PlayerSpell = spells[i]
		if spell == null:
			continue
		if spell.is_dispel:
			push_error("SpellbookManager: dispel tool '%s' must not be in the spells array — it consumes no slot. Skipping." % spell.spell_name)
			continue
		spell.slot_index = i


## Packs up to 32 `spells` into a 1024-byte (`32 * 32 B`) `std430` `PackedByteArray` matching `SpellDefinition`.
func build_spellbook_bytes() -> PackedByteArray:
	var count : int = Helpers.aux_ssbo_counts[Helpers.sim_layers.PLAYER_ACTIONS]
	var stride : int = Helpers.SPELL_DEFINITION_BYTE_SIZE
	var data : PackedByteArray = PackedByteArray()
	data.resize(count * stride)
	data.fill(0)

	# Warn if `spells` exceeds the 32-bit capacity of a single `r32ui` `ACTION_KEY` word.
	if spells.size() > count:
		push_error("SpellbookManager: %d spells exceeds the %d-slot capacity of one u32 presence word. The first %d are mirrored; add a second bitmask sub-layer for more." % [spells.size(), count, count])

	# Encode `[spell_id, effect_type, magnitude, radius, duration, _pad0, _pad1, _pad2]` at 32-byte stride.
	for i : int in mini(spells.size(), count):
		var spell : PlayerSpell = spells[i]
		if spell == null or spell.is_dispel:
			continue
		if spell.slot_index != i:
			spell.slot_index = i

		var base : int = i * stride
		data.encode_u32(base + 0, i)
		data.encode_u32(base + 4, spell.effect_type)
		data.encode_float(base + 8, spell.magnitude)
		data.encode_float(base + 12, spell.radius)
		data.encode_float(base + 16, spell.duration)

	return data


## Re-packs and uploads a single 32-byte `SpellDefinition` slice at `slot` in the `SpellBook` SSBO after runtime edits.
func upload_spell_slice(slot : int) -> void:
	# Validate that the GPU auxiliary SSBO exists and `slot` is within `spells` bounds.
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

	# Encode the 32-byte `SpellDefinition` record and upload it to `slot * stride` in Binding 10.
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
