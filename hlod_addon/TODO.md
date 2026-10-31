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
- [ ] 6. Performance budget overlay (`addons/perf_overlay`)
- [ ] Final: README index, run every test suite, push

Not built on purpose: terrain (use the Terrain3D add-on), sky/weather/water (existing add-ons), animation/AI LOD
(small per-game scripts).
