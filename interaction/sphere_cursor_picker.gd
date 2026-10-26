extends Node
class_name SphereCursorPicker

## Detects cursor hover over the planetary sphere and resolves the surface point to an
## equirectangular UV coordinate and the underlying Eulerian simulation cell.
##
## Picking plan. Heightmap displacement is intentionally IGNORED for now;
## the analytical ray-sphere test assumes a perfect unit sphere of radius `sphere_radius`.
##
## This is a plain Node — attach it anywhere in the scene and assign `camera` + `planet`.
## Call init_cursor_picker() once GameStateManager is ready (mirrors world_simulator's
## initialise_sim_layers pattern). _process early-exits until init has run.

# ============================================================
#  Signals  (plan §4.1)
# ============================================================

## Fired whenever hover state changes: hover starts, hover stops, or the discrete cell changes.
## For continuous sub-cell UV between cell changes, read `hover_data` directly each frame.
signal hover_changed(data: SphereHoverData)

## Fired when the cursor enters a new discrete grid cell (also fires on the first hover).
signal cell_entered(cell: Vector2i, uv: Vector2)

## Fired when the cursor leaves a previously-entered discrete grid cell (also fires on hover stop).
signal cell_exited(cell: Vector2i)

## Fired on a mouse-button press while hovering a cell. `action_key` carries the
## spell's action bit pattern (see PlayerSpell.get_action_bit_pattern()): 1u << slot
## for placements, the target's bit for selective dispels, or WIPE_ALL (all bits) for
## a whole-cell wipe. 0 only when a consumer emits without a spell — so 0 unambiguously
## means "no action" on the wire. `action_value` sign encodes place (>= 0) vs.
## wipe (< 0).
signal cell_clicked(cell: Vector2i, uv: Vector2, action_key : int, action_value : float)


# ============================================================
#  Exports
# ============================================================

## The Camera3D used to generate the pick ray. Required — this node is no longer a camera itself.
@export var camera : Camera3D

## The planet node whose mesh we ray-test against. If null, the sphere is assumed centered
## at world origin (Transform3D.IDENTITY) with radius `sphere_radius`.
@export var planet : Node3D

## Radius of the analytical sphere, in the planet's LOCAL space (plan §2.3 uses R = 1.0).
@export var sphere_radius : float = 1.0

## Simulation grid resolution used for UV→cell quantization. Defaults to 512×512 to match
## `vis_terrain.gdshader`'s `u_grid_size`. init_cursor_picker() overrides this from WorldConfig.
@export var grid_size : Vector2i = Vector2i(512, 512)

## If true, prints a concise summary to the Output panel on cell change and on click.
## This is console-only feedback for verifying the math; it is NOT the step-5 telemetry UI.
@export var debug_log : bool = false

## this is the currently selected spell. If no spell is selected, this is null. 
## if null, the cell clicked signal will not emit. 
@export var spell : PlayerSpell 

# ============================================================
#  Runtime State
# ============================================================

## The live hover result. Always up-to-date each frame while hovering; cleared on hover stop.
var hover_data : SphereHoverData

var _is_hovering : bool = false
var _prev_cell : Vector2i = Vector2i(-1, -1)

## Set true by init_cursor_picker(). _process early-exits until this is true.
var _is_initialised : bool = false


## Allocates the live hover-data container. Called once on node entry.
func _ready() -> void:
	hover_data = SphereHoverData.new()
	init_cursor_picker()


## One-time initialisation. Mirrors world_simulator.initialise_sim_layers(): pulls world
## dimensions from the live WorldConfig exactly once. Must be called externally (by whichever
## system owns/spawns this picker) once GameStateManager is ready. _process early-exits until
## this has run and set _is_initialised = true. If WorldConfig isn't ready yet, it logs and
## leaves _is_initialised false so the caller can retry.
func init_cursor_picker() -> void:
	var wc : WorldConfig = GameStateManager.world_config
	camera = GameStateManager.instance.camera
	planet = GameStateManager.instance.world
	if wc == null or wc.world_width <= 0 or wc.world_height <= 0:
		push_error("SphereCursorPicker.init_cursor_picker(): WorldConfig not ready or has invalid dimensions.")
		return
	grid_size = Vector2i(wc.world_width, wc.world_height)
	_is_initialised = true


