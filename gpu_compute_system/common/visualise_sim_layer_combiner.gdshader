shader_type canvas_item;

uniform sampler2DArray world_texture;
uniform int layer_to_view_r = 0;
uniform int layer_to_view_g = 0;
uniform int layer_to_view_b = 0;
uniform int layer_to_view_a = 0;
uniform int layer_to_view_all = 0;
uniform bool show_all = true;

void fragment() {
	// Sample the exact GPU layer defined by the UI.
	// Since our pipeline currently uses r16f, data is only in the .r channel.
	vec4 col_all = texture(world_texture, vec3(UV, float(layer_to_view_all)));
	float col_r = texture(world_texture, vec3(UV, float(layer_to_view_r))).r;
	float col_g = texture(world_texture, vec3(UV, float(layer_to_view_g))).r;
	float col_b = texture(world_texture, vec3(UV, float(layer_to_view_b))).r;
	float col_a = texture(world_texture, vec3(UV, float(layer_to_view_a))).r;
	// Output as greyscale (or use value in R and G if you want to see "yellow" bounds checks)
	COLOR = mix(
		vec4(col_r, col_g, col_b, col_a), 
		col_all, 
		float(show_all)
		);
}