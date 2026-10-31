# Occluder Tools

Adds occluders to the large solid meshes in a scene, so Godot's occlusion culling can skip everything hidden behind
them. Godot has the occlusion culling itself (`OccluderInstance3D`); this add-on only places the occluders.

## Use

1. Copy `addons/occluder_tools/` into your project and enable **Occluder Tools** in the Plugins settings.
2. Select the nodes that hold your buildings, walls and terrain pieces. An **Occluders** menu appears in the 3D toolbar.
3. **Add to selection...** scans the selection and adds an `OccluderInstance3D` child to each suitable mesh.
   A report lists what was skipped and why. **Remove generated from selection** undoes it. Both are undoable.
4. If occlusion culling was off in the project settings it is turned on and saved; restart the editor once.

## What gets an occluder

An occluder that is bigger than its mesh hides things that should be visible, so only safe cases are used:

- The mesh must be **closed** (watertight), opaque (no transparency; shader materials are skipped), and not skinned.
- It must be large: the longest world-space side at least *Minimum size* (default 4 m) and the middle side at least half of that.
- Meshes that nearly fill their bounding box get a slightly shrunk **box**. Other closed meshes of at most 2000
  triangles get an **exact array occluder** (optional). Anything more complex is skipped.

Meshes inside instanced scenes are left alone: add their occluders in the source scene.

## Notes

- Occluders cost CPU per frame, so many of them in a small scene can cost more than they save. Check with the
  profiler and the Occlusion culling debug draw mode.
- Occlusion culling needs the Forward+ or Mobile renderer. It is not available in the Compatibility renderer.
- Occluders stay in place when HLOD switches a cluster to its proxy.
- Tests: `godot --headless --path . -s res://tests/run_occluder_tests.gd`
