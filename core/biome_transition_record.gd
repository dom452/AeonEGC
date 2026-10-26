extends RefCounted
class_name BiomeTransitionRecord

## One biome transition derived from a snapshot diff (plan §3.1 step 2).
## Diffing is lossless by construction: every GPU state change between two
## snapshots is either present in the newer snapshot or intentionally gone.

## Flat cell index (y * world_width + x).
var cell_index : int
## Biome ID before the transition (from the shadow copy, 0..17 or 255).
var old_biome : int
## Biome ID after the transition (from the GPU snapshot, 0..17 or 255).
var new_biome : int
## 24-bit ACTION_KEY attribution snapshot riding in the texel's upper bits.
var attribution_bits : int
