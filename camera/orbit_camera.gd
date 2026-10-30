## Spherical orbit camera that rotates around a target node, handles zoom clamping,
## and publishes camera distance, UV target, and UV velocity to global shader parameters.
extends Camera3D

## Central 3D node around which the camera orbits (typically the planet mesh).
@export var target : Node3D
## Minimum radial distance from the planet center in world units (unit sphere surface is `1.0`).
@export var min_radius : float = 1.1
## Maximum radial distance from the planet center in world units when zoomed out.
@export var max_radius : float = 1.67
## Radial distance step applied per scroll-wheel zoom input.
@export var zoom_speed : float = 0.1
## Radians of yaw/pitch rotation applied per pixel of mouse drag when orbiting.
@export var orbit_sensitivity : float = 0.005
## Exponential smoothing factor (`lerp_speed * delta`) for yaw, pitch, and radius interpolation.
@export var lerp_speed : float = 10.0

## Target yaw angle in radians around the Y axis.
var _target_yaw : float = 0.0
## Target pitch angle in radians clamped inside `(-PI/2, +PI/2)`.
var _target_pitch : float = 0.0
## Target radial distance from `target` in world units.
var _target_radius : float = 1.75

## Smoothed current yaw angle in radians.
var _yaw : float = 0.0
## Smoothed current pitch angle in radians.
var _pitch : float = 0.0
## Smoothed current radial distance from `target` in world units.
var _radius : float = 1.75

## Previous frame's equirectangular UV coordinate used to compute per-second UV velocity.
var _prev_uv : Vector2 = Vector2.ZERO


## Initializes spherical coordinates (`_radius`, `_yaw`, `_pitch`) and `_prev_uv` from the starting transform.
func _ready() -> void:
	# Derive initial orbit radius from the starting local position length.
	_radius = position.length()
	_target_radius = _radius
	
	# Derive initial yaw and pitch angles from the normalized starting position vector.
	var dir : Vector3 = position.normalized()
	_yaw = atan2(dir.x, dir.z)
	_pitch = asin(dir.y)
	
	_target_yaw = _yaw
	_target_pitch = _pitch
	
	# Seed `_prev_uv` with the initial equirectangular UV to prevent a velocity spike on frame 1.
	var initial_u : float = wrapf(_yaw / TAU, 0.0, 1.0)
	var initial_v : float = 0.5 - (_pitch / PI)
	_prev_uv = Vector2(initial_u, initial_v)


## Updates `_target_yaw` and clamped `_target_pitch` from mouse drag motion while `"camera_orbit"` is held.
func _unhandled_input(event: InputEvent) -> void:
	# Accumulate yaw and pitch deltas from relative mouse movement while the orbit action is pressed.
	if event is InputEventMouseMotion and Input.is_action_pressed("camera_orbit"):
		var m_event : InputEventMouseMotion = event as InputEventMouseMotion
		_target_yaw -= m_event.relative.x * orbit_sensitivity
		_target_pitch += m_event.relative.y * orbit_sensitivity
		
		# Clamp pitch just short of the poles to prevent gimbal lock.
		_target_pitch = clamp(_target_pitch, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)


## Interpolates spherical orbit coordinates, updates the camera's 3D transform, and writes camera shader globals.
func _process(delta: float) -> void:
	# Step `_target_radius` inward or outward on zoom actions within `[min_radius, max_radius]`.
	if Input.is_action_just_pressed("camera_zoom_in"):
		_target_radius = clamp(_target_radius - zoom_speed, min_radius, max_radius)
	if Input.is_action_just_pressed("camera_zoom_out"):
		_target_radius = clamp(_target_radius + zoom_speed, min_radius, max_radius)

	# Interpolate current spherical coordinates toward their target values.
	_yaw = lerp_angle(_yaw, _target_yaw, lerp_speed * delta)
	_pitch = lerp(_pitch, _target_pitch, lerp_speed * delta)
	_radius = lerp(_radius, _target_radius, lerp_speed * delta)
	
	# Convert spherical `(radius, pitch, yaw)` to a Cartesian offset around `target` and orient the camera.
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
	
	# Compute surface distance, normalized zoom percentage, and equirectangular UV under the camera.
	var dist_to_surface : float = max(0.0, _radius - 1.0)
	var zoom_pct : float = clamp((_radius - min_radius) / (max_radius - min_radius), 0.0, 1.0)
	
	var current_u : float = wrapf(_yaw / TAU, 0.0, 1.0)
	var current_v : float = 0.5 - (_pitch / PI)
	var current_uv : Vector2 = Vector2(current_u, current_v)
	
	# Compute seam-wrapped UV velocity per second from the frame-to-frame UV delta.
	var uv_velocity : Vector2 = current_uv - _prev_uv
	if uv_velocity.x > 0.5:
		uv_velocity.x -= 1.0
	elif uv_velocity.x < -0.5:
		uv_velocity.x += 1.0
	uv_velocity /= delta
	
	_prev_uv = current_uv
	
	# Extrapolate next-frame and 1-second-ahead UV coordinates with X wrapping and Y pole clamping.
	var uv_next_frame : Vector2 = current_uv + (uv_velocity * delta)
	uv_next_frame.x = wrapf(uv_next_frame.x, 0.0, 1.0)
	uv_next_frame.y = clamp(uv_next_frame.y, 0.0, 1.0)
	
	var uv_1s : Vector2 = current_uv + (uv_velocity * 1.0)
	uv_1s.x = wrapf(uv_1s.x, 0.0, 1.0)
	uv_1s.y = clamp(uv_1s.y, 0.0, 1.0)
	
	# Publish camera distance, UV coordinates, and world-space vectors to global shader parameters.
	RenderingServer.global_shader_parameter_set(StringName("u_camera_distance"), dist_to_surface)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_zoom_pct"), zoom_pct)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_target_uv"), current_uv)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_uv_velocity"), uv_velocity)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_target_uv_next_frame"), uv_next_frame)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_target_uv_1s"), uv_1s)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_world_pos"), global_position)
	RenderingServer.global_shader_parameter_set(StringName("u_camera_dir_world"), -global_transform.basis.z)
