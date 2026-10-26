shader_type canvas_item;

uniform sampler2DArray world_texture;
uniform int layer_to_view = 0;
uniform float scale = 1.0;
uniform float offset = 0.0;

void fragment() {
	// Single-cell events (spell placements, click counters) must survive the downscale
	// from the 512x512 grid to these ~160px preview cards. Linear filtering averages
	// one bright texel across ~10 card pixels (and drops it entirely when samples fall
	// between texels), so take the MAX over every source cell this card pixel covers.
	ivec2 source_size = textureSize(world_texture, 0).xy;
	vec2 half_footprint = (abs(dFdx(UV)) + abs(dFdy(UV))) * 0.5;
	ivec2 first_cell = ivec2(floor((UV - half_footprint) * vec2(source_size)));
	ivec2 last_cell = ivec2(ceil((UV + half_footprint) * vec2(source_size))) - ivec2(1);
	first_cell = clamp(first_cell, ivec2(0), source_size - ivec2(1));
	last_cell = clamp(last_cell, ivec2(0), source_size - ivec2(1));
	last_cell = max(last_cell, first_cell);

	float raw_value = 0.0;
	for (int y = first_cell.y; y <= last_cell.y; y++) {
		for (int x = first_cell.x; x <= last_cell.x; x++) {
			raw_value = max(raw_value, texelFetch(world_texture, ivec3(x, y, layer_to_view), 0).r);
		}
	}
	
	// Apply dynamic VisHelpers scaling and offset
	float value = (raw_value + offset) * scale;
	
	// Output as greyscale (or use value in R and G if you want to see "yellow" bounds checks)
	COLOR = vec4(value, value, value, 1.0);
}