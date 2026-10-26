extends CI_FastNoiseLite
class_name CI_FastNoiseLite_Cylindrical

## Generates a 3D cylindrical FastNoiseLite image that seamlessly wraps horizontally (X-axis).
func custom_image() -> Image:
	if not noise:
		return null
		
	if width <= 0 or height <= 0:
		return null

	var floats : PackedFloat32Array = PackedFloat32Array()
	floats.resize(width * height)

	var freq : float = noise.frequency
	var radius : float = (float(width) * freq) / TAU
	var inv_w : float = TAU / float(width)

	for y : int in range(height):
		var ny : float = float(y) * freq
		var row_offset : int = y * width
		for x : int in range(width):
			var angle : float = float(x) * inv_w
			var nx : float = radius * cos(angle)
			var nz : float = radius * sin(angle)
			
			var sample : float = (noise.get_noise_3d(nx, ny, nz) + 1.0) * 0.5
			floats[row_offset + x] = clampf(sample, 0.0, 1.0)

	return Image.create_from_data(width, height, false, Image.FORMAT_RF, floats.to_byte_array())
