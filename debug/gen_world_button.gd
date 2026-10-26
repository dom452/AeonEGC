extends Button

@export var world_generator : WorldGenerator

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	self.pressed.connect(_button_pressed)

func _button_pressed() -> void:
	world_generator.initialise_layer_generators()
