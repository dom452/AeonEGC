extends CI_FastNoiseLite
## Generates a 3D noise texture mapped to spherical surface coordinates, ensuring seamless
## horizontal wrapping and realistic pole-convergence without spherical stretching artifacts.
class_name CI_FastNoiseLite_Spherical

## Samples 3D noise across spherical latitude and longitude angles to produce an equirectangular noise map.
func custom_image() -> Image:
	# Verify that a noise generator exists and target dimensions are valid.
	if not noise:
		return null
		
	if width <= 0 or height <= 0:
		return null

	# Allocate single-precision float buffer for all pixels.
	var floats : PackedFloat32Array = PackedFloat32Array()
	floats.resize(width * height)

	# Calculate radius in pixels so distance between sample points stays uniform.
	var radius : float = float(width) / TAU
	var inv_w : float = TAU / float(width)

	# Iterate rows from North pole (Y=0) down to South pole (Y=height-1).
	for y : int in range(height):
		# Convert pixel Y into latitude angle phi (-pi/2 at south pole, +pi/2 at north pole).
		var norm_y : float = (float(y) + 0.5) / float(height)
		var phi : float = (0.5 - norm_y) * PI
		var cos_lat : float = cos(phi)
			
		var ny : float = radius * sin(phi)
		var row_offset : int = y * width
		
		# Iterate columns (longitude around the planet from 0 to 2*PI).
		for x : int in range(width):
			var theta : float = (float(x) + 0.5) * inv_w
			# Scale horizontal radius by cos(latitude) so lines of longitude naturally converge at poles.
			var nx : float = radius * cos_lat * cos(theta)
			var nz : float = radius * cos_lat * sin(theta)
			
			# Sample 3D noise and normalize from [-1, 1] to [0, 1].
			var sample : float = (noise.get_noise_3d(nx, ny, nz) + 1.0) * 0.5
			floats[row_offset + x] = clampf(sample, 0.0, 1.0)

	# Pack floats into a 32-bit single-channel floating point image.
	return Image.create_from_data(width, height, false, Image.FORMAT_RF, floats.to_byte_array())

