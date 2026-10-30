extends Node
## Raycasts the mouse cursor against an analytical unit sphere to resolve equirectangular
## UV coordinates, discrete grid cells, shader hover globals, and player spell click events.
class_name SphereCursorPicker

## Emitted when hover starts, hover stops, or the hovered discrete grid cell changes.
signal hover_changed(data: SphereHoverData)

## Emitted when the cursor enters a new discrete grid cell (including initial hover entry).
signal cell_entered(cell: Vector2i, uv: Vector2)

## Emitted when the cursor leaves a previously hovered discrete grid cell or exits the sphere.
signal cell_exited(cell: Vector2i)

## Emitted on mouse button press while hovering a cell with a non-null `spell`, carrying the
## spell's `ACTION_KEY` bitmask (`1 << slot` or `WIPE_ALL`) and signed cost (`>= 0` place, `< 0` dispel).
signal cell_clicked(cell: Vector2i, uv: Vector2, action_key : int, action_value : float)

## Active `Camera3D` used to project viewport mouse coordinates into a 3D pick ray.
@export var camera : Camera3D

## Planet node whose transform defines the local space of the analytical sphere (`Transform3D.IDENTITY` if null).
@export var planet : Node3D

## Radius of the analytical sphere in `planet`'s local coordinate space.
@export var sphere_radius : float = 1.0

## Simulation grid dimensions (`Vector2i(world_width, world_height)`) used to quantize UV coordinates into cells.
@export var grid_size : Vector2i = Vector2i(512, 512)

## When true, prints a one-line summary to the console on cell hover transitions and clicks.
@export var debug_log : bool = false

## Currently selected `PlayerSpell` cast on click; when null, clicks do not emit `cell_clicked`.
@export var spell : PlayerSpell 

## Live per-frame hover telemetry container updated while hovering and cleared on exit.
var hover_data : SphereHoverData

## True while the cursor ray currently intersects the planetary sphere.
var _is_hovering : bool = false
## Discrete grid cell coordinates from the previous frame (`Vector2i(-1, -1)` when not hovering).
var _prev_cell : Vector2i = Vector2i(-1, -1)

## True once `init_cursor_picker()` has bound `camera`, `planet`, and `grid_size` from `GameStateManager`.
var _is_initialised : bool = false


## Allocates `hover_data` and attempts initial binding via `init_cursor_picker()`.
func _ready() -> void:
	hover_data = SphereHoverData.new()
	init_cursor_picker()


## Binds `camera`, `planet`, and `grid_size` from `GameStateManager` and enables per-frame picking.
func init_cursor_picker() -> void:
	# Pull active camera, planet mesh, and world dimensions from GameStateManager.
	var wc : WorldConfig = GameStateManager.world_config
	camera = GameStateManager.instance.camera
	planet = GameStateManager.instance.world
	if wc == null or wc.world_width <= 0 or wc.world_height <= 0:
		push_error("SphereCursorPicker.init_cursor_picker(): WorldConfig not ready or has invalid dimensions.")
		return
	grid_size = Vector2i(wc.world_width, wc.world_height)
	_is_initialised = true


