extends Camera3D

## The central node the camera will orbit around (e.g., the planet mesh).
@export var target : Node3D
## The closest the camera can get to the center of the planet. (Sphere radius is 1.0).
@export var min_radius : float = 1.1
## The furthest the camera can zoom out from the planet.
@export var max_radius : float = 1.67
## How much the radius changes per scroll wheel step.
@export var zoom_speed : float = 0.1
## Mouse sensitivity when dragging to orbit the camera.
@export var orbit_sensitivity : float = 0.005
## Smoothing factor for camera movement and zoom. Higher is snappier, lower is floatier.
@export var lerp_speed : float = 10.0

var _target_yaw : float = 0.0
var _target_pitch : float = 0.0
var _target_radius : float = 1.75

var _yaw : float = 0.0
var _pitch : float = 0.0
var _radius : float = 1.75

var _prev_uv : Vector2 = Vector2.ZERO

func _ready() -> void:
	# Calculate initial radius
	_radius = position.length()
	_target_radius = _radius
	
	# Calculate initial yaw/pitch based on starting position
	var dir : Vector3 = position.normalized()
	_yaw = atan2(dir.x, dir.z)
	_pitch = asin(dir.y)
	
	_target_yaw = _yaw
	_target_pitch = _pitch
	
	# Initialize previous UV to prevent a velocity spike on frame 1
	var initial_u : float = wrapf(_yaw / TAU, 0.0, 1.0)
	var initial_v : float = 0.5 - (_pitch / PI)
	_prev_uv = Vector2(initial_u, initial_v)

func _unhandled_input(event: InputEvent) -> void:
	# Handle mouse motion for orbiting, gated by the Input Map action
	if event is InputEventMouseMotion and Input.is_action_pressed("camera_orbit"):
		var m_event : InputEventMouseMotion = event as InputEventMouseMotion
		_target_yaw -= m_event.relative.x * orbit_sensitivity
		_target_pitch += m_event.relative.y * orbit_sensitivity
		
		# Clamp pitch to avoid gimbal lock (flipping over the poles)
		_target_pitch = clamp(_target_pitch, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)

func _process(delta: float) -> void:
	# Handle zooming via Input Map actions
	if Input.is_action_just_pressed("camera_zoom_in"):
		_target_radius = clamp(_target_radius - zoom_speed, min_radius, max_radius)
	if Input.is_action_just_pressed("camera_zoom_out"):
		_target_radius = clamp(_target_radius + zoom_speed, min_radius, max_radius)

	# Smoothly interpolate current values towards targets
	_yaw = lerp_angle(_yaw, _target_yaw, lerp_speed * delta)
	_pitch = lerp(_pitch, _target_pitch, lerp_speed * delta)
	_radius = lerp(_radius, _target_radius, lerp_speed * delta)
	
	# Convert spherical coordinates to Cartesian
	var offset : Vector3 = Vector3(
		_radius * cos(_pitch) * sin(_yaw),
		_radius * sin(_pitch),
		_radius * cos(_pitch) * cos(_yaw)
	)
	
	var target_pos : Vector3 = Vector3.ZERO
	if target != null:
		target_pos = target.global_position
		
	global_position = target_pos + offset
	look_at(target_pos, Vector3.UP)
	
	# --- SHADER GLOBALS CALCULATION ---
	
	var dist_to_surface : float = max(0.0, _radius - 1.0)
	var zoom_pct : float = clamp((_radius - min_radius) / (max_radius - min_radius), 0.0, 1.0)
	
	# Calculate UV coordinate based on equirectangular projection
	var current_u : float = wrapf(_yaw / TAU, 0.0, 1.0)
	var current_v : float = 0.5 - (_pitch / PI)
	var current_uv : Vector2 = Vector2(current_u, current_v)
	
	# Calculate UV velocity (per second) and handle wrapping at the seam (U = 0.0 to 1.0)
	var uv_velocity : Vector2 = current_uv - _prev_uv
	if uv_velocity.x > 0.5:
		uv_velocity.x -= 1.0
	elif uv_velocity.x < -0.5:
		uv_velocity.x += 1.0
	uv_velocity /= delta
	
	_prev_uv = current_uv
	
	# Predictions
	var uv_next_frame : Vector2 = current_uv + (uv_velocity * delta)
	uv_next_frame.x = wrapf(uv_next_frame.x, 0.0, 1.0)
	uv_next_frame.y = clamp(uv_next_frame.y, 0.0, 1.0) # Latitude clamps at poles
	
	var uv_1s : Vector2 = current_uv + (uv_velocity * 1.0)
	uv_1s.x = wrapf(uv_1s.x, 0.0, 1.0)
	uv_1s.y = clamp(uv_1s.y, 0.0, 1.0)
	
	# Update all globals
	RenderingServer.global_shader_parameter_set(StringName("u_camera_distance"), dist_to_surface)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_zoom_pct"), zoom_pct)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_target_uv"), current_uv)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_uv_velocity"), uv_velocity)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_target_uv_next_frame"), uv_next_frame)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_target_uv_1s"), uv_1s)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_world_pos"), global_position)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_dir_world"), -global_transform.basis.z)
