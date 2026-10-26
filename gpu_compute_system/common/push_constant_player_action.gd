@tool
extends Push_Constant
class_name PushConstant_PlayerAction

## Push constant that relays a single Player Action click (from SphereCursorPicker's
## `cell_clicked` signal) into a compute shader's push-constant block for ONE dispatch frame,
## then clears itself (returns the field's zero/default on subsequent frames).
##
## One resource encodes exactly ONE field of the click payload. Add four instances to a
## PLAYER_ACTIONS sim layer's `push_constants_resources` array (one per Field) to pass the
## full (cell, uv, action_key, action_value) tuple to the shader.
##
## `action_key` on the wire is the spell's action bit pattern (PlayerSpell.get_action_bit_pattern():
## 1u << slot_index for placements, the target's bit for selective dispels, or WIPE_ALL —
## all bits — for a whole-cell wipe). The wire value is 0 ONLY on frames without a click.
## A NEGATIVE `action_value` (dispel tool) instructs the shader to clear bits instead of
## setting one.
##
## Lifecycle (the "single frame" contract):
##   1. `cell_clicked` fires during the input phase (before _process) → the handler caches
##      this resource's field and sets `_pending = true`.
##   2. During dispatch (process phase) the layer calls `get_value()` once → it returns the
##      cached value and immediately clears `_pending`.
##   3. The next dispatch calls `get_value()` again → `_pending` is false, so it returns the
##      field's zero/default. For ACTION_KEY this is 0, which the shader treats as "no action".
##
## Node discovery: reads `GameStateManager.cursor_picker` — a static reference that the
## GameStateManager owner sets when spawning the picker (mirrors the GSM singleton pattern).
## On the first valid `get_value()` it caches the picker and subscribes to `cell_clicked`.
## If `cursor_picker` is still null, it logs an error and retries on the next `get_value()`.
##
## Type detection: `cache_push_constants_layout()` calls `get_value()` to infer `type` only
## when `type == TYPE_NIL`. We set `type` explicitly from `field` in `_init()`/`_update_metadata()`,
## so layout-caching never depends on the picker existing yet.

enum Field {
	CELL = 0,         ## Vector2i — discrete grid cell under the cursor.
	UV = 1,           ## Vector2   — equirectangular [0,1]² UV under the cursor.
	ACTION_KEY = 2,   ## int — pre-shifted spell bit pattern (1u << bit); 0 = no action this frame.
	ACTION_VALUE = 3, ## float — spell cost; NEGATIVE = dispel/wipe the spell bit.
}

## Which payload field this resource encodes. Changing it re-derives `type` and `name`.
@export var field : Field = Field.ACTION_KEY:
	set(v):
		field = v
		_update_metadata()

var _picker : SphereCursorPicker
var _subscribed : bool = false
var _pending : bool = false

var _cached_cell : Vector2i = Vector2i.ZERO
var _cached_uv : Vector2 = Vector2.ZERO
var _cached_action_key : int = 0
var _cached_action_value : float = 0.0


## Constructor — derives `type` and `name` from the default `field`. Runs both in the
## editor and at runtime so the inspector and layout-caching see a concrete type immediately.
func _init() -> void:
	_update_metadata()

## Re-derives `type` and `name` whenever `field` changes. Setting `type` explicitly here
## means `cache_push_constants_layout()` never has to call `get_value()` for type inference
## (which would fail before the picker exists).
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

## Called by the layer dispatcher each frame. Returns the cached click value ONCE (then
## clears `_pending`), or the field's zero/default on subsequent calls. Also performs the
## lazy one-time picker discovery + signal subscription on first valid call.
func get_value() -> Variant:
	# Never touch global state in the editor — return the default so inspector display works.
	if Engine.is_editor_hint():
		return _default_value()

	# Lazy discovery via the GameStateManager static reference. Re-acquire (and reset
	# subscription state) whenever our cached picker has gone invalid, so a respawned
	# picker is picked up and re-subscribed on a later frame.
	if not is_instance_valid(_picker):
		_picker = GameStateManager.cursor_picker
		_subscribed = false
		if not is_instance_valid(_picker):
			push_error("PushConstant_PlayerAction: GameStateManager.cursor_picker is null. Retrying next frame.")
			return _default_value()

	# Subscribe exactly once per valid picker instance.
	if not _subscribed:
		if not _picker.cell_clicked.is_connected(_on_cell_clicked):
			_picker.cell_clicked.connect(_on_cell_clicked)
		_subscribed = true

	# Single-frame consume: return the cached value once, then revert to the default.
	if _pending:
		_pending = false
		return _cached_value_for_field()
	return _default_value()

## Signal handler — caches the full click payload and arms this resource for one dispatch.
## The full tuple is cached on every resource regardless of `field`, so the four resources
## in a layer stay synchronized to the same click event.
func _on_cell_clicked(cell : Vector2i, uv : Vector2, action_key : int, action_value : float) -> void:
	_cached_cell = cell
	_cached_uv = uv
	_cached_action_key = action_key
	_cached_action_value = action_value
	_pending = true

## Returns the cached value for THIS resource's configured field. Only meaningful while
## `_pending` is true (i.e. the frame immediately after a click).
func _cached_value_for_field() -> Variant:
	match field:
		Field.CELL:         return _cached_cell
		Field.UV:           return _cached_uv
		Field.ACTION_KEY:   return _cached_action_key
		Field.ACTION_VALUE: return _cached_action_value
	return _default_value()

## Returns the field's zero/default value, used outside the single-frame window and in the
## editor. For ACTION_KEY this is 0, which the shader interprets as "no action this frame".
func _default_value() -> Variant:
	match field:
		Field.CELL:         return Vector2i.ZERO
		Field.UV:           return Vector2.ZERO
		Field.ACTION_KEY:   return 0
		Field.ACTION_VALUE: return 0.0
	return 0