func _process(_delta: float) -> void:
	# Mirror world_simulator: do nothing until init_cursor_picker() has been called.
	if not _is_initialised:
		return

	if not is_instance_valid(camera):
		push_error("SphereCursorPicker: no valid Camera3D assigned. Aborting pick.")
		return

	# --- 2.1 Viewport mouse coordinate normalization (flexible SubViewport / full Window) ---
	# IMPORTANT: camera.project_ray_origin/normal expect mouse coordinates in the CAMERA's
	# own viewport space, not this node's viewport. When the camera lives inside a
	# SubViewport (as in World_Gen.tscn, where the 3D scene sits under a
	# SubViewportContainer), the root Window's mouse position is in the wrong space: a
	# different scale plus a per-pixel offset. Passing it straight to project_ray_* makes
	# the cast ray drift further off-target toward the far edge of the viewport until it
	# leaves the frustum and the ray-sphere test misses — which looks exactly like "the
	# right half of the sphere never registers a hover". Resolve the mouse position in the
	# camera's viewport space instead.
	var cam_vp : Viewport = camera.get_viewport()
	if cam_vp == null:
		return

	var mouse_pos : Vector2
	if cam_vp is SubViewport:
		var sv : SubViewport = cam_vp as SubViewport
		var parent : Node = sv.get_parent()
		if parent is SubViewportContainer:
			# SubViewportContainer stretches the SubViewport's render to fit the container,
			# so map the container-local mouse position back into SubViewport pixel space.
			var svc : SubViewportContainer = parent as SubViewportContainer
			var local_mouse : Vector2 = svc.get_local_mouse_position()
			var svc_size : Vector2 = svc.size
			if svc_size.x > 0.0 and svc_size.y > 0.0:
				mouse_pos = local_mouse * (Vector2(sv.size) / svc_size)
			else:
				# Container not laid out yet — fall back to unscaled local coords.
				mouse_pos = local_mouse
		else:
			# SubViewport without a SubViewportContainer parent: rely on its own tracking.
			mouse_pos = sv.get_mouse_position()
	else:
		# Camera is in the root Window (or any non-SubViewport viewport): mouse position
		# is already in the correct space.
		mouse_pos = cam_vp.get_mouse_position()

	if not _is_mouse_in_viewport(cam_vp, mouse_pos):
		_clear_hover()
		return

	# --- 2.2 Camera 3D ray generation ---
	var ray_origin : Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir : Vector3 = camera.project_ray_normal(mouse_pos) # Normalized

	# --- 2.3 Analytical ray-sphere intersection (ignoring heightmap displacement) ---
	# Transform the ray into the planet's local space to support arbitrary sphere transforms.
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

	# --- 2.4 Spherical-to-equirectangular UV mapping ---
	hover_data.uv = sphere_normal_to_uv(n_local)

	# --- 2.5 UV to Eulerian grid cell & geographic coordinates ---
	hover_data.cell_coord = uv_to_cell_coord(hover_data.uv, grid_size)
	hover_data.continuous_cell = Vector2(hover_data.uv.x * float(grid_size.x), hover_data.uv.y * float(grid_size.y))
	hover_data.cell_index = hover_data.cell_coord.y * grid_size.x + hover_data.cell_coord.x
	var latlon : Vector2 = uv_to_lat_lon(hover_data.uv)
	hover_data.latitude_deg = latlon.x
	hover_data.longitude_deg = latlon.y

	# World-space hit point & normal (for any future 3D reticle; not used for UV).
	if is_instance_valid(planet):
		hover_data.hit_point_world = planet.global_transform * hover_data.hit_point_local
		hover_data.surface_normal = (planet.global_transform.basis * n_local).normalized()
	else:
		hover_data.hit_point_world = hover_data.hit_point_local
		hover_data.surface_normal = n_local

	# Refresh the live hover_data object in place.
	hover_data.is_hovering = true

	# --- write to global shader uniforms for visualisation ---
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

	# --- Discrete cell change detection & signals ---
	if not _is_hovering:
		# Hover just started.
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
		# else: same cell, sub-cell UV drift only — no signal (read hover_data for continuous).
		# Still keep the object fresh (already updated above) for any polling consumer.


