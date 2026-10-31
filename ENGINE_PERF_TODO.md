# Engine performance work

Engine-level changes (this fork), as opposed to the GDScript add-ons in `hlod_addon/`.
Each item is committed with its own tests.

- [x] **Directional shadow cascade caching** (Forward+).
  `rendering/lights_and_shadows/directional_shadow/cache_far_cascades` (+ `cache_margin`, `cache_max_age_frames`).
  Far cascades are rendered with a margin and reused while the camera stays inside it. Test: `hlod_addon/tests/run_shadow_cache_tests.gd`.
- [ ] **Texture streaming**: mip streaming already exists in `modules/texture_streaming` (GPU feedback, GSTF format).
  Remaining: byte-budgeted upload, accurate budget during promotion, direct multi-level promotion.
- [ ] **GPU upload queue** with a per-frame byte budget.
- [ ] **MultiMesh per-instance culling** (indirect multimesh exists; no per-instance culling yet).
- [ ] **Scene tree bulk attach/detach**: measure first.