## Projects the mouse cursor into a 3D ray each frame, intersects the planet sphere, updates `hover_data`
## and shader hover uniforms, and emits cell enter/exit signals on discrete cell changes.
func _process(_delta: float) -> void:
	# Skip picking until `init_cursor_picker()` has succeeded and a valid camera is assigned.
	if not _is_initialised:
		return

	if not is_instance_valid(camera):
		push_error("SphereCursorPicker: no valid Camera3D assigned. Aborting pick.")
		return

	# Resolve mouse coordinates in the camera's own viewport space (scaling through SubViewportContainer if present).
	var cam_vp : Viewport = camera.get_viewport()
	if cam_vp == null:
		return

	var mouse_pos : Vector2
	if cam_vp is SubViewport:
		var sv : SubViewport = cam_vp as SubViewport
		var parent : Node = sv.get_parent()
		if parent is SubViewportContainer:
			var svc : SubViewportContainer = parent as SubViewportContainer
			var local_mouse : Vector2 = svc.get_local_mouse_position()
			var svc_size : Vector2 = svc.size
			if svc_size.x > 0.0 and svc_size.y > 0.0:
				mouse_pos = local_mouse * (Vector2(sv.size) / svc_size)
			else:
				mouse_pos = local_mouse
		else:
			mouse_pos = sv.get_mouse_position()
	else:
		mouse_pos = cam_vp.get_mouse_position()

	# Clear hover state if the cursor lies outside the camera viewport bounds.
	if not _is_mouse_in_viewport(cam_vp, mouse_pos):
		_clear_hover()
		return

	# Project the 2D viewport mouse position into a world-space ray origin and unit direction.
	var ray_origin : Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir : Vector3 = camera.project_ray_normal(mouse_pos)

	# Transform the pick ray into the planet's local coordinate space and intersect the analytical sphere.
	var inv : Transform3D = Transform3D.IDENTITY
	var basis_inv : Basis = Basis.IDENTITY
	if is_instance_valid(planet):
		inv = planet.global_transform.affine_inverse()
		basis_inv = planet.global_transform.basis.inverse()

	var local_origin : Vector3 = inv * ray_origin
	var local_dir : Vector3 = (basis_inv * ray_dir).normalized()

	var hit : Dictionary = ray_sphere_intersect(local_origin, local_dir, sphere_radius)
	if hit.is_empty():
		_clear_hover()
		return

	var n_local : Vector3 = hit["normal"]
	hover_data.hit_point_local = hit["point"]

	# Convert the local surface normal into equirectangular UV, discrete cell coordinates, and lat/lon degrees.
	hover_data.uv = sphere_normal_to_uv(n_local)
	hover_data.cell_coord = uv_to_cell_coord(hover_data.uv, grid_size)
	hover_data.continuous_cell = Vector2(hover_data.uv.x * float(grid_size.x), hover_data.uv.y * float(grid_size.y))
	hover_data.cell_index = hover_data.cell_coord.y * grid_size.x + hover_data.cell_coord.x
	var latlon : Vector2 = uv_to_lat_lon(hover_data.uv)
	hover_data.latitude_deg = latlon.x
	hover_data.longitude_deg = latlon.y

	# Transform local hit point and surface normal back to world space.
	if is_instance_valid(planet):
		hover_data.hit_point_world = planet.global_transform * hover_data.hit_point_local
		hover_data.surface_normal = (planet.global_transform.basis * n_local).normalized()
	else:
		hover_data.hit_point_world = hover_data.hit_point_local
		hover_data.surface_normal = n_local

	hover_data.is_hovering = true

	# Publish hover cell, active flag, and UV to global shader parameters for terrain highlighting.
	RenderingServer.global_shader_parameter_set(
		StringName("u_hover_cell_coord"), 
		hover_data.cell_coord
		)
	RenderingServer.global_shader_parameter_set(
		StringName("u_hover_active"), 
		float(hover_data.is_hovering)
		)
	RenderingServer.global_shader_parameter_set(
		StringName("u_hover_uv"), 
		hover_data.uv
		)

	# Emit enter/exit/changed signals when hover starts or crosses into a different discrete grid cell.
	if not _is_hovering:
		_is_hovering = true
		_prev_cell = hover_data.cell_coord
		hover_changed.emit(hover_data)
		cell_entered.emit(hover_data.cell_coord, hover_data.uv)
		if debug_log:
			_print_hover("ENTER", hover_data.cell_coord, hover_data.uv, latlon)
	else:
		if hover_data.cell_coord != _prev_cell:
			var old : Vector2i = _prev_cell
			_prev_cell = hover_data.cell_coord
			cell_exited.emit(old)
			cell_entered.emit(hover_data.cell_coord, hover_data.uv)
			hover_changed.emit(hover_data)
			if debug_log:
				_print_hover("MOVE", hover_data.cell_coord, hover_data.uv, latlon)


## Emits `cell_clicked` with the active `spell`'s bitmask and signed cost when a mouse button is pressed while hovering.
func _input(event: InputEvent) -> void:
	# Relay mouse-button presses on a hovered cell when an active PlayerSpell is selected.
	if event is InputEventMouseButton:
		var mb : InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed and _is_hovering:
			if spell:
				# Encode placement spells as non-negative cost and dispel tools as strictly negative (`-1.0 - cost` avoids `-0.0`).
				var relayed_cost : float = absf(float(spell.cost))
				print(spell.spell_name)
				if spell.is_dispel:
					relayed_cost = -1.0 - relayed_cost
				cell_clicked.emit(hover_data.cell_coord, hover_data.uv, spell.get_action_bit_pattern(), relayed_cost)
				if debug_log:
					_print_hover(
						"CLICK[%d]" % mb.button_index, 
						hover_data.cell_coord, 
						hover_data.uv,
						Vector2(hover_data.latitude_deg, hover_data.longitude_deg)
					)


