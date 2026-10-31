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
  A single cell is never split, so keep cells small enough to add within a few milliseconds.
- *Prewarm* draws each new cell once, tiny and off-screen, before showing it, so the renderer compiles what it
  needs ahead of time.

## Collision and navigation

- Put collision shapes in the cell scenes. They load and free with the cell.
- Add a **WorldGroundGate** node (streamer + body) to keep the player frozen until the ground around it has loaded.
  `WorldStreamer.is_position_loaded()` and the `required_area_ready` signal are there for your own logic.
- Navigation: each cell has its own region. Regions of neighbouring cells connect where their edges are within the
  navigation map's edge connection margin, so make sure the ground meshes of two cells meet at the cell border.

## API

`update_now()`, `is_position_loaded(pos)`, `are_required_cells_loaded()`, `get_loaded_counts()`, `get_cell(coord, layer)`,
`is_busy()`, and the signals `cell_loaded`, `cell_unloaded`, `required_area_ready`, `required_area_lost`.

Tests: `godot --headless --path . -s res://tests/run_streaming_tests.gd`
