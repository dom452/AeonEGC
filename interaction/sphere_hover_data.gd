extends RefCounted
## Live telemetry container holding the cursor's current ray-sphere intersection
## coordinates, equirectangular UV, discrete grid cell, and latitude/longitude.
class_name SphereHoverData

## True while the cursor ray currently intersects the planetary sphere.
var is_hovering : bool = false
## Equirectangular UV coordinate in `[0.0, 1.0)` under the cursor.
var uv : Vector2 = Vector2.ZERO
## Discrete simulation grid cell coordinates `Vector2i(x, y)`.
var cell_coord : Vector2i = Vector2i.ZERO
## Continuous sub-cell grid coordinates in `[0.0, grid_size)`.
var continuous_cell : Vector2 = Vector2.ZERO
## Flat row-major 1D cell index (`cell_coord.y * world_width + cell_coord.x`).
var cell_index : int = 0
## Geographic latitude in degrees (`+90.0` North Pole to `-90.0` South Pole).
var latitude_deg : float = 0.0
## Geographic longitude in degrees (`-180.0` to `+180.0`).
var longitude_deg : float = 0.0
## World-space 3D coordinates of the ray-sphere hit point.
var hit_point_world : Vector3 = Vector3.ZERO
## Planet-local 3D coordinates of the ray-sphere hit point.
var hit_point_local : Vector3 = Vector3.ZERO
## Outward unit surface normal in world space at the hit point.
var surface_normal : Vector3 = Vector3.UP
