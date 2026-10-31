# HLOD for Godot (add-on)

Hierarchical level of detail for stock Godot 4.3+: merge a group of meshes into one cheap proxy that is shown from
far away, and swap back to the real objects when the camera comes close. Pure GDScript, no GDExtension, no engine fork.

## Install

Copy `addons/hlod/` into your project's `addons/` folder and enable **HLOD** in *Project > Project Settings > Plugins*.

## Use

1. Add an **HLODCluster** node (a `Node3D`) and put your buildings, props or a whole scene below it.
2. Select the cluster and press **Generate HLOD** in the 3D editor toolbar. A progress dialog shows the steps and
   can be cancelled; the whole bake is one undo step.
3. Set **Switch Distance**: beyond it the proxy is shown, closer the children are. **Switch Margin** adds hysteresis
   so the swap doesn't flicker. **Fade Mode** (Forward+ only) cross-fades the two.

What the proxy generation does:

- merges all visible `MeshInstance3D` and `MultiMeshInstance3D` descendants (every MultiMesh instance included),
- bakes opaque `StandardMaterial3D`s (albedo colour/texture only) into one **material atlas** (`Merge Materials`),
- removes **hidden faces** that no outside viewpoint can see (`Remove Hidden Faces`),
- simplifies to `Simplify Ratio`. This uses `ImporterMesh.generate_lods`, whose levels halve the triangle count, so the
  closest available level to your ratio is used.

Nested clusters work: an inner cluster's proxy is used instead of its children when the outer one is baked.

### Big worlds

- **`build_grid(cell_size)`** (script) sorts the children into a grid of nested clusters, each with its own proxy.
  Cells use half the parent's switch distance.
- **Streaming**: `store_detail_scene(path)` saves the children as a scene and removes them; at run time the cluster
  loads them in a thread when the camera is within `switch + margin + Stream Load Margin` and frees them beyond
  `Stream Unload Margin`.

### Import

In the import dock of a glTF/scene, the **Meshes > HLOD** options (`hlod/*`) wrap the imported scene in a cluster
and generate the proxy (optionally a grid) during import.

## Limits

- Only opaque `StandardMaterial3D` with at most an albedo texture is atlased; other materials stay separate surfaces.
- Skinned meshes, particles and lights are not merged.
- Hidden-face removal is a sampling test, so very thin or open geometry may keep extra triangles; it can't see
  through transparent surfaces (those are never occluders).
- Simplification steps are coarse (each level halves the triangles).
- Tested on the Godot 4.8 beta build only; 4.3+ is the target, since it needs `ImporterMesh.generate_lods` and
  visibility ranges.

## Tests

```bash
godot --headless --path . -s res://tests/run_tests.gd
```
