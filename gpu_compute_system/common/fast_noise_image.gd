extends CustomImage
class_name CI_FastNoiseLite

@export var noise : FastNoiseLite

func custom_image() -> Image:
	return noise.get_image(width, height, false, false, true)
	
