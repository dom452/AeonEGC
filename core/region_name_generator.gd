extends RefCounted
## Generates deterministic procedural names for newly christened regions and
## relational daughter names for severed region fragments.
class_name RegionNameGenerator

## Ordered relational prefixes prepended to a parent region's root when naming split daughter fragments.
const RELATIONAL_PREFIXES : PackedStringArray = [
	"Lesser", "Far", "Upper", "Sundered", "Cleaved", "Lower", "Outer", "New",
]

## Word banks of `prefix`, `root`, and `suffix` token arrays keyed by biome naming category.
const BANKS : Dictionary = {
	"cryosphere": {
		"prefix": ["Frozen", "Pale", "Silent", "White", "Shivering"],
		"root": ["Expanse", "Waste", "Shelf", "Sheet", "Reach", "Verge"],
		"suffix": ["of Hoarfrost", "of the Long Winter", "of Rime", "of Stillness"],
	},
	"cold": {
		"prefix": ["Grey", "Windswept", "Bare", "Frostbound", "Northern"],
		"root": ["Tundra", "Barrens", "Flats", "Basin", "Moor", "Tract"],
		"suffix": ["of Thin Snow", "of the Frost Line", "of Pale Sun", "of Lichens"],
	},
	"forest": {
		"prefix": ["Deep", "Whispering", "Tangled", "Verdant", "Shadowed", "Elder"],
		"root": ["Forest", "Wood", "Grove", "Thicket", "Weald", "Canopy"],
		"suffix": ["of Dawnlight", "of Moss", "of the Old Growth", "of Songbirds"],
	},
	"grassland": {
		"prefix": ["Golden", "Waving", "Open", "Endless", "Sunlit"],
		"root": ["Steppe", "Plains", "Meadow", "Downs", "Sea of Grass", "Veldt"],
		"suffix": ["of Zephyrs", "of Tall Grass", "of the Herd Winds", "of Wildflowers"],
	},
	"desert": {
		"prefix": ["Scorching", "Shifting", "Blistered", "Sun-Cursed", "Rusted"],
		"root": ["Erg", "Sands", "Waste", "Dunes", "Expanse", "Flats"],
		"suffix": ["of Mirages", "of the Twin Suns", "of Bleached Bone", "of Dry Winds"],
	},
	"tropical": {
		"prefix": ["Steamy", "Emerald", "Crying", "Teeming", "Suffocating"],
		"root": ["Jungle", "Rainforest", "Tangle", "Greenhood", "Wilds"],
		"suffix": ["of Ten Thousand Frogs", "of Orchids", "of the Canopy Veil", "of Eternal Rain"],
	},
	"volcanic": {
		"prefix": ["Smoldering", "Blessed", "Hissing", "Cinder", "Warm"],
		"root": ["Oasis", "Vents", "Springs", "Crater", "Hearth", "Basin"],
		"suffix": ["of the Deep Fire", "of Healing Steam", "of Molten Stone", "of the Ember Tide"],
	},
	"wetland": {
		"prefix": ["Murky", "Reedy", "Drowned", "Misty", "Boggy"],
		"root": ["Marsh", "Fen", "Swamp", "Mire", "Wetland", "Slough"],
		"suffix": ["of Reeds", "of the Frog Chorus", "of Brackish Water", "of Cattails"],
	},
	"limnic": {
		"prefix": ["Clear", "Deep", "Mirror", "Cold", "Tranquil"],
		"root": ["Lake", "Basin", "Tarn", "Waters", "Sound"],
		"suffix": ["of the First Rain", "of Still Water", "of the River Mouth", "of Silver Fish"],
	},
	"marine_polar": {
		"prefix": ["Icebound", "Black", "Cracking", "Lead-Grey", "Howling"],
		"root": ["Sea", "Floes", "Reach", "Water", "Expanse"],
		"suffix": ["of Pack Ice", "of the White Silence", "of the Polar Night", "of Whales"],
	},
	"marine": {
		"prefix": ["Shimmering", "Endless", "Salt", "Rolling", "Sunlit"],
		"root": ["Sea", "Shoals", "Deep", "Waters", "Gulf", "Swell"],
		"suffix": ["of Coral", "of the Trade Winds", "of a Thousand Islands", "of the Tide"],
	},
	"pelagic": {
		"prefix": ["Abyssal", "Bottomless", "Storm-Wracked", "Sapphire", "Nameless"],
		"root": ["Deep", "Ocean", "Expanse", "Reach", "Waste of Water"],
		"suffix": ["of the Drowned Stars", "of Leviathans", "of No Shore", "of the Rolling Deep"],
	},
	"scrub": {
		"prefix": ["Dry", "Fragrant", "Thin", "Sun-Bleached", "Scratchy"],
		"root": ["Scrub", "Chaparral", "Heath", "Brush", "Rise"],
		"suffix": ["of Wild Sage", "of Dry Stone", "of the Goat Paths", "of Summer Smoke"],
	},
	"alpine": {
		"prefix": ["High", "Windy", "Stone-Strewn", "Cloud-Kissed", "Precipitous"],
		"root": ["Heights", "Slopes", "Meadows", "Saddle", "Cirque", "Ridge"],
		"suffix": ["of Thin Air", "of the Mountain Goats", "of Late Thaw", "of Echoes"],
	},
	"estuarine": {
		"prefix": ["Brackish", "Tangled", "Muddy", "Tidal", "Rooted"],
		"root": ["Estuary", "Delta", "Mangroves", "Channels", "Fingers"],
		"suffix": [" of the Meeting Waters", " of Crabs", " of the Ebb Tide", " of Stilted Roots"],
	},
}

