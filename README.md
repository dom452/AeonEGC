# World Sim (Working Title: *Aeon*)

A GPU-accelerated planetary simulation and experimental god-game built in Godot 4.6 (Forward+ / Vulkan / D3D12). 
No scripted weather timers or commanding individual units. Instead, the entire planet—solar insolation, thermodynamics, two-layer atmospheric fluid dynamics, hydrostatic surface water flow, and four-stage plant succession — runs continuously in compute shaders at a fixed 60 Hz timestep.

Players interact with the world as an **indirect geological and arcane force**: introducing localized physical perturbations (such as awakening a geothermal vent in a frozen basin) and watching second- and third-order ecological cascades unfold across simulated years.

<img width="1446" height="1008" alt="3D planetary globe in World_Gen.tscn showing continents, ocean depth gradients, polar ice caps, vegetation biomes, and corner-tile biome borders" src="https://github.com/user-attachments/assets/fa2c8ddc-5e96-4023-be62-04cdcf9600cd" />

---

## Table of Contents
1. [Requirements & Quick Start](#1-requirements--quick-start)
2. [What You See in `World_Gen.tscn` (Default Scene)](#2-what-you-see-in-world_gentscn-default-scene)
3. [How to Navigate & Interact](#3-how-to-navigate--interact)
4. [Points of Interest: What to Watch For](#4-points-of-interest-what-to-watch-for)
5. [Design Philosophy: Indirect Agency & Long Feedback Loops](#5-design-philosophy-indirect-agency--long-feedback-loops)
6. [Technical & GPU Architecture](#6-technical--gpu-architecture)
7. [Repository Structure & Documentation](#7-repository-structure--documentation)

---

## 1. Requirements & Quick Start

* **Engine:** Godot Engine **4.6** (Standard or .NET build) with **Forward+** rendering (`RenderingDevice` compute support via Vulkan or D3D12; OpenGL compatibility mode is not supported).
* **Main Scene:** [`debug/World_Gen.tscn`](debug/World_Gen.tscn) (configured as `run/main_scene` in [`project.godot`](project.godot)).

### Running the Simulation in 3 Steps
1. Open the project in Godot 4.6 and press **F5** (or run [`debug/World_Gen.tscn`](debug/World_Gen.tscn)).
2. Click **`Generate World`** in the top-left sidebar. This dispatches the 18-pass GPU World Generation pipeline ("Simulated Settle"), carving terrain, settling hydrology and polar ice, seeding pioneer flora, classifying initial biomes, and logging the opening chronicle entry (`"Year 0: The world awakens."`).
3. Click **`Start Sim`** to begin continuous 60 Hz runtime simulation stepping.

---

## 2. What You See in `World_Gen.tscn` (Default Scene)

When [`debug/World_Gen.tscn`](debug/World_Gen.tscn) launches, the window is divided into two primary regions: a **Left Control & Telemetry Sidebar** and a **Main Tabbed Workspace** on the right.

<img width="410" height="1057" alt="Left Sidebar controls, Telemetry readout, RGB Channel Mapper, Chronicle Panel, and Main 3D World Viewport" src="https://github.com/user-attachments/assets/65d5c21f-882d-47b5-b5e1-48a7fb42cd45" />

### A. Left Sidebar (`DebugPanel`)
From top to bottom, the sidebar contains:

1. **Simulation Lifecycle Controls:**
   * **`Generate World`:** Runs the 18-stage GPU world generation pipeline and initializes the CPU biome region graph.
   * **`Start Sim` / `Stop Sim`:** Starts or halts the runtime compute pipeline (`WorldSimulator`).
   * **Time-Scale Row (`Pause`, `Slower`, `Faster`, `4x`):** Adjusts `sim_speed` (`0` to `4` full pipeline dispatches per rendered frame).
2. **Live Telemetry Readout (`Telemetry`):**
   * **`FPS` (`deltaTime`):** Frame delta time.
   * **`sim speed`:** Current simulation multiplier (`1x` $\approx$ 1 in-game day per real second; `4x` $\approx$ 90 real seconds per 360-day orbital year).
   * **`Hovered Cell`:** Discrete `(x, y)` grid coordinates (`0..511, 0..511`) under the mouse cursor.
   * **`Hovered UV`:** Equirectangular `(u, v)` coordinates (`0.0..1.0`) on the sphere.
   * **`Lat Long`:** Spherical latitude (`-90°..+90°`) and longitude (`-180°..+180°`) under the cursor.
   * **`Days` & `Years`:** Cumulative elapsed orbital days and years (`360` days/year) plus fractional intra-day and intra-year progress (`0.00..1.00`).
3. **RGB Data-Lens Channel Mapper (`DebugLayers`):**
   * Three dropdown menus (**Red**, **Green**, **Blue**) populated by [`LayerChannelUI`](debug/layer_channel_ui.gd) with every Fine Float (`[FLOAT]`) and Atomic (`[ATOMIC]`) sub-layer in the simulation.
   * When all three are set to `Flat 1.0` (default), the globe renders its natural terrain, water, ice, vegetation, and biome-border shader ([`_assets/_shaders/vis_terrain.gdshader`](_assets/_shaders/vis_terrain.gdshader)). Selecting any simulation layer switches the 3D globe into a live false-color RGB data lens.
4. **Chronicle & Impact Economy Panel (`ChroniclePanel`):**
   * Displays the player's current **`Impact: <score>`** (earned when player-attributed cascades push cells into higher-tier biomes) and a live scrolling **`AeonLog`** recording historical milestones as named biome regions emerge, expand, split, merge, or go extinct.

### B. Main Tabbed Workspace (`TabContainer`)
* **`World` Tab (Default Active Tab):**
  Renders the 3D planetary globe (`SimSphere4096.obj`) inside a `SubViewport` with a directional sun light (`DirectionalLight3D`) that orbits the planet each frame to match the exact diurnal hour angle and seasonal axial-tilt declination computed in `solar_insolation_sim.glsl`.
* **System Telemetry Tabs (Generated Dynamically on Startup):**
  [`WorldVisualiserUX`](gpu_compute_system/common/world_vis_ux.gd) replaces the placeholder tabs at startup with scrollable 2D equirectangular slice inspectors for every simulation domain:
  * **`Topography Generation`**, **`Thermodynamics`**, **`Fluid Dynamics`**, **`Ecology Baseline`**, **`Fauna Behavior`**, **`Civilization Behavior`**, **`Player Actions`**, and **`Coarse Dynamics`** ($64\times 64$ 2-layer atmospheric SWE fields).

<img width="1485" height="1049" alt="side-by-side real-time equirectangular heatmaps of Float, Atomic, and Coarse simulation slices" src="https://github.com/user-attachments/assets/242a31db-518f-421f-b46c-05598aef4882" />

---

## 3. How to Navigate & Interact

### Camera Controls (`OrbitCamera`)
| Input | Action | Details |
| :--- | :--- | :--- |
| **Right-Click + Drag** | **Orbit Globe** | Rotates the camera smoothly around the planet (`yaw` wraps $360^\circ$; `pitch` clamps near $\pm 90^\circ$ to prevent gimbal lock). |
| **Mouse Wheel Up / Down** | **Zoom In / Out** | Steps camera radius between `1.1` (low-orbit close inspection) and `1.67` (full-hemisphere view). |
| **Mouse Hover over Globe** | **Inspect Cell** | Highlights the hovered $512\times 512$ cell in gold on the 3D sphere and updates `Hovered Cell`, `Hovered UV`, and `Lat Long` in the sidebar. |

### Player Spells & World Interaction (`DebugSpellSelector` & `SphereCursorPicker`)
| Input | Action | Details |
| :--- | :--- | :--- |
| **Number Keys `1` – `9`** | **Select Spell Slot** | Selects a spell from [`default_spellbook.tres`](spells/default_spellbook.tres). Press **`1`** to select **`Geothermal Vent`** (Slot 0). |
| **Key `X`** | **Select Dispel Tool** | Selects the whole-cell dispel tool ([`wipe_spell.tres`](spells/wipe_spell.tres)) to clear active spell bits on a clicked cell. |
| **Key `Q`** | **Clear Selection** | Deselects the active spell so left-clicks on the globe do nothing. |
| **Left-Click on Globe** | **Cast / Dispel** | Latches a single-frame GPU action on the hovered `(x, y)` cell, writing the spell's bitmask into `PLAYER_ACTIONS.ACTION_KEY`. |

### Inspecting Hidden Simulation Layers on the 3D Globe
To overlay raw physical fields directly onto the 3D sphere:
1. Locate the three dropdowns (**Red / Green / Blue**) above the `Chronicle` panel.
2. Select any combination of layers—for example:
   * **Red:** `[FLOAT] LANDSCAPE_GROUND_TEMP`
   * **Green:** `[ATOMIC] FLORA_TREES_CANOPY`
   * **Blue:** `[FLOAT] ATMOSPHERE_HUMIDITY`
3. Reset all three dropdowns to **`Flat 1.0`** to return to the standard natural-color planet view.

<img width="516" height="592" alt="RGB False-Color Data-Lens Mode mapping" src="https://github.com/user-attachments/assets/18d4e9b8-5b5c-4894-85e5-c67e9a2e1162" />

<img width="1053" height="1020" alt="Side-by-side comparison of the 3D globe in Standard Terrain Mode vs. RGB False-Color Data-Lens Mode mapping Ground Temperature, Tree Canopy, and Atmospheric Humidity" src="https://github.com/user-attachments/assets/f1b0be29-fc8e-48fa-89e3-7d044a3c3fdf" />

---

## 4. Points of Interest: What to Watch For

Once you click **`Generate World`** and **`Start Sim`**, look for these emergent physical and ecological phenomena:

1. **Diurnal & Seasonal Solar Sweep:**
   Watch the day/night terminator sweep across the globe once per real second (at `1x` speed) while the subsolar latitude migrates between the Northern and Southern tropics over a 360-day year (`~6` real minutes at `1x`, or `90` seconds at `4x`).
2. **Polar Ice Caps & $0^\circ\text{C}$ Enthalpy Phase-Locking:**
   Near the poles and high mountain peaks, water freezes into bright glacial ice sheets (`WATER_ICE_HEIGHT`) and sea ice. During spring thaw, cells where liquid water and ice coexist remain thermally phase-locked at $0^\circ\text{C}$ until latent heat fully melts or freezes the column.
3. **Mid-Latitude Cyclogenesis & Orographic Rain Shadows:**
   Switch to the **`Coarse Dynamics`** tab or map `[FLOAT] ATMOSPHERE_RAIN` and `[FLOAT] ATMOSPHERE_WIND.X` to the RGB channels. The $64\times 64$ 2-layer Shallow Water Equations generate planetary Rossby waves and mid-latitude storms. When moisture-laden winds hit mountain ranges, kinematic terrain steering forces air upward, dropping heavy orographic rain on windward slopes and leaving arid rain-shadow deserts on the leeward side.
4. **Four-Tier Biological Succession (`Grasses` $\to$ `Shrubs` $\to$ `Trees`):**
   Barren soil cannot immediately grow forest canopy. Pioneer grasses must first colonize moist, nutrient-rich ground; shrubs establish only where grass density is sufficient; canopy trees grow atop established shrubs, casting `CANOPY_SHADE` and boosting local evapotranspiration.
5. **Corner-Tile SDF Biome Borders:**
   Zoom in close to the planet surface (`Mouse Wheel Up`) to see crisp, screen-space-width boundary lines with rounded Bézier-like corners separating the 18 discrete biomes (Tundra, Boreal Taiga, Temperate Forest, Subtropical Desert, Thermal Oasis, etc.), rendered without staircase artifacts via a 12-tile corner-arm SDF classifier in [`vis_terrain.gdshader`](_assets/_shaders/vis_terrain.gdshader).
6. **The Geothermal Awakening Cascade (Interactive Experiment):**
   * Press **`1`** to equip **Geothermal Vent**, zoom into a frozen polar tundra or glacial basin, and **Left-Click** a few adjacent cells.
   * Set speed to **`4x`**. Notice that **nothing pays out immediately**.
   * Over the next several simulated years, watch the injected geothermal heat conduct outward, thaw ice into liquid river runoff, elevate local humidity, and trigger pioneer grass and shrub colonization.
   * When the warming cells cross the hysteresis threshold into a higher-tier biome (such as **Thermal Oasis** or **Boreal Taiga**), particle and audio cues fire on the globe, your **`Impact`** score increases, and the **`Chronicle`** logs the birth and expansion of a newly christened region.

---

## 5. Design Philosophy: Indirect Agency & Long Feedback Loops

Most strategy and god games rely on immediate feedback—validating every click within milliseconds with points, resource popups, or direct unit obedience. However, real climatic and ecological systems possess high **physical inertia** (thermal mass, fluid advection time, and biological succession). Compressing those delays into instant puzzle mechanics sacrifices the core experience of stewarding a living planet, while leaving long delays unassisted creates a "causal attribution gap" where players cannot tell if an action taken minutes ago caused a current transformation.

**World Sim** resolves this tension by separating **micro-loop input acknowledgment** from **macro-loop systemic validation**:

* **Bit-Packed Causal Provenance (`ACTION_KEY` $\to$ `BIOME_TYPE`):**
  When you cast a spell on a cell, `player_actions_sim.glsl` sets a persistent spell bit in `PLAYER_ACTIONS.ACTION_KEY` (`r32ui`). Every frame, `biome_classifier_sim.glsl` evaluates a 6D environmental feature vector (temperature, moisture, standing water, tree canopy, herbaceous cover, salinity) against 18 biome centroids using a `0.15` hysteresis margin so diurnal/seasonal oscillations do not cause border flicker. The resulting `LANDSCAPE.BIOME_TYPE` texel packs the biome ID in bits `[0..7]` and a 24-bit snapshot of active `ACTION_KEY` provenance in bits `[8..31]`.
* **Retrospective Impact Currency (`BiomeEconomy`):**
  At ~1 Hz, [`BiomeSnapshotManager`](core/biome_snapshot_manager.gd) asynchronously reads back `BIOME_TYPE` without stalling the GPU and diffs it against a CPU shadow array. When a cell transitions to a higher ecological tier (`Tier(new) > Tier(old)`), [`BiomeEconomy`](core/biome_economy.gd) checks the causal attribution bits on the cell (`1.0x` credit) and its 4 orthogonal neighbors (`0.5x` credit for downwind/downstream advection), paying out **Impact Currency** at the moment the ecological tipping point is crossed.
* **World Memory & Lineage (`RegionGraphManager` & `AeonLog`):**
  [`RegionGraphManager`](core/region_graph_manager.gd) maintains a live Connected Component Labeling (CCL) graph of contiguous biome regions on worker threads. When a region reaches 5+ cells, [`RegionNameGenerator`](core/region_name_generator.gd) christens it with a procedural name and logs its birth, area milestones ($10,000\text{ km}^2$, $50,000\text{ km}^2$), splits, absorptions, and extinctions into [`AeonLog`](core/aeon_log.gd).

---

## 6. Technical & GPU Architecture

### A. Multi-Scale Planetary Grids & Topology
All compute shaders operate on a closed spherical topology with continuous $360^\circ$ longitudinal X-wrapping (`(x + W) % W`), $\cos(\text{latitude})$ zonal metric scaling, and branchless $180^\circ$ polar crossover (`(x + W/2) % W` with vector momentum sign inversion across the poles):

1. **Coarse Dynamics Grid ($64\times 64\times 9$, `r32f`, Double-Buffered):**
   Solves coupled 2-layer (stratosphere + troposphere) Shallow Water Equations (SWE) using dynamic Audusse well-balanced hydrostatic reconstruction, Rusanov fluxes, and reduced-gravity baroclinic coupling.
2. **Fine Float Grid ($512\times 512$, `r16f`, Double-Buffered):**
   Stores continuous diagnostic and physical state (heights/depths in hectometers where `1.0 = 100 m`, temperatures in `°C`, wind/water velocity vectors, humidity, rain, snow, sunlight, growth modifiers, and 17 scent layers).
3. **Atomic Grid ($512\times 512$, `r32ui`, Single-Buffered Mass SOT):**
   Acts as the mass-conserving Source of Truth via hardware `imageAtomicAdd` / `imageAtomicOr`. Uses dual fixed-point multipliers defined in [`WorldConfig`](core/world_config.gd):
   * **Standard (`atomic_multiplier = 100.0`):** Water volume, ice volume, soil nutrients, minerals (`1 uint = 0.01` float units / `1 m` depth).
   * **Flora (`flora_atomic_multiplier = 1,000,000.0`):** Grasses, shrubs, tree canopy, aquatic flora, and detritus (prevents sub-millimeter logistic growth deltas from truncating to zero).
4. **Lagrangian Cluster SSBOs (`std430`, Double-Buffered):**
   Pre-allocated VRAM buffers (`96 B` per `PopulationCluster`) for `1,000,000` fauna clusters and `100,000` civilization clusters.

### B. Universal Set 0 GPU Binding Contract
Every `LayerGenerator` (WorldGen) and `LayerSimulator` (Runtime) compute pass shares a unified descriptor set layout managed by [`GpuWorldState`](gpu_compute_system/common/gpu_world_state.gd):

| Binding | Shader Identifier | Format / Layout | Buffering | Role |
| :---: | :--- | :--- | :--- | :--- |
| **0** | `write_tex` | `r16f` ($512\times 512\times N_F$) | Double (Write) | Fine Float Grid Write |
| **1** | `read_tex` | `r16f` ($512\times 512\times N_F$) | Double (Read) | Fine Float Grid Read |
| **2** | `atomic_tex` | `r32ui` ($512\times 512\times N_A$) | Single (R/W) | Conserved Atomic Mass & Bitmask Grid |
| **3** | `ssbo_write` | `std430` (`96 B` $\times$ `1,100,001`) | Double (Write) | Lagrangian Cluster SSBO Write |
| **4** | `ssbo_read` | `std430` (`96 B` $\times$ `1,100,001`) | Double (Read) | Lagrangian Cluster SSBO Read |
| **5** | `atomic_vis_tex` | `r16f` ($512\times 512\times N_A$) | Single (Write) | Normalized `[0..1]` Atomic Visualizer Texture |
| **6** | `coarse_write_tex` | `r32f` ($64\times 64\times 9$) | Double (Write) | Coarse 2-Layer SWE Dynamics Write |
| **7** | `coarse_read_tex` | `r32f` ($64\times 64\times 9$) | Double (Read) | Coarse 2-Layer SWE Dynamics Read |
| **9** | `HoverProbeBuffer` | `std430` (`400 B`) | Single | Opt-in single-cell hover telemetry readback |
| **10** | `SpellBook` | `std430` (`32 B` $\times$ `32`) | Single (Read) | Opt-in runtime `SpellDefinition` table |
| **11** | `ArchetypeLimits` | `std430` (`176 B` $\times$ `200`) | Single (Read) | Opt-in `SpeciesArchetype` biological bounds |
| **12** | `ImpactCurrency` | `std430` (`256 B`) | Double | Opt-in GPU atomic impact accumulator |
| **15** | `custom_tex` | `r32f` ($512\times 512\times K$) | Single (Read) | WorldGen custom noise textures (`LayerGenerator` only) |

### C. Runtime Execution Pipeline (`WorldConfig.sim_layers`)
Each simulation step (`simDeltaTime = 0.01667 s`) dispatches compute passes sequentially with Vulkan memory barriers between phases:

1. **Phase 0 — World Generation ("Simulated Settle", 18 passes on `Generate World`):**
   Generates bedrock, slopes, sediment, solar insolation, geothermal vents, ground/air temperatures, atmospheric pressure, liquid water base, multi-step hydraulic river carving, polar ice seeding/freezing, thermal rebalancing, initial flora seeding, and initial biome classification.
2. **Phase 1 — Environment & Climatology:**
   * `player_actions_sim.glsl` & `spell_effects_sim.glsl` (latches player clicks into `ACTION_KEY` and refreshes active spell source layers such as `SPELL_GEOTHERMAL`).
   * `solar_insolation_sim.glsl` (orbital zenith, seasonal declination, and semidiurnal `TIDAL_FORCE`).
   * `thermodynamics_sim.glsl` (conduction, polar-wrapped diffusion, ground/water/air exchange, $0^\circ\text{C}$ latent heat phase-locking, Stefan-Boltzmann radiative cooling, greenhouse back-radiation, cloud albedo, and exothermic rain latent heat).
   * `hydraulic_flow_sim.glsl` (hydrostatic surface water flow, nutrient erosion, artesian groundwater, and salinity transport).
   * `fine_to_coarse_downsample.glsl` $\to$ `coarse_swe_sim.glsl` $\to$ `swe_atmosphere_sim.glsl` (downsamples terrain/heat to $64\times 64$, steps the 2-layer atmospheric SWE core, and interpolates winds back to $512\times 512$ for terrain steering, Dalton evaporation, humidity advection, and orographic rain/snow).
3. **Phase 2 — Flora & Ecology Baseline:**
   * `flora_ecology_sim.glsl` (evaluates thermal/moisture/nutrient suitability, updates `CANOPY_SHADE`, advances 4-tier logistic flora succession and detritus decomposition, and emits flora scent fields).
4. **Phase 5 — End-of-Frame Biome Classification & Visualizer Normalization:**
   * `biome_classifier_sim.glsl` (classifies each cell into one of 18 biomes with hysteresis and snapshots `ACTION_KEY` provenance bits into `LANDSCAPE.BIOME_TYPE`).
   * `atomic_visualizer_sim.glsl` (normalizes `r32ui` atomic slices into `Binding 5` `r16f` so the 3D globe shader and 2D UI tabs read GPU textures directly via `Texture2DArrayRD` with zero CPU copy overhead).

---

## 7. Repository Structure & Documentation

```text
world-sim/
├── _assets/                 # 3D sphere meshes, layer_globals.gdshaderinc, and vis_terrain.gdshader
├── camera/                  # Spherical OrbitCamera controller and shader global publisher
├── core/                    # GameStateManager, Helpers (VRAM SOT), WorldConfig, Biome & Region managers
├── debug/                   # World_Gen.tscn harness, SphereVisualiser, LayerChannelUI, AeonChroniclePanel
├── gpu_compute_system/      # GpuWorldState, LayerGenerator, LayerSimulator, PushConstants, and .glsl shaders
├── interaction/             # Analytical ray-sphere cursor picker (SphereCursorPicker) & hover telemetry
├── spells/                  # PlayerSpell resource definitions and SpellbookManager (Binding 10)
└── tools/                   # Editor utilities and shader global code generation
```
