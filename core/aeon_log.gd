extends RefCounted
## Maintains an append-only, bounded in-memory chronicle of Year-prefixed
## planetary and regional lifecycle milestones.
class_name AeonLog

## Maximum number of formatted chronicle entries retained in the ring buffer.
const MAX_ENTRIES : int = 512

## Emitted whenever a new Year-prefixed milestone entry is appended to the chronicle.
signal entry_logged(formatted_entry : String)

## Ordered list of formatted chronicle entries from oldest retained to newest.
var entries : Array[String] = []


## Prepends the current simulation year (`Year X: <headline>`) to a milestone string.
static func format_entry(headline : String) -> String:
	return "Year %d: %s" % [GameStateManager.elapsed_years, headline]


## Logs the christening of a newly formed geographic region.
func log_birth(region_name : String, biome_id : int, cell_count : int) -> void:
	# Format and append the region birth entry with its biome phrase and initial size.
	_add("The %s was born — a new %s of %d cells." % [
		region_name, _biome_phrase(biome_id), cell_count])


## Logs a region crossing a major surface-area milestone in square kilometers.
func log_growth(region_name : String, area_km2 : float, threshold_km2 : float) -> void:
	# Format and append the area expansion entry.
	_add("%s grew beyond %d km² and now spans %.0f km²." % [
		region_name, int(threshold_km2), area_km2])


## Logs a region splitting into two or more severed geographic fragments.
func log_severing(parent_name : String, daughters : PackedStringArray) -> void:
	# Include christened daughter names when at least one fragment meets the naming threshold.
	if daughters.is_empty():
		_add("%s was split asunder." % parent_name)
	else:
		_add("%s was split asunder; %s broke away." % [parent_name, _join_names(daughters)])


## Logs a smaller named region being absorbed into a larger adjacent region of the same biome.
func log_absorption(absorbed_name : String, senior_name : String) -> void:
	# Record the seniority merge in the chronicle.
	_add("The %s was fully absorbed into the expanding %s." % [absorbed_name, senior_name])


## Logs the complete disappearance of a previously christened region.
func log_extinction(region_name : String) -> void:
	# Record the region's final cell loss in the chronicle.
	_add("The %s faded from the world — nothing of it remains." % region_name)


## Logs the opening entry when a freshly generated world finishes initial region labeling.
func log_world_awakens() -> void:
	# Append the initial world-creation marker.
	_add("The world awakens; the chronicle begins.")


## Logs the opening summary entry when a loaded world rebuilds its region graph.
func log_region_named_after_load(count : int) -> void:
	# Append the post-load summary with the discovered region count.
	_add("The chronicle resumes; %d lands are known to this world." % count)


## Formats `headline` with the current year, trims oldest entries past `MAX_ENTRIES`, and emits `entry_logged`.
func _add(headline : String) -> void:
	# Prefix with the current year and append to the ring buffer.
	var entry : String = format_entry(headline)
	entries.append(entry)
	# Evict oldest entries when the buffer exceeds capacity.
	while entries.size() > MAX_ENTRIES:
		entries.remove_at(0)
	# Notify UI listeners of the newly recorded milestone.
	entry_logged.emit(entry)


## Maps a catalog biome ID (0..17) to its human-readable noun phrase for chronicle prose.
func _biome_phrase(biome_id : int) -> String:
	# Return the descriptive terrain noun corresponding to the catalog biome ID.
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


## Joins one or more region names into a comma-and-conjunction prose list with lowercase articles.
static func _join_names(names : PackedStringArray) -> String:
	# Return a single prefixed name when only one daughter region is present.
	if names.size() == 1:
		return "the %s" % names[0]
	# Concatenate multiple region names with commas and a final "and".
	var parts : String = ""
	for i : int in names.size():
		if i == names.size() - 1:
			parts += " and the %s" % names[i]
		else:
			parts += ", the %s" % names[i] if not parts.is_empty() else "the %s" % names[i]
	return parts
