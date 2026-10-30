extends PanelContainer
## Debug-scene only (reusable as a template for production chronicle and currency HUD UI):
## binds event-driven `AeonLog` entries and `BiomeEconomy` currency updates to a docked UI panel.
class_name AeonChroniclePanel

## Scrollable rich-text log displaying Year-prefixed chronicle milestones.
@onready var log_text : RichTextLabel = $ChronicleVBox/LogText
## Header label displaying the player's current Impact Currency total.
@onready var score_label : Label = $ChronicleVBox/Header/ImpactScore

## Bound `AeonLog` instance emitting `entry_logged` milestones.
var _bound_log : AeonLog = null
## Bound `BiomeEconomy` instance emitting `currency_gained` updates.
var _bound_economy : BiomeEconomy = null


## Binds immediately to `GameStateManager`'s chronicle and economy if ready, or defers until `world_ready`.
func _ready() -> void:
	# Bind immediately when singletons already exist; otherwise wait for `world_ready`.
	var gsm : GameStateManager = GameStateManager.instance
	if gsm.aeon_log != null and gsm.biome_economy != null:
		_bind(gsm.aeon_log, gsm.biome_economy)
	else:
		gsm.world_ready.connect(_on_world_ready)


## Connects to `aeon_log` and `biome_economy` on the first `world_ready` emission.
func _on_world_ready() -> void:
	# Ignore subsequent `world_ready` emissions once the persistent instances are bound.
	if _bound_log != null:
		return
	_bind(GameStateManager.instance.aeon_log, GameStateManager.instance.biome_economy)


## Subscribes to `chronicle` and `economy` signals, backfills existing log entries, and refreshes the score label.
func _bind(chronicle : AeonLog, economy : BiomeEconomy) -> void:
	_bound_log = chronicle
	_bound_economy = economy
	chronicle.entry_logged.connect(_on_entry_logged)
	economy.currency_gained.connect(_on_currency_gained)
	# Backfill any chronicle entries recorded prior to UI binding and display initial currency.
	for entry : String in chronicle.entries:
		_append_entry(entry)
	_update_score()


## Forwards newly emitted chronicle entries to `log_text`.
func _on_entry_logged(entry : String) -> void:
	_append_entry(entry)


## Appends a single formatted milestone line to `log_text`.
func _append_entry(entry : String) -> void:
	log_text.append_text(entry + "\n")


## Refreshes `score_label` whenever a biome transition awards Impact Currency.
func _on_currency_gained(_amount : int, _cell : Vector2i, _new_biome : int) -> void:
	_update_score()


## Updates `score_label.text` with the current wallet balance from `_bound_economy`.
func _update_score() -> void:
	score_label.text = "Impact: %d" % (_bound_economy.currency if _bound_economy else 0)
