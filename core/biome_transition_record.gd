extends RefCounted
## Immutable value record representing a single cell's biome change between two
## consecutive `BIOME_TYPE` GPU snapshots.
class_name BiomeTransitionRecord

## Flat row-major grid index (`y * world_width + x`) of the transitioned cell.
var cell_index : int
## Classified biome ID (`0..17`) held by the cell in the previous shadow snapshot.
var old_biome : int
## Classified biome ID (`0..17`) held by the cell in the new GPU snapshot.
var new_biome : int
## 24-bit `ACTION_KEY` spell-presence bitmask unpacked from the texel's upper bits (`[8..31]`).
var attribution_bits : int
