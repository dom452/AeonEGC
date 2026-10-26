@abstract
extends Resource
class_name  CustomImage

var width : int
var height : int

@abstract
func custom_image() -> Image

func get_image() -> Image:
	var img : Image = custom_image()
	if img:
		return img
	else:
		return null

func set_image_params(w : int, h : int) -> void:
	width = w
	height = h
