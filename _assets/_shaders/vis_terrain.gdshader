shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://_assets/layer_globals.gdshaderinc"

uniform sampler2DArray float_texture : filter_linear, repeat_enable;
uniform sampler2DArray atomic_vis_tex : filter_linear, repeat_enable;
uniform sampler2D u_detail_noise : filter_linear, repeat_enable;

global uniform float u_camera_distance;

// Cursor hover state — published each frame by SphereCursorPicker (plan §6.2).
// u_hover_active > 0.5 ⇒ the cursor is over the sphere; u_hover_cell_coord is the
// discrete simulation cell under it. Used below to draw a cell-outline highlight.
global uniform ivec2 u_hover_cell_coord;
global uniform float u_hover_active;

uniform vec2 u_grid_size = vec2(512.0, 512.0);

// Cell-highlight overlay tuning (plan §6.2). Strength 0.0 ⇒ overlay fully disabled.
uniform vec3 col_hover_highlight : source_color = vec3(1.0, 0.8, 0.2);
uniform float u_hover_highlight_strength = 0.6;

// --- Water (merged from vis_water.gdshader; vertex displacement removed) ---
// Land + water now share one opaque surface on the flat unit sphere, so water is
// blended over terrain color in-shader by `water_weight` instead of a transparent
// second mesh. Depth bands drive the shallow→deep gradient; ice overlays on top.
uniform float u_depth_shallow = 0.01;
uniform float u_depth_deep = 0.20;
uniform vec3 col_water_shallow : source_color = vec3(0.2, 0.6, 0.8);
uniform vec3 col_water_deep : source_color = vec3(0.0, 0.1, 0.3);
uniform vec3 col_ice : source_color = vec3(0.9, 0.95, 1.0);

// --- Biome border overlay (event-logging plan §7.3) ---
// Renders discrete biome boundaries on the globe by sampling the BIOME_TYPE
// atomic layer through the visualizer's normalized pass-through (biome byte /
// 255). Strength 0.0 ⇒ overlay fully disabled (default off until the
// classification system is enabled).
// u_biome_border_width_px sizes the line in SCREEN pixels (constant width as
// the camera zooms), clamped by a 3-cell search radius when cells shrink to
// sub-pixel at far zoom.
uniform float u_biome_border_strength = 0.0;
uniform float u_biome_border_width_px = 2.0;
// Corner fillet radius in CELL units (0..0.5). 0 = hard right angles; larger
// values round the staircase corners into bezier-like arcs. Cell-unit on
// purpose: the staircase it smooths is one cell tall.
uniform float u_biome_border_corner_radius = 0.35;
uniform vec3 col_biome_border : source_color = vec3(0.05, 0.05, 0.05);

// Robust manual bilinear filter to bypass Godot's Texture2DArrayRD ignoring sampler states
float sample_smooth(sampler2DArray tex, vec2 uv, float layer) {
	// UV.y = 0 (pole) evaluates to -0.5 unnormalized, causing a 50% blend with row 1.
	// Clamping unnorm.y to [0, size-1] forces the pole to sample 100% of the uniform row 0.
	vec2 unnorm = vec2(uv.x * u_grid_size.x - 0.5, clamp(uv.y * u_grid_size.y - 0.5, 0.0, u_grid_size.y - 1.0));
	vec2 f = fract(unnorm);
	vec2 inv = 1.0 / u_grid_size; 
	
	// X wraps seamlessly, Y is clamped safely within pixel centers
	float x0 = fract((floor(unnorm.x) + 0.5) * inv.x);
	float x1 = fract((floor(unnorm.x) + 1.0 + 0.5) * inv.x);
	float y0 = (floor(unnorm.y) + 0.5) * inv.y;
	float y1 = (floor(unnorm.y) + 1.0 + 0.5) * inv.y;
	
	float tl = texture(tex, vec3(x0, y0, layer)).r;
	float tr = texture(tex, vec3(x1, y0, layer)).r;
	float bl = texture(tex, vec3(x0, y1, layer)).r;
	float br = texture(tex, vec3(x1, y1, layer)).r; 
	
	return mix(mix(tl, tr, f.x), mix(bl, br, f.x), f.y);
}

