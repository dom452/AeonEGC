shader_type spatial;

uniform sampler2DArray float_texture;
uniform usampler2DArray atomic_texture;

#include "layer_globals.gdshaderinc"

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	float light = texture(float_texture, vec3(UV, float(F_ENERGY_Sunlight))).r;
	float col_r = texture(float_texture, vec3(UV, float(F_LANDSCAPE_BedrockHeight))).r;
	float col_g = texture(float_texture, vec3(UV, float(F_WATER_WaterLiquidHeight))).r;
	float col_b = texture(float_texture, vec3(UV, float(F_WATER_WaterIceHeight))).r;
	ALBEDO = vec3(col_r, col_g, col_b);
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
