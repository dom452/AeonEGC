extends MeshInstance3D
class_name SphereVisualiser

@export var game_state_manager : GameStateManager
@export var sun_light : DirectionalLight3D

@export_group("Procedural Detail")
@export var base_smooth_noise : FastNoiseLite
@export var base_ridge_noise : FastNoiseLite
@export var detail_resolution : int = 1024

var runtime_texture_arrays_float : Array[Texture2DArrayRD] = []
var runtime_texture_array_atomic : Texture2DArrayRD
var mat_terrain : ShaderMaterial

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if not game_state_manager.is_node_ready():
		await game_state_manager.ready
	setup_visualiser()

func setup_visualiser() -> void:
	if base_smooth_noise == null:
		base_smooth_noise = FastNoiseLite.new()
		base_smooth_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		base_smooth_noise.frequency = 2.0
	if base_ridge_noise == null:
		base_ridge_noise = FastNoiseLite.new()
		base_ridge_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
		base_ridge_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		base_ridge_noise.frequency = 2.0

	# Land + water are unified in a single vis_terrain shader — no separate water mesh
	# is instantiated anymore. Reuse the scene-assigned override material when the
	# editor has already wired one (keeps designer-tweakable shader params live);
	# otherwise build one from the shader so the node still works standalone.
	mat_terrain = get_surface_override_material(0) as ShaderMaterial
	if mat_terrain == null:
		mat_terrain = ShaderMaterial.new()
		mat_terrain.shader = load("res://_assets/vis_terrain.gdshader")
		set_surface_override_material(0, mat_terrain)
	elif mat_terrain.shader == null:
		mat_terrain.shader = load("res://_assets/vis_terrain.gdshader")

	game_state_manager.current_world_state.state_updated.connect(update_shader)
	
	runtime_texture_arrays_float.resize(2)
	runtime_texture_arrays_float[0] = Texture2DArrayRD.new()
	runtime_texture_arrays_float[0].texture_rd_rid = GameStateManager.current_world_state.float_state_textures[0]
	runtime_texture_arrays_float[1] = Texture2DArrayRD.new()
	runtime_texture_arrays_float[1].texture_rd_rid = GameStateManager.current_world_state.float_state_textures[1]

	runtime_texture_array_atomic = Texture2DArrayRD.new()
	runtime_texture_array_atomic.texture_rd_rid = GameStateManager.current_world_state.atomic_visual_texture
	
	_generate_and_bind_detail_texture()

	update_shader(GameStateManager.current_world_state.read_world_state_index)

func _process(_delta: float) -> void:
	if sun_light and GameStateManager.world_config:
		# Mirror the exact math from solar_insolation_sim.glsl using the new GameStateManager properties
		var _elapsed_days : float = float(GameStateManager.elapsed_days) + GameStateManager.day_progress
		
		var time_of_day : float = GameStateManager.day_progress * TAU
		var time_of_year : float = GameStateManager.year_progress * TAU
		
		# Declination is the latitude of the sun due to axial tilt
		var declination : float = GameStateManager.world_config.max_axial_tilt * cos(time_of_year)
		
		# The shader uses: hour_angle = time_of_day + longitude - PI
		# Zenith occurs when hour_angle == 0, so longitude = PI - time_of_day
		var sun_yaw : float = PI - time_of_day
		var sun_pitch : float = declination
		
		var sun_dir : Vector3 = Vector3(
			cos(sun_pitch) * sin(sun_yaw),
			sin(sun_pitch),
			cos(sun_pitch) * cos(sun_yaw)
		).normalized()
		
		# Point the light opposite to the sun's direction (so it shines FROM the sun TO the origin)
		sun_light.global_transform.origin = Vector3.ZERO
		sun_light.look_at(-sun_dir, Vector3.UP)

func _generate_and_bind_detail_texture() -> void:
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

	var tex : ImageTexture = ImageTexture.create_from_image(img)
	mat_terrain.set_shader_parameter("u_detail_noise", tex)
	
func update_shader(read_index : int) -> void:
	#var current_read_idx : int = GameStateManager.current_world_state.read_world_state_index
	if read_index >= 0 and read_index < runtime_texture_arrays_float.size():
		var float_tex : Texture2DArrayRD = runtime_texture_arrays_float[read_index]
		var atomic_tex : Texture2DArrayRD = runtime_texture_array_atomic
		
		mat_terrain.set_shader_parameter("float_texture", float_tex)
		mat_terrain.set_shader_parameter("atomic_vis_tex", atomic_tex)