// Texel-snapped NEAREST read for categorical layers. Biome IDs are discrete:
// bilinear filtering blends adjacent IDs into garbage (a forest next to a
// desert would sample as 8.5 — no such biome). Snap to the owning texel's
// center and sample once. The owning texel of uv is floor(uv * u_grid_size)
// — NO -0.5 offset here: subtracting 0.5 returns the west/north neighbor's
// texel for 3/4 of every cell, which flips center_id mid-cell and shatters
// corner-tile classification into dashes and hooks. X wraps the FLOOR so
// uv.x = 0 reads texel 0, not 511; Y clamps at poles.
float sample_nearest(sampler2DArray tex, vec2 uv, float layer) {
	vec2 unnorm = vec2(uv.x * u_grid_size.x, clamp(uv.y * u_grid_size.y, 0.0, u_grid_size.y - 0.001));
	float cx = mod(floor(unnorm.x), u_grid_size.x);
	vec2 snapped = vec2(
		(cx + 0.5) / u_grid_size.x,
		(floor(unnorm.y) + 0.5) / u_grid_size.y
	);
	return texture(tex, vec3(snapped, layer)).r;
}

// Rounded integer biome id at a texel (reconstructed from the visualizer's
// id/255.0 pass-through — see the fragment() call site note).
int biome_id_at(sampler2DArray tex, vec2 uv, float layer) {
	return int(round(sample_nearest(tex, uv, layer) * 255.0));
}

// Closest distance from p to the segment [a, b] (cell-local units).
float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-9), 0.0, 1.0);
	return length(pa - ba * t);
}

// Corner-point classification from the 4 cells around a corner (nw|ne over
// sw|se). Each arm bit is set when the two cells flanking that arm's edge
// differ: N=1 (nw!=ne), E=2 (ne!=se), S=4 (sw!=se), W=8 (nw!=sw). The 12
// reachable non-zero patterns are the tile sheet: 2 opposite arms = STRAIGHT,
// 2 adjacent = TURN, 3 = T, 4 = CROSS. Classification is corner-relative, so
// both cells sharing an edge always agree on the tile — the comb-killer.
int corner_arms(int nw, int ne, int sw, int se) {
	return ((nw != ne) ? 1 : 0) | ((ne != se) ? 2 : 0) | ((sw != se) ? 4 : 0) | ((nw != sw) ? 8 : 0);
}

// Geometry of one tile in corner-local coordinates (origin = the corner
// point, +x = world +x, +y = world +y). Each arm is drawn only from the
// corner to the arm midpoint; the tile at the arm's other end draws the
// other half, so the two half-arm copies join seamlessly. TURN tiles
// truncate their arms to the fillet tangent and draw the quarter-arc of
// radius r bulging toward the corner (minor arc, quadrant-clamped). T and
// CROSS draw sharp half-arms (policy: junctions stay sharp). Returns
// distance in cell units (1e6 for EMPTY).
float tile_distance(vec2 q, int arms, float radius) {
	if (arms == 0) return 1e6;
	bool is_turn = (arms == 3 || arms == 6 || arms == 12 || arms == 9);
	float t0 = is_turn ? radius : 0.0;
	float best = 1e6;
	if ((arms & 1) != 0) best = min(best, seg_dist(q, vec2(0.0, -t0), vec2(0.0, -0.5)));   // N
	if ((arms & 2) != 0) best = min(best, seg_dist(q, vec2(t0, 0.0), vec2(0.5, 0.0)));     // E
	if ((arms & 4) != 0) best = min(best, seg_dist(q, vec2(0.0, t0), vec2(0.0, 0.5)));     // S
	if ((arms & 8) != 0) best = min(best, seg_dist(q, vec2(-t0, 0.0), vec2(-0.5, 0.0)));   // W
	if (is_turn) {
		// Arc center sits r along each arm from the corner; the minor arc
		// lives in the corner-side quadrant (both qc components on the
		// corner side of the tangent lines through the center).
		vec2 diag = (arms == 3) ? vec2(1.0, -1.0) :
		            (arms == 6) ? vec2(1.0, 1.0) :
		            (arms == 12) ? vec2(-1.0, 1.0) : vec2(-1.0, -1.0);
		vec2 qc = q - diag * radius;
		if (qc.x * diag.x <= 0.0 && qc.y * diag.y <= 0.0) {
			best = min(best, abs(length(qc) - radius));
		}
	}
	return best;
}

