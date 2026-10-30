extends Node
## Debug-scene only (reusable as a template for production spell-hotbar UI): binds number-row
## hotkeys (`1..9`), dispel (`X`), and clear (`Q`) to `GameStateManager.cursor_picker.spell`.
class_name DebugSpellSelector

## Slotless whole-cell dispel `PlayerSpell` assigned to the cursor picker when pressing `X`.
@export var dispel_tool : PlayerSpell = preload("res://spells/wipe_spell.tres")


## Prints the initial spell selection state when entering the scene tree.
func _ready() -> void:
	_print_selection()


## Maps keys `1..9` to `SpellbookManager.spells[0..8]`, `X` to `dispel_tool`, and `Q` to `null` on `cursor_picker`.
func _unhandled_key_input(event : InputEvent) -> void:
	if event is InputEventKey:
		var key : InputEventKey = event as InputEventKey
		if not key.pressed or key.echo:
			return
		var picker : SphereCursorPicker = GameStateManager.cursor_picker
		if not is_instance_valid(picker):
			return

		# Select a placement spell by slot (`1..9`), select the dispel tool (`X`), or clear selection (`Q`).
		var book : SpellbookManager = GameStateManager.spellbook_manager
		if key.keycode >= KEY_1 and key.keycode <= KEY_9:
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


## Prints the currently active `PlayerSpell` and its SSBO slot or dispel status to the console.
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