## Handles mouse-button presses. If a click lands on a hovered cell AND a spell is
## selected, emits `cell_clicked` carrying the cell, UV, the spell's action bit pattern,
## and spell.cost. The bit pattern comes from PlayerSpell.get_action_bit_pattern():
## placement spells send their own presence bit (1u << slot_index); dispel tools send
## the TARGET's bit (selective dispel) or WIPE_ALL (clear the whole cell). The VALUE
## SIGN carries place vs. wipe: negative cost for dispel tools, non-negative otherwise.
## Without a selected spell the click is silently ignored (no GPU write occurs).
func _input(event: InputEvent) -> void:
	# Fire cell_clicked on mouse-button press while currently hovering a cell.
	if event is InputEventMouseButton:
		var mb : InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed and _is_hovering:
			if spell:
				# The shader consumes only the SIGN of action_value (place >= 0, wipe < 0);
				# the magnitude is the spell's cost, carried for future use. Dispel tools
				# force a strictly negative value even at cost 0 — a bare -cost would emit
				# -0.0, which compares >= 0 in IEEE and would silently become a placement.
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

# ============================================================
#  Hover state management
# ============================================================

## Clears the hover state (cursor left the viewport or missed the sphere) and emits the
## `cell_exited` + `hover_changed` signals so downstream consumers can react.
func _clear_hover() -> void:
	if not _is_hovering:
		return
	_is_hovering = false
	var old : Vector2i = _prev_cell
	_prev_cell = Vector2i(-1, -1)

	hover_data.is_hovering = false
	# Keep stale uv/cell for one read if a consumer polls after exit; clear index/geo to be safe.
	hover_data.cell_index = 0

	cell_exited.emit(old)
	hover_changed.emit(hover_data)

# ============================================================
#  Viewport helpers (plan §2.1 — flexible SubViewport / full Window)
# ============================================================

## Returns the mouse position in this node's viewport-local coordinate system.
static func get_viewport_mouse(vp : Viewport) -> Vector2:
	return vp.get_mouse_position()

## Bounds check that works for both a SubViewport and the root Window (full-viewport case).
## The base `Viewport` class exposes no `size` property, so we resolve it per concrete type.
static func _is_mouse_in_viewport(vp : Viewport, mouse_pos : Vector2) -> bool:
	var size : Vector2 = _get_viewport_size(vp)
	return Rect2(Vector2.ZERO, size).has_point(mouse_pos)

static func _get_viewport_size(vp : Viewport) -> Vector2:
	if vp is SubViewport:
		return Vector2((vp as SubViewport).size)
	var as_window : Window = vp as Window
	if as_window != null:
		return Vector2(as_window.size)
	# Fallback for any other Viewport subclass.
	return vp.get_visible_rect().size

# ============================================================
#  Sphere math utilities (plan §2.3 – 2.5, Phase 1)
# ============================================================

