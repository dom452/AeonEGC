"""Generates the Master Biome Catalog centroid tables into both biome shaders.

Single source of truth (plan §2.5): the 18 centroid vectors, offsets, hysteresis
constant, and the 6D feature-vector normalization constants live HERE. Run from
the project root:

    python tools/generate_biome_tables.py

The script stamps an auto-generated block between BEGIN/END markers in:
  - gpu_compute_system/world_gen/presets/06_classification/biome_seeding_generator.glsl
  - gpu_compute_system/world_sim/presets/06_classification/biome_classifier_sim.glsl

Rationale: Godot 4.6's RDShaderFile importer does not expand #include for .glsl
compute shaders (verified empirically), so the shared constants are duplicated
by generation — never by hand — and tests/test_biome_classification.gd checks
the two stamped blocks are byte-identical.

The table must stay in sync with core/helpers.gd (BIOME_TEXEL_* constants) and
_planning/event_logging_system_plan.md §2.3.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ============================================================================
# MASTER BIOME CATALOG — the single editable copy.
# (T_norm, M_norm, W_norm, V_tree, V_herb, S_norm) + score offset C_k.
# Offsets are computed at full precision as C_k = 0.5 * ||b_k||^2
# (the plan table's 4-decimal column is rounded; row 10 rounds to 1.4953
# versus 1.4947 exact — the delta is negligible against hysteresis 0.15).
# ============================================================================
# name, (T, M, W, V_tree, V_herb, S)
BIOMES: list[tuple[str, tuple[float, float, float, float, float, float]]] = [
    ("Glacial Ice Sheet",     (0.111, 0.029, 0.771, 0.000, 0.000, 0.000)),
    ("Polar Tundra",          (0.311, 0.071, 0.000, 0.000, 0.350, 0.000)),
    ("Boreal Taiga",          (0.422, 0.171, 0.000, 0.700, 0.300, 0.000)),
    ("Alpine Meadow",         (0.467, 0.257, 0.000, 0.050, 0.600, 0.000)),
    ("Temperate Forest",      (0.578, 0.314, 0.000, 0.800, 0.400, 0.000)),
    ("Temperate Grassland",   (0.556, 0.143, 0.000, 0.050, 0.900, 0.000)),
    ("Temperate Rainforest",  (0.544, 0.743, 0.000, 0.950, 0.650, 0.000)),
    ("Mediterranean Scrub",   (0.633, 0.157, 0.000, 0.250, 0.650, 0.050)),
    ("Subtropical Desert",    (0.800, 0.023, 0.000, 0.000, 0.050, 0.125)),
    ("Semi-Arid Savanna",     (0.733, 0.214, 0.000, 0.200, 0.750, 0.000)),
    ("Tropical Rainforest",   (0.744, 0.914, 0.000, 0.980, 0.800, 0.000)),
    ("Thermal Oasis",         (0.711, 0.114, 0.050, 0.400, 0.850, 0.025)),
    ("Freshwater Wetland",    (0.667, 0.457, 0.086, 0.200, 0.850, 0.013)),
    ("Mangrove Estuary",      (0.733, 0.514, 0.114, 0.750, 0.300, 0.500)),
    ("Freshwater Lake",       (0.578, 0.229, 0.404, 0.000, 0.150, 0.005)),
    ("Sea Ice / Frozen Sea",  (0.244, 0.057, 0.488, 0.000, 0.000, 0.750)),
    ("Shallow Coastal Shelf", (0.667, 0.286, 0.461, 0.000, 0.350, 0.875)),
    ("Pelagic Deep Ocean",    (0.556, 0.286, 0.971, 0.000, 0.050, 0.875)),
]

# Shared tuning constants.
HYSTERESIS_DELTA = 0.15
BIOME_UNCLASSIFIED = 255
BIOME_ID_MASK = "0xFFu"

# 6D feature vector normalization constants (plan §2.2).
DEPTH_LOG_DIVISOR = 3.5          # log10(1 + depth_m) / 3.5 -> [0,1] at 3500 m
TEMP_RANGE = 90.0                # (temp_c + 40) / 90 -> [-40, +50] -> [0,1]
TEMP_MIN_C = -40.0
K_TREE = 5.0                     # flora_ecology_sim carrying capacities
K_SHRUB = 3.0
K_GRASS = 1.0

TARGETS = [
    ROOT / "gpu_compute_system/world_gen/presets/06_classification/biome_seeding_generator.glsl",
    ROOT / "gpu_compute_system/world_sim/presets/06_classification/biome_classifier_sim.glsl",
]

BEGIN_MARK = "// ===== GENERATED BIOME TABLES — DO NOT EDIT BELOW (tools/generate_biome_tables.py) ====="
END_MARK = "// ===== END GENERATED BIOME TABLES ====="


def _fmt(value: float) -> str:
    """GLSL float literal with a decimal point."""
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return text if "." in text else text + ".0"


def build_block() -> str:
    lines: list[str] = [BEGIN_MARK]

    lines.append(f"const uint BIOME_COUNT = {len(BIOMES)}u;")
    lines.append(f"const uint BIOME_UNCLASSIFIED = {BIOME_UNCLASSIFIED}u; // sentinel: 'not yet evaluated' (plan §2.1)")
    lines.append(f"const float HYSTERESIS_DELTA = {HYSTERESIS_DELTA};")
    lines.append("")

    # Split each centroid into a vec4 (T, M, W, V_tree) and a vec2 (V_herb, S)
    # so dot products stay in packed 4/2-lane math (2 x dot4 + 1 x dot2 per
    # challenger, cheaper than 6 scalar MADs).
    # NOTE: GLSL initializer lists reject a trailing comma after the last
    # element, so separators go BETWEEN entries only.
    lines.append("// Score_k = dot(x_part1, BIOME_TMWV[k]) + dot(x_part2, BIOME_HS[k]) - BIOME_OFFSET[k]")
    lines.append("const vec4 BIOME_TMWV[18] = vec4[](")
    tmwv_rows = [f"vec4({_fmt(t)}, {_fmt(m)}, {_fmt(w)}, {_fmt(vt)})" for _name, (t, m, w, vt, _vh, _s) in BIOMES]
    for i, row in enumerate(tmwv_rows):
        sep = "," if i < len(tmwv_rows) - 1 else ""
        lines.append(f"    {row}{sep} // {BIOMES[i][0]}")
    lines.append(");")
    lines.append("const vec2 BIOME_HS[18] = vec2[](")
    hs_rows = [f"vec2({_fmt(vh)}, {_fmt(s)})" for _name, (_t, _m, _w, _vt, vh, s) in BIOMES]
    for i, row in enumerate(hs_rows):
        sep = "," if i < len(hs_rows) - 1 else ""
        lines.append(f"    {row}{sep} // {BIOMES[i][0]}")
    lines.append(");")
    lines.append("const float BIOME_OFFSET[18] = float[](")
    for i, (name, b) in enumerate(BIOMES):
        c = 0.5 * sum(x * x for x in b)
        sep = "," if i < len(BIOMES) - 1 else ""
        lines.append(f"    {_fmt(c)}{sep} // {name}")
    lines.append(");")
    lines.append("")

    lines.append("// Normalization constants for the 6D feature vector (plan §2.2).")
    lines.append(f"const float DEPTH_LOG_DIVISOR = {_fmt(DEPTH_LOG_DIVISOR)};  // log10(1 + depth_m) / {DEPTH_LOG_DIVISOR}")
    lines.append(f"const float TEMP_RANGE = {_fmt(TEMP_RANGE)};               // (temp_c + 40) / {TEMP_RANGE}")
    lines.append(f"const float TEMP_MIN_C = {_fmt(TEMP_MIN_C)};")
    lines.append(f"const float K_TREE = {_fmt(K_TREE)};")
    lines.append(f"const float K_SHRUB = {_fmt(K_SHRUB)};")
    lines.append(f"const float K_GRASS = {_fmt(K_GRASS)};")
    lines.append(END_MARK)
    return "\n".join(lines)


def stamp(path: Path, block: str) -> bool:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(
        re.escape(BEGIN_MARK) + r"\n.*?\n" + re.escape(END_MARK) + r"\n",
        re.S,
    )
    if pattern.search(text):
        new_text = pattern.sub(block + "\n", text)
    else:
        marker = "// === GENERATED CODE INJECTION POINT (tools/generate_biome_tables.py) ==="
        if marker not in text:
            raise SystemExit(f"{path}: no injection point marker and no existing block")
        new_text = text.replace(marker, block + "\n\n" + marker)
    if new_text != text:
        path.write_text(new_text, encoding="utf-8", newline="\n")
        return True
    return False


def main() -> None:
    block = build_block()
    for target in TARGETS:
        if not target.exists():
            raise SystemExit(f"target missing: {target}")
        changed = stamp(target, block)
        print(f"{'STAMPED' if changed else 'unchanged'}: {target.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
