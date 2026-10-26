extends PanelContainer
class_name AeonChroniclePanel

## The Aeon Chronicle: live log box + Impact Currency score, docked at the
## bottom of the debug panel column. Scene-built (debug/World_Gen.tscn), not
## procedural.
##
## Binding is event-driven (no per-frame polling): GameStateManager emits
## `world_ready` once the world state, AeonLog and BiomeEconomy singletons
## exist (first generate_world() or load_game()). If they already exist at
## _ready, bind immediately; otherwise defer to the signal. Re-emissions
## (world regeneration) are ignored — the singletons are stable instances.

@onready var log_text : RichTextLabel = $ChronicleVBox/LogText
@onready var score_label : Label = $ChronicleVBox/Header/ImpactScore

var _bound_log : AeonLog = null
var _bound_economy : BiomeEconomy = null


func _ready() -> void:
	var gsm : GameStateManager = GameStateManager.instance
	if gsm.aeon_log != null and gsm.biome_economy != null:
		_bind(gsm.aeon_log, gsm.biome_economy)
	else:
		gsm.world_ready.connect(_on_world_ready)


func _on_world_ready() -> void:
	if _bound_log != null:
		return  # already bound; world_ready re-fires on regeneration
	_bind(GameStateManager.instance.aeon_log, GameStateManager.instance.biome_economy)


func _bind(chronicle : AeonLog, economy : BiomeEconomy) -> void:
	_bound_log = chronicle
	_bound_economy = economy
	chronicle.entry_logged.connect(_on_entry_logged)
	economy.currency_gained.connect(_on_currency_gained)
	# Backfill history (covers load_game mid-session) and current score.
	for entry : String in chronicle.entries:
		_append_entry(entry)
	_update_score()


func _on_entry_logged(entry : String) -> void:
	_append_entry(entry)


func _append_entry(entry : String) -> void:
	log_text.append_text(entry + "\n")


func _on_currency_gained(_amount : int, _cell : Vector2i, _new_biome : int) -> void:
	_update_score()


func _update_score() -> void:
	score_label.text = "Impact: %d" % (_bound_economy.currency if _bound_economy else 0)
