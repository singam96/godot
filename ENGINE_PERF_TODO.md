# Engine performance work

Engine-level changes (this fork), as opposed to the GDScript add-ons in `hlod_addon/`.
Each item is committed with its own tests.

- [x] **Directional shadow cascade caching** (Forward+).
  `rendering/lights_and_shadows/directional_shadow/cache_far_cascades` (+ `cache_margin`, `cache_max_age_frames`).
  Far cascades are rendered with a margin and reused while the camera stays inside it. Test: `hlod_addon/tests/run_shadow_cache_tests.gd`.
- [x] **Texture streaming**: mip streaming already existed in `modules/texture_streaming` (GPU feedback, StreamedTexture2D).
  Added `rendering/textures/streaming/max_upload_mb_per_second`, a byte budget on uploads (the existing limit counted operations,
  not bytes), and kept the streaming state attached across `texture_replace_compatible`.
  Test: `hlod_addon/tests/texture_streaming_project` (`run_streaming_texture_tests.gd`).
  Not done: counting the old+new texture during a promotion in the VRAM budget, and streaming meshes.
- [x] **GPU upload queue**: covered for streamed textures by the byte budget above. Textures and meshes created on loader threads
  are not deferred (the RenderingDevice calls cannot be postponed without changing every caller).
- [x] **MultiMesh per-instance GPU culling** (Forward+, main view and shadow passes).
  `rendering/limits/multimesh/gpu_culling_min_instances` (0 = off). A compute pass copies the instances in view to a second
  buffer with the same layout and writes the count into an indirect draw, so no shader changes. Test: `hlod_addon/tests/run_multimesh_cull_tests.gd`.
  Not culled: 2D, user indirect, motion vectors, multiview/XR, lower mesh LODs, dual-paraboloid shadows, other passes.
- [x] **Scene tree bulk attach/detach**: measured, not changed. `add_child` of a prebuilt subtree costs about 1.4 us per node
  (5000 nodes: 7 ms). The longer frame after it is rendering, not the tree, so a bulk attach in C++ would save little.

## Defaults
All three are on by default: `cache_far_cascades` = 2, `gpu_culling_min_instances` = 1000, `max_upload_mb_per_second` = 128.
Set them to 0 to get the previous behavior. Cached shadow cascades can show a newly added or moved caster up to
`cache_max_age_frames` frames late.
