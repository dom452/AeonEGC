extends MeshInstance3D
## Debug-scene only (reusable as a template for production planet rendering and lighting):
## wraps `GpuWorldState`'s ping-pong `Texture2DArrayRD` buffers into `vis_terrain.gdshader`,
## generates seamless 3D spherical detail noise, and synchronizes `sun_light` with orbital time.
class_name SphereVisualiser

## Active `GameStateManager` providing `current_world_state` and orbital time progression.
@export var game_state_manager : GameStateManager
## Scene directional light oriented each frame to match the subsolar zenith in `solar_insolation_sim.glsl`.
@export var sun_light : DirectionalLight3D

@export_group("Procedural Detail")
## Smooth simplex noise generator sampled in 3D Cartesian space for low/high-frequency terrain detail (`R`/`G` channels).
@export var base_smooth_noise : FastNoiseLite
## Cellular ridge noise generator sampled in 3D Cartesian space for rocky micro-detail (`B`/`A` channels).
@export var base_ridge_noise : FastNoiseLite
## Equirectangular texture resolution (`width = height`) baked into `u_detail_noise`.
@export var detail_resolution : int = 1024

## Ping-pong `Texture2DArrayRD` wrappers exposing `float_state_textures[0..1]` to `mat_terrain`.
var runtime_texture_arrays_float : Array[Texture2DArrayRD] = []
## `Texture2DArrayRD` wrapper exposing `atomic_visual_texture` (`Binding 5`, `r16f`) to `mat_terrain`.
var runtime_texture_array_atomic : Texture2DArrayRD
## Active `ShaderMaterial` (`vis_terrain.gdshader`) bound to surface 0 of the planet mesh.
var mat_terrain : ShaderMaterial


## Waits for `game_state_manager` to be ready and initializes the terrain shader and `Texture2DArrayRD` bindings.
func _ready() -> void:
	if not game_state_manager.is_node_ready():
		await game_state_manager.ready
	setup_visualiser()


## Configures default noise resources, binds `vis_terrain.gdshader`, wraps GPU ping-pong RIDs in
## `Texture2DArrayRD`, bakes `u_detail_noise`, and connects `state_updated` to `update_shader`.
func setup_visualiser() -> void:
	# Create default smooth and cellular noise generators when not assigned in the Inspector.
	if base_smooth_noise == null:
		base_smooth_noise = FastNoiseLite.new()
		base_smooth_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		base_smooth_noise.frequency = 2.0
	if base_ridge_noise == null:
		base_ridge_noise = FastNoiseLite.new()
		base_ridge_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		base_ridge_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		base_ridge_noise.frequency = 2.0

	# Reuse the surface override ShaderMaterial if present on the mesh, or instantiate one with `vis_terrain.gdshader`.
	mat_terrain = get_surface_override_material(0) as ShaderMaterial
	if mat_terrain == null:
		mat_terrain = ShaderMaterial.new()
		mat_terrain.shader = load("res://_assets/vis_terrain.gdshader")
		set_surface_override_material(0, mat_terrain)
	elif mat_terrain.shader == null:
		mat_terrain.shader = load("res://_assets/vis_terrain.gdshader")

	game_state_manager.current_world_state.state_updated.connect(update_shader)
	
	# Wrap both ping-pong float texture array RIDs and the normalized atomic visualizer RID in `Texture2DArrayRD`.
	runtime_texture_arrays_float.resize(2)
	runtime_texture_arrays_float[0] = Texture2DArrayRD.new()
	runtime_texture_arrays_float[0].texture_rd_rid = GameStateManager.current_world_state.float_state_textures[0]
	runtime_texture_arrays_float[1] = Texture2DArrayRD.new()
	runtime_texture_arrays_float[1].texture_rd_rid = GameStateManager.current_world_state.float_state_textures[1]

	runtime_texture_array_atomic = Texture2DArrayRD.new()
	runtime_texture_array_atomic.texture_rd_rid = GameStateManager.current_world_state.atomic_visual_texture
	
	# Bake the seamless spherical detail noise texture and bind the initial read buffer.
	_generate_and_bind_detail_texture()

	update_shader(GameStateManager.current_world_state.read_world_state_index)


