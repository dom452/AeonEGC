extends RefCounted
class_name AeonLog

## The planetary chronicle (event-logging plan §5.1). Owned by GameStateManager;
## RegionGraphManager submits lifecycle milestones, the log formats and stores
## them. One entry per event, Year-prefixed, append-only.
##
## Persistence is explicitly out of scope for this plan (§5.1 defers narrative
## state to the save-system workstream); this class keeps an in-memory ring
## buffer sized for a session.

const MAX_ENTRIES : int = 512

signal entry_logged(formatted_entry : String)

var entries : Array[String] = []

## Formats "Year X: <headline>" using the elapsed year counter.
static func format_entry(headline : String) -> String:
	return "Year %d: %s" % [GameStateManager.elapsed_years, headline]


func log_birth(region_name : String, biome_id : int, cell_count : int) -> void:
	_add("The %s was born — a new %s of %d cells." % [
		region_name, _biome_phrase(biome_id), cell_count])


func log_growth(region_name : String, area_km2 : float, threshold_km2 : float) -> void:
	_add("%s grew beyond %d km² and now spans %.0f km²." % [
		region_name, int(threshold_km2), area_km2])


func log_severing(parent_name : String, daughters : PackedStringArray) -> void:
	if daughters.is_empty():
		_add("%s was split asunder." % parent_name)
	else:
		_add("%s was split asunder; %s broke away." % [parent_name, _join_names(daughters)])


func log_absorption(absorbed_name : String, senior_name : String) -> void:
	_add("The %s was fully absorbed into the expanding %s." % [absorbed_name, senior_name])


func log_extinction(region_name : String) -> void:
	_add("The %s faded from the world — nothing of it remains." % region_name)


func log_world_awakens() -> void:
	# §7.7 legacy migration marker — one deliberate entry, never silent.
	_add("The world awakens; the chronicle begins.")


func log_region_named_after_load(count : int) -> void:
	_add("The chronicle resumes; %d lands are known to this world." % count)


func _add(headline : String) -> void:
	var entry : String = format_entry(headline)
	entries.append(entry)
	while entries.size() > MAX_ENTRIES:
		entries.remove_at(0)
	entry_logged.emit(entry)


func _biome_phrase(biome_id : int) -> String:
	match biome_id:
		0: return "glacial sheet"
		1: return "tundra"
		2: return "taiga"
		3: return "alpine meadow"
		4: return "temperate forest"
		5: return "grassland"
		6: return "rainforest"
		7: return "mediterranean scrub"
		8: return "desert"
		9: return "savanna"
		10: return "jungle"
		11: return "thermal oasis"
		12: return "wetland"
		13: return "mangrove estuary"
		14: return "lake"
		15: return "frozen sea"
		16: return "coastal shelf"
		17: return "deep ocean"
		_: return "land"


static func _join_names(names : PackedStringArray) -> String:
	if names.size() == 1:
		return "the %s" % names[0]
	var parts : String = ""
	for i : int in names.size():
		if i == names.size() - 1:
			parts += " and the %s" % names[i]
		else:
			parts += ", the %s" % names[i] if not parts.is_empty() else "the %s" % names[i]
	return parts