## Resets hover state when the cursor misses the sphere or leaves the viewport and emits `cell_exited` and `hover_changed`.
func _clear_hover() -> void:
	if not _is_hovering:
		return
	# Clear active hover flags and notify listeners of the exited cell.
	_is_hovering = false
	var old : Vector2i = _prev_cell
	_prev_cell = Vector2i(-1, -1)

	hover_data.is_hovering = false
	hover_data.cell_index = 0

	cell_exited.emit(old)
	hover_changed.emit(hover_data)


## Returns the mouse position in `vp`'s local coordinate system.
static func get_viewport_mouse(vp : Viewport) -> Vector2:
	return vp.get_mouse_position()


## Returns true if `mouse_pos` lies inside the pixel bounds of `vp`.
static func _is_mouse_in_viewport(vp : Viewport, mouse_pos : Vector2) -> bool:
	var size : Vector2 = _get_viewport_size(vp)
	return Rect2(Vector2.ZERO, size).has_point(mouse_pos)


## Returns the pixel dimensions of `vp` across `SubViewport`, `Window`, and generic `Viewport` subclasses.
static func _get_viewport_size(vp : Viewport) -> Vector2:
	if vp is SubViewport:
		return Vector2((vp as SubViewport).size)
	var as_window : Window = vp as Window
	if as_window != null:
		return Vector2(as_window.size)
	return vp.get_visible_rect().size


## Intersects a normalized local ray `(ray_origin, ray_dir)` against an origin-centered sphere of `radius`,
## returning `{"t": float, "point": Vector3, "normal": Vector3}` or `{}` on a miss.
static func ray_sphere_intersect(ray_origin : Vector3, ray_dir : Vector3, radius : float) -> Dictionary:
	# Solve the quadratic ray-sphere equation `t^2 + 2(O.D)t + (|O|^2 - R^2) = 0`.
	var h : float = ray_origin.dot(ray_dir)
	var c : float = ray_origin.dot(ray_origin) - radius * radius
	var disc : float = h * h - c
	if disc < 0.0:
		return {}

	# Select the nearest positive intersection `t` along the ray.
	var sqrt_disc : float = sqrt(disc)
	var t : float = -h - sqrt_disc
	if t < 0.0:
		t = -h + sqrt_disc
		if t < 0.0:
			return {}

	var point : Vector3 = ray_origin + ray_dir * t
	return {
		"t": t,
		"point": point,
		"normal": point.normalized(),
	}


## Maps a local unit sphere normal to an equirectangular UV in `[0, 1)^2` (`+Y` north pole → `V = 0`,
## `-Y` south pole → `V = 1`, `atan2(-Z, X)` matching the planet mesh's longitude winding).
static func sphere_normal_to_uv(normal : Vector3) -> Vector2:
	# Convert Y elevation to latitude `phi` and map north-to-south into `V` in `[0.0, 1.0]`.
	var ny : float = clampf(normal.y, -1.0, 1.0)
	var phi : float = asin(ny)
	var v : float = 0.5 - (phi / PI)

	# Compute longitude `theta = atan2(-z, x)` to match the sphere mesh's U winding direction.
	var theta : float = atan2(-normal.z, normal.x)
	var u : float = wrapf(theta / TAU, 0.0, 1.0)

	return Vector2(u, v)


## Quantizes an equirectangular `uv` in `[0, 1]^2` into a clamped discrete grid cell `Vector2i(x, y)`.
static func uv_to_cell_coord(uv : Vector2, grid : Vector2i) -> Vector2i:
	var cx : int = clampi(int(uv.x * float(grid.x)), 0, grid.x - 1)
	var cy : int = clampi(int(uv.y * float(grid.y)), 0, grid.y - 1)
	return Vector2i(cx, cy)


## Converts an equirectangular `uv` into `Vector2(latitude_deg, longitude_deg)` (`[-90..+90]`, `[-180..+180]`).
static func uv_to_lat_lon(uv : Vector2) -> Vector2:
	var latitude : float = (0.5 - uv.y) * 180.0
	var longitude : float = (uv.x * 360.0) - 180.0
	return Vector2(latitude, longitude)


## Prints a one-line diagnostic summary of a hover or click event when `debug_log` is enabled.
func _print_hover(tag : String, cell : Vector2i, uv : Vector2, latlon : Vector2) -> void:
	print("[%s] cell=(%d, %d) idx=%d  UV=(%.4f, %.4f)  Lat=%.2f° Lon=%.2f°" % [
		tag, cell.x, cell.y, cell.y * grid_size.x + cell.x,
		uv.x, uv.y, latlon.x, latlon.y,
	])
