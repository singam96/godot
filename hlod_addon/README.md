# Open-world toolkit for Godot 4.3+

Add-ons for large worlds, written in GDScript (no GDExtension, no engine fork). Copy the ones you need from
`addons/` into your project and enable them in the Plugins settings. Each has its own README.

| Add-on | What it does |
|---|---|
| [`hlod`](addons/hlod/) | Merges clusters of meshes into one atlased, simplified proxy shown from far away; grids, streaming, import options |
| [`occluder_tools`](addons/occluder_tools/) | Adds safe occluders to large solid meshes for occlusion culling |
| [`impostors`](addons/impostors/) | Bakes billboard impostors of trees, props and clusters for the far distance |
| [`world_streaming`](addons/world_streaming/) | Streams world cells with a frame budget; far cells, cell splitter, per-cell navigation, ground gate, work queue, prewarming |
| [`foliage`](addons/foliage/) | Chunked MultiMesh scattering with real, impostor and cull levels |
| [`origin_shift`](addons/origin_shift/) | Moves the world back to the origin and keeps 64-bit absolute coordinates |
| [`perf_overlay`](addons/perf_overlay/) | Frame time, draw calls, triangles and streaming against budgets, with a hitch counter |

## How they fit together

```
near            medium            far              very far
real meshes --> HLOD proxy  -->  impostor  -->  culled
(MultiMesh via foliage for repeated objects; occluders hide what is behind buildings)

world_streaming loads/frees the cells that hold all of this around the player;
origin_shift keeps the player near the origin; perf_overlay shows what each frame costs.
```

Not included on purpose: terrain (use the Terrain3D add-on), sky, weather and water (existing add-ons).

## Project in this folder

This folder is also a Godot project with all add-ons enabled and the test suites in `tests/`:

```bash
godot --headless --import --path .
godot --headless --path . -s res://tests/run_tests.gd            # hlod
godot --headless --path . -s res://tests/run_occluder_tests.gd
godot --headless --path . -s res://tests/run_streaming_tests.gd
godot --headless --path . -s res://tests/run_streaming_threads_tests.gd
godot --headless --path . -s res://tests/run_foliage_tests.gd
godot --headless --path . -s res://tests/run_origin_tests.gd
godot --headless --path . -s res://tests/run_hitch_tests.gd
godot --headless --path . -s res://tests/run_overlay_tests.gd
xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_impostor_tests.gd   # needs a renderer
```

Tested on the Godot 4.8 beta only (software renderer for the rendering tests); the target is stock 4.3+.
