@tool
extends Push_Constant
## Push constant that relays a single player click event into a compute shader for exactly
## one frame, then resets to a default value (e.g. 0) on subsequent frames to avoid duplicate actions.
class_name PushConstant_PlayerAction

## Which field of the player click event this push constant extracts and delivers.
enum Field {
	## Discrete 2D grid cell coordinate (Vector2i) under the cursor.
	CELL = 0,
	## Equirectangular UV coordinate (Vector2) under the cursor.
	UV = 1,
	## Bitmask (int) representing the spell slot; 0 means no action occurred this frame.
	ACTION_KEY = 2,
	## Numeric value or cost (float); positive values place spells, negative values dispel/clear them.
	ACTION_VALUE = 3,
}

## Configures which specific component of the player action payload this resource provides.
@export var field : Field = Field.ACTION_KEY:
	set(v):
		field = v
		_update_metadata()

## Cached reference to the SphereCursorPicker node handling 3D picking.
var _picker : SphereCursorPicker
## True once this resource has connected to the cursor picker's click signal.
var _subscribed : bool = false
## True when a new click event has arrived but has not yet been consumed by the GPU dispatch.
var _pending : bool = false

## Cached cell coordinate from the most recent click.
var _cached_cell : Vector2i = Vector2i.ZERO
## Cached UV coordinate from the most recent click.
var _cached_uv : Vector2 = Vector2.ZERO
## Cached action bitmask from the most recent click.
var _cached_action_key : int = 0
## Cached action value/cost from the most recent click.
var _cached_action_value : float = 0.0


## Initializes the resource and establishes its data type and name based on the selected field.
func _init() -> void:
	_update_metadata()


## Sets the Variant type and debug name corresponding to the selected payload field.
func _update_metadata() -> void:
	match field:
		Field.CELL:
			type = TYPE_VECTOR2I
			name = StringName("PlayerAction.Cell")
		Field.UV:
			type = TYPE_VECTOR2
			name = StringName("PlayerAction.UV")
		Field.ACTION_KEY:
			type = TYPE_INT
			name = StringName("PlayerAction.ActionKey")
		Field.ACTION_VALUE:
			type = TYPE_FLOAT
			name = StringName("PlayerAction.ActionValue")


## Retrieves the click data once for the active dispatch frame, then clears the pending flag so it reverts to zero.
func get_value() -> Variant:
	# Avoid querying runtime singletons while inspecting resources in the editor.
	if Engine.is_editor_hint():
		return _default_value()

	# Lazily locate the cursor picker singleton if not yet acquired.
	if not is_instance_valid(_picker):
		_picker = GameStateManager.cursor_picker
		_subscribed = false
		if not is_instance_valid(_picker):
			push_error("PushConstant_PlayerAction: GameStateManager.cursor_picker is null. Retrying next frame.")
			return _default_value()

	# Connect to the click event signal once per valid picker instance.
	if not _subscribed:
		if not _picker.cell_clicked.is_connected(_on_cell_clicked):
			_picker.cell_clicked.connect(_on_cell_clicked)
		_subscribed = true

	# Return the click data for this frame, then immediately reset so it doesn't trigger again next frame.
	if _pending:
		_pending = false
		return _cached_value_for_field()
	return _default_value()


## Caches the click payload received from the cursor picker and arms the pending flag for the next dispatch.
func _on_cell_clicked(cell : Vector2i, uv : Vector2, action_key : int, action_value : float) -> void:
	# Store the full event payload so any paired push constant resources receive identical state.
	_cached_cell = cell
	_cached_uv = uv
	_cached_action_key = action_key
	_cached_action_value = action_value
	_pending = true


## Returns the cached value corresponding to this resource's configured field.
func _cached_value_for_field() -> Variant:
	match field:
		Field.CELL:         return _cached_cell
		Field.UV:           return _cached_uv
		Field.ACTION_KEY:   return _cached_action_key
		Field.ACTION_VALUE: return _cached_action_value
	return _default_value()


## Returns the neutral default value for this field when no player click is active (e.g. 0 for action key).
func _default_value() -> Variant:
	match field:
		Field.CELL:         return Vector2i.ZERO
		Field.UV:           return Vector2.ZERO
		Field.ACTION_KEY:   return 0
		Field.ACTION_VALUE: return 0.0
	return 0

