# World Streaming

Loads and frees the cells of a large world around the player, in threads and within a per-frame time budget.

## Install

Copy `addons/world_streaming/` into your project and enable **World Streaming** in the Plugins settings.

## Set up

1. **Split your world.** Put the world's objects as direct children of one `Node3D`, select it and press
   **Split into Cells** in the 3D toolbar (or call `world_cell_builder.gd`'s `build()` from a script). Every child
   goes into the cell its position falls in, and one scene per cell is saved: `cell_<x>_<z>.tscn`. Optional:
   - **Far cells:** also saves `far_<x>_<z>.scn`, one merged, simplified mesh per cell (needs the HLOD add-on).
   - **Bake navigation:** adds a baked `NavigationRegion3D` to every cell.
2. **Add a `WorldStreamer`** at the origin of your world. Set the same *Cell Size* and *Cells Dir*, and the *Target*
   (the player or the camera; empty uses the current camera).
3. Tune the distances: detail cells load within *Load Radius* and free beyond *Unload Radius* (the gap stops
   cells from flickering at the edge). *Far Load Radius* adds the far cells beyond it; a far cell is swapped for
   the detail one without a gap.

Cells are authored in world coordinates, relative to the streamer node. If you use the origin-shift add-on, put the
streamer below the node that gets shifted.

## Hitches

- Loading is threaded. Adding a cell to the tree and freeing one are limited by *Frame Budget* (ms per frame).
  Without *Incremental Children* a single cell is never split, so keep cells small enough to add within a few milliseconds.
- *Threaded Instantiate* (on by default) builds a cell's nodes on a worker thread, so only adding it to the tree is
  left for the main thread. Scripts on the cell's nodes must not touch the scene tree in `_init`.
- *Incremental Children* (on by default) adds a cell's children a few per frame, and removes them the same way when
  the cell is unloaded, so one big cell never costs a whole frame. It takes several frames for a cell to appear, and
  `cell_loaded` is emitted when it is complete. Turn it off if you need a cell to appear in a single frame; it only matters for cells with several children.
- Measured on 9 cells of 1500 mesh nodes each (CPU only, headless): worst frame while loading 30 ms on the main
  thread, 9 ms with a worker thread, 8 ms with incremental children; worst frame while unloading 88 ms, 90 ms and 8 ms.
  Unloading only improves with *Incremental Children*. These are not GPU numbers: check your own scene with the Perf
  Overlay.
- *Prewarm* draws each new cell once, tiny and off-screen, before showing it, so the renderer compiles what it
  needs ahead of time.

- **FrameWorkQueue**: a node for your own spawning. `enqueue(callable, priority)` runs jobs within a time budget per
  frame; a job that returns `true` is run again, so one long loop can be sliced.
- **MaterialPrewarmer**: `await prewarm([scene, mesh, material])` draws the items once, tiny and off-screen with
  lights and shadows on, for example on a loading screen.

## Collision and navigation

- Put collision shapes in the cell scenes. They load and free with the cell.
- Add a **WorldGroundGate** node (streamer + body) to keep the player frozen until the ground around it has loaded.
  `WorldStreamer.is_position_loaded()` and the `required_area_ready` signal are there for your own logic.
- Navigation: each cell has its own region. Regions of neighboring cells connect where their edges are within the
  navigation map's edge connection margin, so make sure the ground meshes of two cells meet at the cell border.

## API

`update_now()`, `is_position_loaded(pos)`, `are_required_cells_loaded()`, `get_loaded_counts()`, `get_cell(coord, layer)`,
`is_busy()`, and the signals `cell_loaded`, `cell_unloaded`, `required_area_ready`, `required_area_lost`.

Tests: `godot --headless --path . -s res://tests/run_streaming_tests.gd`, `run_streaming_threads_tests.gd` and `run_hitch_tests.gd` (prewarm needs a renderer).
