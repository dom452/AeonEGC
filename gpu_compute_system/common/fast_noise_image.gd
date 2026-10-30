extends CustomImage
## Generates a standard planar 2D noise texture using a configured FastNoiseLite resource.
class_name CI_FastNoiseLite

## FastNoiseLite generator configuring the noise algorithm, frequency, and fractal octaves.
@export var noise : FastNoiseLite

## Bakes a 2D noise image sampled on a flat planar grid at the configured width and height.
func custom_image() -> Image:
	# Request an uncompressed single-channel float or grayscale noise image from the engine.
	return noise.get_image(width, height, false, false, true)

	