// Signed-distance field (cell units) to the categorical biome boundary, with
// bezier-style rounded corners. The staircase boundary is reconstructed as
// straight axis-aligned runs joined by circular fillet arcs of radius
// u_biome_border_corner_radius — visually equivalent to replacing each right
// angle with a quadratic curve, but evaluable per-fragment.
//
// Corner classification per cell (the distance is the min over boundary
// segments adjacent to the fragment's cell):
//   - An orthogonal neighbor with a different id contributes a straight run
//     along the shared edge.
//   - A diagonal neighbor contributes a corner ONLY when both adjacent
//     orthogonal neighbors also differ — the genuine corner where two runs
//     meet. A lone diagonal difference is a point-touch (the source of the
//     old half-cell "teeth") and draws nothing.
// Distances are rounded-box SDF pieces (edge segment / corner arc), min'd
// together — the field stays a true distance, so screen-space width and AA
// behave at every zoom.
float biome_border_distance(sampler2DArray tex, vec2 uv, float layer, float corner_radius) {
	vec2 grid_pos = vec2(uv.x * u_grid_size.x, clamp(uv.y * u_grid_size.y, 0.0, u_grid_size.y - 0.001));
	vec2 cell = floor(grid_pos);
	vec2 f = grid_pos - cell;                 // 0..1 inside the cell
	int center_id = biome_id_at(tex, uv, layer);

	// Sample the 4 orthogonal + 4 diagonal neighbors once.
	int n_e  = biome_id_at(tex, vec2(fract((mod(cell.x + 1.0, u_grid_size.x) + 0.5) / u_grid_size.x), (cell.y + 0.5) / u_grid_size.y), layer);
	int n_w  = biome_id_at(tex, vec2(fract((mod(cell.x - 1.0, u_grid_size.x) + 0.5) / u_grid_size.x), (cell.y + 0.5) / u_grid_size.y), layer);
	int n_n  = biome_id_at(tex, vec2(fract((cell.x + 0.5) / u_grid_size.x), (clamp(cell.y - 1.0, 0.0, u_grid_size.y - 1.0) + 0.5) / u_grid_size.y), layer);
	int n_s  = biome_id_at(tex, vec2(fract((cell.x + 0.5) / u_grid_size.x), (clamp(cell.y + 1.0, 0.0, u_grid_size.y - 1.0) + 0.5) / u_grid_size.y), layer);
	int n_ne = biome_id_at(tex, vec2(fract((mod(cell.x + 1.0, u_grid_size.x) + 0.5) / u_grid_size.x), (clamp(cell.y - 1.0, 0.0, u_grid_size.y - 1.0) + 0.5) / u_grid_size.y), layer);
	int n_nw = biome_id_at(tex, vec2(fract((mod(cell.x - 1.0, u_grid_size.x) + 0.5) / u_grid_size.x), (clamp(cell.y - 1.0, 0.0, u_grid_size.y - 1.0) + 0.5) / u_grid_size.y), layer);
	int n_se = biome_id_at(tex, vec2(fract((mod(cell.x + 1.0, u_grid_size.x) + 0.5) / u_grid_size.x), (clamp(cell.y + 1.0, 0.0, u_grid_size.y - 1.0) + 0.5) / u_grid_size.y), layer);
	int n_sw = biome_id_at(tex, vec2(fract((mod(cell.x - 1.0, u_grid_size.x) + 0.5) / u_grid_size.x), (clamp(cell.y + 1.0, 0.0, u_grid_size.y - 1.0) + 0.5) / u_grid_size.y), layer);

	// ============ CORNER-TILE CLASSIFICATION ("shape language") ============
	// Min the distance over the fragment's 4 surrounding corner tiles. q is
	// the fragment position relative to each corner point; each corner needs
	// only its 4-cell quad — the 4 quads overlap into the 9 already-fetched
	// IDs (center + 8 neighbors).
	//
	// Corner layout (world-space, y grows south / screen-down as in the
	// grid):  nw | ne      →  NW-corner quad: (nw, ne, w, c)
	//         ---+---         NE-corner quad: (n, ne, c, e)
	//         sw | se         SW-corner quad: (w, c, nw, n)
	//                         SE-corner quad: (c, e, s, se)
	// Isolated cell: 4 TURN tiles = closed rounded square. Checkerboard:
	// CROSS tile of sharp axis-aligned half-arm stubs (degenerate saddle,
	// by design). Lone diagonal: B's rounded corner, drawn consistently
	// from both sides.
	float r = clamp(corner_radius, 0.0, 0.5);
	float best = 1e6;
	best = min(best, tile_distance(f, corner_arms(n_nw, n_n, n_w, center_id), r));
	best = min(best, tile_distance(f - vec2(1.0, 0.0), corner_arms(n_n, n_ne, center_id, n_e), r));
	best = min(best, tile_distance(f - vec2(0.0, 1.0), corner_arms(n_w, center_id, n_sw, n_s), r));
	best = min(best, tile_distance(f - vec2(1.0, 1.0), corner_arms(center_id, n_e, n_s, n_se), r));
	return best;
}

