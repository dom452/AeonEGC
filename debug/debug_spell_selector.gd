extends Node
class_name DebugSpellSelector

## POC debug spell selector: hotkeys assign spells to GameStateManager.cursor_picker,
## and print the current selection to the console. Exists only so the geothermal-vent
## POC tests (T-S2..T-S6) are executable without a full spell-selection UI
## (spell_system_tech_plan.md Phase D).
##
## Hotkeys (number row): 1..9 select placed spells from the ACTIVE SPELLBOOK
## (GameStateManager.spellbook_manager.spells — the single source of truth, so the
## hotkey order always matches SSBO slot order). X selects the dispel tool (clears the
## whole cell). Q clears the selection.

## The dispel tool (slotless — dispels live outside the spellbook array).
@export var dispel_tool : PlayerSpell = preload("res://spells/wipe_spell.tres")


func _ready() -> void:
	_print_selection()


func _unhandled_key_input(event : InputEvent) -> void:
	if event is InputEventKey:
		var key : InputEventKey = event as InputEventKey
		if not key.pressed or key.echo:
			return
		var picker : SphereCursorPicker = GameStateManager.cursor_picker
		if not is_instance_valid(picker):
			return

		var book : SpellbookManager = GameStateManager.spellbook_manager
		if key.keycode >= KEY_1 and key.keycode <= KEY_9:
			# 1..9 select book spells by array position (== SSBO slot).
			if book != null:
				var idx : int = key.keycode - KEY_1
				if idx < book.spells.size() and book.spells[idx] != null:
					picker.spell = book.spells[idx]
					_print_selection()
		elif key.keycode == KEY_X:
			picker.spell = dispel_tool
			_print_selection()
		elif key.keycode == KEY_Q:
			picker.spell = null
			_print_selection()


func _print_selection() -> void:
	var picker : SphereCursorPicker = GameStateManager.cursor_picker
	if is_instance_valid(picker) and picker.spell:
		var detail : String = ""
		if picker.spell.is_dispel:
			detail = " (dispel tool)"
		elif picker.spell.slot_index >= 0:
			detail = " (slot %d)" % picker.spell.slot_index
		print("[SpellSelector] selected: %s%s" % [picker.spell.spell_name, detail])
	else:
		print("[SpellSelector] no spell selected — clicks are ignored")
