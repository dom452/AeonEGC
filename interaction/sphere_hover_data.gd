extends RefCounted
class_name SphereHoverData

## True if the cursor is currently intersecting the planetary sphere.
var is_hovering : bool = false
## Exact [0.0, 1.0] equirectangular UV coordinate under the cursor.
var uv : Vector2 = Vector2.ZERO
## Discrete simulation grid cell (0 .. world_width-1, 0 .. world_height-1).
var cell_coord : Vector2i = Vector2i.ZERO
## Continuous sub-cell coordinates in [0.0, world_size).
var continuous_cell : Vector2 = Vector2.ZERO
## 1D flat cell index for buffer lookups (cell_y * width + cell_x).
var cell_index : int = 0
## Human-readable latitude and longitude in degrees (x = lat, y = lon).
var latitude_deg : float = 0.0
var longitude_deg : float = 0.0
## 3D coordinates of the hit point.
var hit_point_world : Vector3 = Vector3.ZERO
var hit_point_local : Vector3 = Vector3.ZERO
var surface_normal : Vector3 = Vector3.UP
