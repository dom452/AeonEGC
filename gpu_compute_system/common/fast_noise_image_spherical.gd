extends CI_FastNoiseLite
class_name CI_FastNoiseLite_Spherical

## Generates a 3D spherical FastNoiseLite image that seamlessly wraps horizontally (X-axis)
## and contracts longitude lines toward the poles (Y-axis) using 3D spherical coordinate mapping.
func custom_image() -> Image:
	if not noise:
		return null
		
	if width <= 0 or height <= 0:
		return null

	var floats : PackedFloat32Array = PackedFloat32Array()
	floats.resize(width * height)

	# By dividing only by TAU, coordinates represent spherical distances in pixels.
	# FastNoiseLite's get_noise_3d internally multiplies by noise.frequency.
	var radius : float = float(width) / TAU
	var inv_w : float = TAU / float(width)

	for y : int in range(height):
		# Map Y to cell-centered latitude angle phi (Model B: poles at boundary edges y = -0.5 and y = height - 0.5)
		var norm_y : float = (float(y) + 0.5) / float(height)
		var phi : float = (0.5 - norm_y) * PI
		var cos_lat : float = cos(phi) # Naturally > 0 for all cells (no pinch clamp needed)
			
		var ny : float = radius * sin(phi)
		var row_offset : int = y * width
		
		for x : int in range(width):
			var theta : float = (float(x) + 0.5) * inv_w
			var nx : float = radius * cos_lat * cos(theta)
			var nz : float = radius * cos_lat * sin(theta)
			
			var sample : float = (noise.get_noise_3d(nx, ny, nz) + 1.0) * 0.5
			floats[row_offset + x] = clampf(sample, 0.0, 1.0)

	return Image.create_from_data(width, height, false, Image.FORMAT_RF, floats.to_byte_array())