// Screen-space border: distance field -> pixel width. fwidth() is fragment-
// stage only, so the caller computes cells-per-pixel there and passes it in.
// Constant on-screen width regardless of zoom; AA comes free from the
// smoothstep band. Returns 0..1 line intensity.
float biome_border_screen(sampler2DArray tex, vec2 uv, float layer, float width_px, float cells_per_px, float corner_radius) {
	float dist_cells = biome_border_distance(tex, uv, layer, corner_radius);
	// Convert the requested pixel width to cell units at this fragment, then
	// draw a 1px-wide AA band around it (half on each side of the ideal line).
	float half_w_cells = max(width_px * 0.5 * cells_per_px, 0.0);
	float aa = max(cells_per_px, 1e-4);
	return 1.0 - smoothstep(half_w_cells - aa, half_w_cells + aa, dist_cells);
}

// === LAYER-CHANNEL DEBUG MODE ===
// When u_debug_layer_mode is true, fragment() bypasses natural terrain composition
// and outputs RGB from 3 user-selected simulation layers (one per channel).
uniform bool u_debug_layer_mode = false;

// Per-channel source selector (array index = channel: 0=R, 1=G, 2=B):
//   0 = Flat 1.0    (solid white in this channel)
//   1 = Flat 0.0    (solid black in this channel)
//   2 = Float array (sample float_texture at u_channel_layer[i])
//   3 = Atomic array (sample atomic_vis_tex at u_channel_layer[i])
uniform int u_channel_src[3];      // default [0,0,0] = all Flat 1.0
uniform int u_channel_layer[3];    // z-index per channel (ignored when src is flat)
uniform float u_channel_scale[3];  // normalization scale per channel (float layers only)
uniform float u_channel_offset[3]; // normalization offset per channel (float layers only)

// Resolves a single channel to a normalized [0,1] float.
float sample_channel(int channel_idx, vec2 uv) {
	int src = u_channel_src[channel_idx];

	if (src == 0) return 1.0;   // Flat 1.0
	if (src == 1) return 0.0;   // Flat 0.0

	int layer = u_channel_layer[channel_idx];

	if (src == 2) {
		// Float array — raw values (e.g. temperature, height). Apply normalization.
		float raw = sample_smooth(float_texture, uv, float(layer));
		return clamp((raw + u_channel_offset[channel_idx]) * u_channel_scale[channel_idx], 0.0, 1.0);
	} else {
		// Atomic visual array — already normalized to [0,1] by atomic_visualizer.glsl.
		// No additional scale/offset (avoids double-normalization).
		float raw = sample_smooth(atomic_vis_tex, uv, float(layer));
		return clamp(raw, 0.0, 1.0);
	}
}