## Lookup table mapping catalog biome IDs (`0..17`) to their naming category keys in `BANKS`.
const BIOME_CATEGORY : PackedStringArray = [
	"cryosphere",   # 0  Glacial Ice Sheet
	"cold",         # 1  Polar Tundra
	"forest",       # 2  Boreal Taiga
	"alpine",       # 3  Alpine Meadow
	"forest",       # 4  Temperate Forest
	"grassland",    # 5  Temperate Grassland
	"forest",       # 6  Temperate Rainforest
	"scrub",        # 7  Mediterranean Scrub
	"desert",       # 8  Subtropical Desert
	"grassland",    # 9  Semi-Arid Savanna
	"tropical",     # 10 Tropical Rainforest
	"volcanic",     # 11 Thermal Oasis
	"wetland",      # 12 Freshwater Wetland
	"estuarine",    # 13 Mangrove Estuary
	"limnic",       # 14 Freshwater Lake
	"marine_polar", # 15 Sea Ice / Frozen Sea
	"marine",       # 16 Shallow Coastal Shelf
	"pelagic",      # 17 Pelagic Deep Ocean
]

## Definite article prefix included in every region's canonical display name.
const ARTICLE : String = "The "

## Set of all region names already minted in the current world (`name -> true`) to guarantee uniqueness.
var used_names : Dictionary = {}


## Returns the naming category key in `BANKS` for `biome_id`, defaulting to `"grassland"` if out of range.
static func category_for_biome(biome_id : int) -> String:
	if biome_id < 0 or biome_id >= BIOME_CATEGORY.size():
		return "grassland"
	return BIOME_CATEGORY[biome_id]


## Mints and records a unique, deterministic fresh region name from `biome_id`'s word bank using `salt`.
func mint_fresh(biome_id : int, salt : int) -> String:
	# Probe up to 64 deterministic combinations from the biome's word bank for an unused name.
	var category : String = category_for_biome(biome_id)
	var bank : Dictionary = BANKS[category]
	for attempt : int in 64:
		var name : String = _compose(bank, salt + attempt * 7919)
		if not used_names.has(name):
			used_names[name] = true
			return name
	# Append a sequential number if all probed combinations in the category bank are already taken.
	var base : String = _compose(bank, salt)
	var unique : String = "%s %d" % [base, used_names.size() + 1]
	used_names[unique] = true
	return unique


## Mints a unique daughter name derived from `parent_name` using a relational prefix not already
## used by `parent_name` or `sibling_names`, capped at one relational prefix deep.
func mint_derived(parent_name : String, biome_id : int, sibling_names : PackedStringArray, salt : int) -> String:
	var root : String = _strip_article(parent_name)
	# Strip any existing relational prefix so derived names never stack more than one relational token deep.
	for token : String in RELATIONAL_PREFIXES:
		if root.begins_with(token + " "):
			root = root.trim_prefix(token + " ")
			break

	# Collect relational tokens already used by the parent or sibling fragments from the same split.
	var taken : Dictionary = {}
	for token : String in RELATIONAL_PREFIXES:
		if parent_name.contains(token):
			taken[token] = true
	for sibling : String in sibling_names:
		for token : String in RELATIONAL_PREFIXES:
			if sibling.contains(token):
				taken[token] = true

	# Filter `RELATIONAL_PREFIXES` down to tokens not yet claimed in this lineage.
	var available : PackedStringArray = PackedStringArray()
	for token : String in RELATIONAL_PREFIXES:
		if not taken.has(token):
			available.append(token)

	# Fall back to a fresh biome name if every relational prefix is already exhausted.
	if available.is_empty():
		return mint_fresh(biome_id, salt)

	# Select the first deterministic candidate that does not collide with `used_names` or siblings.
	for attempt : int in available.size():
		var token : String = available[(salt + attempt) % available.size()]
		var candidate : String = ARTICLE + token + " " + root
		if not used_names.has(candidate) and not sibling_names.has(candidate) and candidate != parent_name:
			used_names[candidate] = true
			return candidate

	# Append a sequential number if every available relational prefix collides with an existing region name.
	var fallback : String = ARTICLE + String(available[salt % available.size()]) + " " + root
	var unique : String = "%s %d" % [fallback, used_names.size() + 1]
	used_names[unique] = true
	return unique


## Returns true if `name` (after stripping `"The "`) begins with a token from `RELATIONAL_PREFIXES`.
static func has_relational_prefix(name : String) -> bool:
	var stripped : String = _strip_article(name)
	for token : String in RELATIONAL_PREFIXES:
		if stripped.begins_with(token + " "):
			return true
	return false


## Assembles `"The <prefix> <root> <suffix>"` from `bank` using `salt` to index each token list.
func _compose(bank : Dictionary, salt : int) -> String:
	var prefixes : Array = bank["prefix"]
	var roots : Array = bank["root"]
	var suffixes : Array = bank["suffix"]
	var prefix : String = prefixes[salt % prefixes.size()]
	@warning_ignore("integer_division")
	var root : String = roots[(salt / 3 + 1) % roots.size()]
	@warning_ignore("integer_division")
	var suffix : String = suffixes[(salt / 7 + 2) % suffixes.size()]
	return ARTICLE + prefix + " " + root + " " + suffix


## Returns `name` with the leading `"The "` article removed if present.
static func _strip_article(name : String) -> String:
	if name.begins_with(ARTICLE):
		return name.trim_prefix(ARTICLE)
	return name
