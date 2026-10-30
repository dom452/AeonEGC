extends CI_FastNoiseLite
## Generates a 3D noise texture mapped onto a cylinder, ensuring the image seamlessly
## repeats along the horizontal X-axis (useful for planet wrap without a vertical seam).
class_name CI_FastNoiseLite_Cylindrical

## Samples 3D noise in a circular loop along X to produce seamless horizontal wrapping.
func custom_image() -> Image:
	# Verify that a noise generator exists and target dimensions are positive.
	if not noise:
		return null
		
	if width <= 0 or height <= 0:
		return null

	# Allocate single-precision float buffer for the whole image grid.
	var floats : PackedFloat32Array = PackedFloat32Array()
	floats.resize(width * height)

	var freq : float = noise.frequency
	var radius : float = (float(width) * freq) / TAU
	var inv_w : float = TAU / float(width)

	# Step through each scanline (Y represents vertical height along the cylinder).
	for y : int in range(height):
		var ny : float = float(y) * freq
		var row_offset : int = y * width
		# Step through X, turning horizontal pixel steps into a 360-degree circle in 3D noise space.
		for x : int in range(width):
			var angle : float = float(x) * inv_w
			var nx : float = radius * cos(angle)
			var nz : float = radius * sin(angle)
			
			# Sample 3D noise and normalize from [-1, 1] to [0, 1] range.
			var sample : float = (noise.get_noise_3d(nx, ny, nz) + 1.0) * 0.5
			floats[row_offset + x] = clampf(sample, 0.0, 1.0)

	# Convert the float array into a single-channel 32-bit floating point image.
	return Image.create_from_data(width, height, false, Image.FORMAT_RF, floats.to_byte_array())

