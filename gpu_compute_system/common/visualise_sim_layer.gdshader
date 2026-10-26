shader_type canvas_item;

uniform sampler2DArray world_texture;
uniform int layer_to_view = 0;
uniform float scale = 1.0;
uniform float offset = 0.0;

void fragment() {
	// Sample the exact GPU layer defined by the UI.
	// Since our pipeline currently uses r16f, data is only in the .r channel.
	float raw_value = texture(world_texture, vec3(UV, float(layer_to_view))).r;
	
	// Normalize the raw data using offset and scale (value = (raw + offset) * scale)
	float value = (raw_value + offset) * scale;

	// Output as greyscale (or use value in R and G if you want to see "yellow" bounds checks)
	COLOR = vec4(value, value, value, 1.0);
}