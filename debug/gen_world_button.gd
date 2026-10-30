## Debug-scene only (reusable as a template for production world-creation UI buttons):
## triggers `WorldGenerator.initialise_layer_generators()` when pressed.
extends Button

## Target `WorldGenerator` node initialized when this button is pressed.
@export var world_generator : WorldGenerator


## Connects the button's `pressed` signal to `_button_pressed`.
func _ready() -> void:
	self.pressed.connect(_button_pressed)


## Invokes `initialise_layer_generators()` on the assigned `world_generator`.
func _button_pressed() -> void:
	world_generator.initialise_layer_generators()