## Analytical ray-sphere intersection for a sphere centered at the local origin.
## `ray_dir` should be normalized. Returns an empty Dictionary on a miss, otherwise:
##   { "t": float, "point": Vector3, "normal": Vector3 }  (all in LOCAL space).
static func ray_sphere_intersect(ray_origin : Vector3, ray_dir : Vector3, radius : float) -> Dictionary:
	# Solves:  t² + 2(O·D)t + (|O|² − R²) = 0
	# Let h = O·D, c = |O|² − R².  Discriminant d = h² − c.
	var h : float = ray_origin.dot(ray_dir)
	var c : float = ray_origin.dot(ray_origin) - radius * radius
	var disc : float = h * h - c
	if disc < 0.0:
		return {} # Ray misses the sphere entirely.

	var sqrt_disc : float = sqrt(disc)
	var t : float = -h - sqrt_disc # Nearest intersection (front face).
	if t < 0.0:
		# Camera is inside the sphere or sphere is behind the near plane; try the far intersection.
		t = -h + sqrt_disc
		if t < 0.0:
			return {} # Sphere entirely behind the ray origin.

	var point : Vector3 = ray_origin + ray_dir * t
	return {
		"t": t,
		"point": point,
		"normal": point.normalized(),
	}

## Maps a local unit surface normal to an equirectangular UV in [0.0, 1.0]².
##   +Y (north pole) → V = 0.0,  −Y (south pole) → V = 1.0
##   +X (prime meridian) → U = 0.0 (wraps to 1.0 at the −X seam)
##
## Longitude DIRECTION: the sphere mesh's authored equirectangular UVs map
## increasing-U to the rotation sense opposite of atan2(Z, X). Using atan2(Z, X)
## anchors U=0 correctly (+X) but inverts the direction — the hover indicator slides
## away from the cursor and only reconverges at U=0.5 (180°). Negating the angle
## (atan2(-Z, X) == -atan2(Z, X)) preserves the U=0 anchor while flipping the
## rotational sense to match the mesh, so the indicator tracks the cursor.
static func sphere_normal_to_uv(normal : Vector3) -> Vector2:
	var ny : float = clampf(normal.y, -1.0, 1.0)
	var phi : float = asin(ny)             # Latitude  ∈ [−π/2, +π/2]
	var v : float = 0.5 - (phi / PI)       # [0.0, 1.0]

	# theta = atan2(-Z, X): matches the mesh UV rotational direction (U increases the
	# opposite way to atan2(Z, X)). See function docstring for the full derivation.
	var theta : float = atan2(-normal.z, normal.x) # Longitude ∈ [−π, +π]
	var u : float = wrapf(theta / TAU, 0.0, 1.0)    # [0.0, 1.0)

	return Vector2(u, v)

## Quantizes a UV coordinate to a discrete simulation grid cell, clamped to valid bounds.
static func uv_to_cell_coord(uv : Vector2, grid : Vector2i) -> Vector2i:
	var cx : int = clampi(int(uv.x * float(grid.x)), 0, grid.x - 1)
	var cy : int = clampi(int(uv.y * float(grid.y)), 0, grid.y - 1)
	return Vector2i(cx, cy)

## Converts a UV coordinate to human-readable latitude/longitude in degrees.
##   Latitude:  +90.0° N (north pole) … −90.0° S (south pole)
##   Longitude: −180.0° … +180.0° (seam at U = 0.0 / 1.0)
static func uv_to_lat_lon(uv : Vector2) -> Vector2:
	var latitude : float = (0.5 - uv.y) * 180.0
	var longitude : float = (uv.x * 360.0) - 180.0
	return Vector2(latitude, longitude)




## Console debug helper — prints a one-line summary of a hover/click event. Only fires
## when `debug_log` is true. Not part of the step-5 telemetry UI.
func _print_hover(tag : String, cell : Vector2i, uv : Vector2, latlon : Vector2) -> void:
	print("[%s] cell=(%d, %d) idx=%d  UV=(%.4f, %.4f)  Lat=%.2f° Lon=%.2f°" % [
		tag, cell.x, cell.y, cell.y * grid_size.x + cell.x,
		uv.x, uv.y, latlon.x, latlon.y,
	])