## Rotates `sun_light` each frame to match the subsolar hour angle and axial-tilt declination from `GameStateManager`.
func _process(_delta: float) -> void:
	if sun_light and GameStateManager.world_config:
		# Compute diurnal hour angle and seasonal solar declination matching `solar_insolation_sim.glsl`.
		var _elapsed_days : float = float(GameStateManager.elapsed_days) + GameStateManager.day_progress
		
		var time_of_day : float = GameStateManager.day_progress * TAU
		var time_of_year : float = GameStateManager.year_progress * TAU
		
		var declination : float = GameStateManager.world_config.max_axial_tilt * cos(time_of_year)
		
		var sun_yaw : float = PI - time_of_day
		var sun_pitch : float = declination
		
		var sun_dir : Vector3 = Vector3(
			cos(sun_pitch) * sin(sun_yaw),
			sin(sun_pitch),
			cos(sun_pitch) * cos(sun_yaw)
		).normalized()
		
		# Aim `sun_light` from the sun direction toward the planet origin.
		sun_light.global_transform.origin = Vector3.ZERO
		sun_light.look_at(-sun_dir, Vector3.UP)


## Samples `base_smooth_noise` and `base_ridge_noise` in 3D spherical coordinates to bake a seam-free
## `RGBA8` equirectangular detail texture and assigns it to `mat_terrain`'s `u_detail_noise` uniform.
func _generate_and_bind_detail_texture() -> void:
	# Compute 3D sampling radii for two octaves (`1x` and `4x`) of smooth and ridge noise.
	var img : Image = Image.create_empty(detail_resolution, detail_resolution, false, Image.FORMAT_RGBA8)
	
	var r_freq_1 : float = base_smooth_noise.frequency
	var r_freq_2 : float = base_smooth_noise.frequency * 4.0
	var radius_s1 : float = (float(detail_resolution) * r_freq_1) / TAU
	var radius_s2 : float = (float(detail_resolution) * r_freq_2) / TAU
	
	var r_freq_3 : float = base_ridge_noise.frequency
	var r_freq_4 : float = base_ridge_noise.frequency * 4.0
	var radius_r1 : float = (float(detail_resolution) * r_freq_3) / TAU
	var radius_r2 : float = (float(detail_resolution) * r_freq_4) / TAU
	
	var inv_w : float = TAU / float(detail_resolution)
	
	# Sample 3D noise on the unit sphere for each `(x, y)` texel so longitude wrapping has zero seam.
	for y : int in range(detail_resolution):
		var norm_y : float = (float(y) + 0.5) / float(detail_resolution)
		var phi : float = (0.5 - norm_y) * PI
		var cos_lat : float = cos(phi)
		
		var ny_s1 : float = radius_s1 * sin(phi)
		var ny_s2 : float = radius_s2 * sin(phi)
		var ny_r1 : float = radius_r1 * sin(phi)
		var ny_r2 : float = radius_r2 * sin(phi)
		
		for x : int in range(detail_resolution):
			var theta : float = (float(x) + 0.5) * inv_w
			
			var nx_s1 : float = radius_s1 * cos_lat * cos(theta)
			var nz_s1 : float = radius_s1 * cos_lat * sin(theta)
			
			var nx_s2 : float = radius_s2 * cos_lat * cos(theta)
			var nz_s2 : float = radius_s2 * cos_lat * sin(theta)
			
			var nx_r1 : float = radius_r1 * cos_lat * cos(theta)
			var nz_r1 : float = radius_r1 * cos_lat * sin(theta)
			
			var nx_r2 : float = radius_r2 * cos_lat * cos(theta)
			var nz_r2 : float = radius_r2 * cos_lat * sin(theta)
			
			var s1 : float = (base_smooth_noise.get_noise_3d(nx_s1, ny_s1, nz_s1) + 1.0) * 0.5
			var s2 : float = (base_smooth_noise.get_noise_3d(nx_s2, ny_s2, nz_s2) + 1.0) * 0.5
			var r1 : float = (base_ridge_noise.get_noise_3d(nx_r1, ny_r1, nz_r1) + 1.0) * 0.5
			var r2 : float = (base_ridge_noise.get_noise_3d(nx_r2, ny_r2, nz_r2) + 1.0) * 0.5
			
			var color : Color = Color(clampf(s1, 0.0, 1.0), clampf(s2, 0.0, 1.0), clampf(r1, 0.0, 1.0), clampf(r2, 0.0, 1.0))
			img.set_pixel(x, y, color)

	# Upload the generated Image as an ImageTexture on `mat_terrain`.
	var tex : ImageTexture = ImageTexture.create_from_image(img)
	mat_terrain.set_shader_parameter("u_detail_noise", tex)


## Binds the current readable ping-pong `float_texture` (`read_index`) and `atomic_vis_tex` to `mat_terrain`.
func update_shader(read_index : int) -> void:
	if read_index >= 0 and read_index < runtime_texture_arrays_float.size():
		var float_tex : Texture2DArrayRD = runtime_texture_arrays_float[read_index]
		var atomic_tex : Texture2DArrayRD = runtime_texture_array_atomic
		
		mat_terrain.set_shader_parameter("float_texture", float_tex)
		mat_terrain.set_shader_parameter("atomic_vis_tex", atomic_tex)
