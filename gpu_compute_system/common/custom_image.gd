@abstract
extends Resource
## Abstract base resource for procedurally generating or providing 2D image data to GPU compute passes.
class_name CustomImage

## Desired pixel width of the generated image.
var width : int
## Desired pixel height of the generated image.
var height : int

## Abstract method that subclasses implement to generate and return the raw Godot Image.
@abstract
func custom_image() -> Image

## Generates and returns the Image, or null if generation fails.
func get_image() -> Image:
	# Delegate to the concrete generator implementation.
	var img : Image = custom_image()
	if img:
		return img
	else:
		return null

## Sets the target pixel dimensions before generating the image.
func set_image_params(w : int, h : int) -> void:
	# Cache dimensions so custom_image() knows what resolution to generate.
	width = w
	height = h

