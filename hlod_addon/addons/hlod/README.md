# HLOD

`HLODCluster` merges the `MeshInstance3D` and `MultiMeshInstance3D` nodes below it into one simplified proxy mesh
that is drawn from `switch_distance` on, while the original nodes are hidden. Other kinds of geometry (sprites,
labels, particles, CSG) are left alone and are not hidden.

Enable the plugin, select a cluster and press **Generate HLOD**, or call `generate_proxy()` / `generate_proxy_async()`.

## Proxy

| Property | Effect |
|---|---|
| `simplify_ratio` | Fraction of triangles kept. The simplifier works in halving steps, so the closest step is used. |
| `merge_materials` | Bakes simple materials (opaque, albedo only) into a shared texture atlas. |
| `atlas_cell_size` | Pixels per material in the atlas. Padding around each tile grows with it (up to 16 px) so small mip levels do not mix neighbors. |
| `compress_atlas` | Compresses the atlas with the best format the renderer supports. Off by default because the result only works where that format does. |
| `remove_hidden_faces` | Drops triangles no ray from outside reaches. |
| `hidden_face_triangle_limit` | Above this many opaque triangles the test is skipped with a warning, because it casts dozens of rays per triangle. |
| `proxy_cast_shadow`, `proxy_layers` | Set by generation from the merged meshes (any caster, union of layers); editable afterwards. |

## Grids

`build_grid(cell_size)` sorts the direct `Node3D` children into cells, one nested cluster each, at half the switch
distance. All cells and the root share one atlas per kind of material, so atlases are baked and stored once. Cells
with nothing to merge are not created and their nodes stay where they were. Calling it again takes the old cells
apart first.

## Streaming

`store_detail_scene(path)` moves the children into a scene that is loaded when the camera comes close. While it is not
loaded the proxy is drawn at every distance, so there is no gap while it loads. A failed load is reported once and
tried again after five seconds.

## Known limits

- Simplification runs per merged batch, so small cracks can open between neighboring objects. Raise `simplify_ratio`
  if that shows.
- A loaded detail scene is instantiated in one frame. Use `world_streaming` when that has to be budgeted.
- Per-instance MultiMesh colors and custom data are not baked into the proxy (a warning is printed).
- Hidden face removal samples a handful of points per triangle. It can drop a triangle that is only visible between
  them; turn it off for such meshes.
