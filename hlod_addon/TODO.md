# Open-world toolkit: progress

Add-ons live in `addons/`, each with a README and headless or rendered tests in `tests/`.
Done = built, tested, committed and pushed.

- [x] HLOD cluster (`addons/hlod`)
- [x] Occluder tools (`addons/occluder_tools`)
- [x] Impostors (`addons/impostors`)
- [x] 1. World streaming: cell loader with a frame budget, far cells, cell splitter (`addons/world_streaming`)
- [x] 2. Foliage scattering: chunked MultiMesh with real, impostor and cull levels (`addons/foliage`)
- [x] 3. Large-world precision: origin shifting and absolute coordinates (`addons/origin_shift`)
- [x] 4. Streamed navigation and collision: per-cell navmesh baking, ground-ready gating (`addons/world_streaming`)
- [x] 5. Hitch prevention: time-budgeted work queue, material prewarming (`addons/world_streaming`)
- [x] 6. Performance budget overlay (`addons/perf_overlay`)
- [x] Streaming without frame drops: worker-thread instancing, incremental child adding/removal, measured
- [x] Final: README index, run every test suite, push

Not built on purpose: terrain (use the Terrain3D add-on), sky/weather/water (existing add-ons), animation/AI LOD
(small per-game scripts).

## HLOD review fixes (addons/hlod)
Found by reading the code and running small repros. Done = fixed, covered by `tests/run_hlod_review_tests.gd`.

- [x] 1. Only MeshInstance3D and MultiMeshInstance3D are collected/linked (a Sprite3D/Label3D/CSG child crashed `prepare()`)
- [x] 2. `build_grid` skips cells with nothing to merge instead of aborting half-built
- [x] 3. Grid cells share one texture atlas (one bake, one texture) instead of one per cell; optional compressed atlas
- [x] 4. Atlas padding scales with the cell size so small mip levels don't mix neighboring materials
- [x] 5. Proxy copies shadow casting and render layers from the sources; MultiMesh colors/custom data warn
- [x] 6. Hidden-face test adds edge samples so partly covered triangles are kept
- [x] 7. Hidden-face removal has a triangle cap (skipped with a warning above it)
- [x] 8. `_merge` batch lookup is a dictionary; unreadable albedo textures are remembered
- [x] 9. Streaming retries failed loads; the proxy stays visible while the detail scene is not loaded
- [x] 10. `store_detail_scene` restores the original owners on failure; re-running `build_grid` does not nest cells
- Verified: `run_tests.gd` (41 checks) and `run_hlod_review_tests.gd` (63 checks) pass, as do the occluder, streaming, foliage, origin, hitch and overlay suites. `run_impostor_tests.gd` needs a renderer and was not run (this build is headless only).
- Known limits, not fixed (documented in `addons/hlod/README.md`): simplification runs per merged batch (small cracks between objects are possible, raise
  `simplify_ratio`); instantiating a loaded detail scene happens in one frame (use `world_streaming` for budgeted
  instancing); per-instance MultiMesh colors are not baked.