uniform float u_slope_rock_threshold = 0.5;
uniform float u_sediment_dirt_threshold = 0.1;

uniform vec3 col_rock : source_color = vec3(0.5, 0.5, 0.5);
uniform vec3 col_dirt : source_color = vec3(0.4, 0.3, 0.2);
uniform vec3 col_sand : source_color = vec3(0.8, 0.7, 0.5);
uniform vec3 col_grass_light : source_color = vec3(0.4, 0.8, 0.2);
uniform vec3 col_grass_dark : source_color = vec3(0.1, 0.4, 0.1);
uniform vec3 col_trees : source_color = vec3(0.05, 0.25, 0.05);

// vertex() intentionally removed: per the water+terrain unification refactor the sphere
// is now a flat unit sphere with NO height displacement. Land/water are distinguished
// purely in fragment color. Re-add a vertex() that displaces along NORMAL when 3D
// height representation is needed again.

void fragment() {
	float slope_x = sample_smooth(float_texture, UV, float(F_LANDSCAPE_SlopeX));
        float slope_y = sample_smooth(float_texture, UV, float(F_LANDSCAPE_SlopeY));
        float slope_mag = length(vec2(slope_x, slope_y));

        float sediment = sample_smooth(float_texture, UV, float(F_LANDSCAPE_SedimentHeight));
        float water_height = sample_smooth(float_texture, UV, float(F_WATER_WaterLiquidHeight));
	float rock_weight = smoothstep(u_slope_rock_threshold * 0.5, u_slope_rock_threshold, slope_mag);
	float dirt_weight = smoothstep(0.0, u_sediment_dirt_threshold, sediment);
	
	// Sample detail noise
	vec4 noise = texture(u_detail_noise, UV);
	float macro_fade = 1.0 - smoothstep(0.4, 0.8, u_camera_distance);
	float micro_fade = 1.0 - smoothstep(0.05, 0.2, u_camera_distance);
	
	float smooth_noise_val = mix(noise.r, noise.g, micro_fade) * macro_fade;
	float ridge_noise_val = mix(noise.b, noise.a, micro_fade) * macro_fade;
	
	float dirt_mottle = smooth_noise_val * 0.4 - 0.2 * macro_fade;
	float rock_mottle = ridge_noise_val * 0.4 - 0.2 * macro_fade;
	
	vec3 m_col_sand = clamp(col_sand + vec3(dirt_mottle), 0.0, 1.0);
	vec3 m_col_dirt = clamp(col_dirt + vec3(dirt_mottle), 0.0, 1.0);
	vec3 m_col_rock = clamp(col_rock + vec3(rock_mottle), 0.0, 1.0);
	
	vec3 terrain_color = mix(m_col_sand, m_col_dirt, dirt_weight);
	terrain_color = mix(terrain_color, m_col_rock, rock_weight);

	float grasses = sample_smooth(atomic_vis_tex, UV, float(A_FLORA_Grasses));
	float shrubs = sample_smooth(atomic_vis_tex, UV, float(A_FLORA_Shrubs));
	float trees = sample_smooth(atomic_vis_tex, UV, float(A_FLORA_TreesCanopy));

	vec3 flora_color = terrain_color;
	float total_flora = clamp(grasses + shrubs + trees, 0.0, 1.0);
	
	float flora_mottle = smooth_noise_val * 0.3 - 0.15 * macro_fade;
	vec3 m_col_grass_light = clamp(col_grass_light + vec3(flora_mottle), 0.0, 1.0);
	vec3 m_col_grass_dark = clamp(col_grass_dark + vec3(flora_mottle), 0.0, 1.0);
	vec3 m_col_trees = clamp(col_trees + vec3(flora_mottle), 0.0, 1.0);
	
	vec3 mixed_flora = mix(m_col_grass_light, m_col_grass_dark, clamp(shrubs, 0.0, 1.0));
	mixed_flora = mix(mixed_flora, m_col_trees, clamp(trees, 0.0, 1.0));
	
	// Flora weight is already organically smoothed at the simulation level via Edge Effects
	float final_flora_weight = clamp(total_flora, 0.0, 1.0);
	
	flora_color = mix(terrain_color, mixed_flora, final_flora_weight);

	vec3 color = flora_color;

	// --- Water overlay (merged from vis_water.gdshader) ---
	// water_weight fades water in only where liquid actually exists (> epsilon),
	// replacing the old transparent ALPHA approach now that land + water share one
	// opaque surface. depth_factor drives the shallow→deep gradient; ice overlays.
	float water_weight = smoothstep(0.0, 0.01, water_height);
	if (water_weight > 0.001) {
		float depth_factor = clamp((water_height - u_depth_shallow) / (u_depth_deep - u_depth_shallow), 0.0, 1.0);
		float churn = smooth_noise_val * 0.2 - 0.1 * macro_fade;
		vec3 m_col_water_shallow = clamp(col_water_shallow + vec3(churn), 0.0, 1.0);
		vec3 m_col_water_deep = clamp(col_water_deep + vec3(churn), 0.0, 1.0);
		vec3 water_color = mix(m_col_water_shallow, m_col_water_deep, depth_factor);

		float ice_volume = sample_smooth(atomic_vis_tex, UV, float(A_WATER_IceVolume));
		float ice_factor = clamp(ice_volume * 10.0, 0.0, 1.0);
		water_color = mix(water_color, col_ice, ice_factor);

		color = mix(color, water_color, water_weight);
	}

	ALBEDO = color;

	// --- Biome border overlay discrete categorical boundary ---
	// Samples the BIOME_TYPE sub-layer of atomic_vis_tex: the atomic
	// visualizer's raw pass-through decodes the packed biome byte as id/255.0,
	// so this shader reads the normalized IDs from the r16f vis array. The raw
	// r32ui atomic grid and the continuous float array are both unusable here.
	// The border is a screen-space line: u_biome_border_width_px sets its
	// on-screen width in pixels, constant across zoom (AA via fwidth).
	if (u_biome_border_strength > 0.001) {
		vec2 biome_fw = fwidth(UV) * u_grid_size;
		float cells_per_px = max(biome_fw.x, biome_fw.y);
		float border = biome_border_screen(atomic_vis_tex, UV, float(A_LANDSCAPE_BiomeType), u_biome_border_width_px, cells_per_px, u_biome_border_corner_radius);
		ALBEDO = mix(ALBEDO, col_biome_border, border * u_biome_border_strength);
	}

	// --- Cursor hover cell highlight (plan §6.2) ---
	// Outlines the discrete simulation cell currently under the cursor. Only active while
	// the picker reports a hover (u_hover_active > 0.5). Sub-pixel cells when zoomed out
	// produce no visible border, which is the desired fallback.
	if (u_hover_active > 0.5) {
		ivec2 current_cell = ivec2(floor(UV * u_grid_size));
		if (all(equal(current_cell, u_hover_cell_coord))) {
			vec2 cell_fract = fract(UV * u_grid_size);
			float edge = step(0.92, cell_fract.x) + step(cell_fract.x, 0.08)
			           + step(0.92, cell_fract.y) + step(cell_fract.y, 0.08);
			float border = clamp(edge, 0.0, 1.0);
			ALBEDO = mix(ALBEDO, col_hover_highlight, border * u_hover_highlight_strength);
		}
	}
	ROUGHNESS = 1.0;

	// === LAYER-CHANNEL DEBUG MODE ===
	// Overwrite ALBEDO last so the natural terrain code doesn't clobber it.
	if (u_debug_layer_mode) {
		ALBEDO = vec3(sample_channel(0, UV), sample_channel(1, UV), sample_channel(2, UV));
	}
}
