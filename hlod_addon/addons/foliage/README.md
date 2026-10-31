# Foliage

Scatters trees, grass and rocks as chunked MultiMeshes. Nearby chunks draw the real mesh, farther ones draw the
baked impostor (see the Impostors add-on), and beyond a maximum distance nothing is drawn. Chunks outside the view are
culled, so thousands of instances cost a handful of draw calls.

## Install

Copy `addons/foliage/` into your project and enable **Foliage** in the Plugins settings. The impostor level needs the
Impostors add-on (`ImpostorData`), which `FoliageScatter` references.

## Use

1. Add a **FoliageScatter** node, set its *Mesh*, the *Area* (a rectangle centered on the node) and *Density*
   (instances per square meter; 0.02 is a tree every ~7 m).
2. Optional: bake an impostor of the mesh and assign it to *Impostor*. Then *Near Distance* is where the real mesh
   gives way to it, and *Max Distance* where it is culled. Without an impostor the real mesh is culled at *Max Distance*.
3. Select the node and press **Generate Foliage**. Placement is a jittered grid, seeded per chunk: even spacing, no
   clumps, and the same layout every time for the same *Seed*.

By default the result is stored in the scene file. For very large areas turn *Save In Scene* off: the foliage is then
generated when the game starts (*Generate On Ready*).

## Ground and masks

Set these from a script before calling `generate()` (or in `_ready`, when generating at run time):

```gdscript
# Return null to leave a spot empty, a height, or {"height": h, "normal": n}.
scatter.ground_sampler = func(p: Vector2): return terrain.get_height(p.x, p.y)
# Chance 0..1 that a spot gets an instance, for paths, clearings and biomes.
scatter.density_sampler = func(p: Vector2): return 0.0 if near_road(p) else 1.0
```

Or tick *Use Physics Ground* to drop instances onto whatever physics body is below (only works while the colliders
exist, so at run time). *Align To Normal* leans instances onto slopes.

Use one FoliageScatter per kind (oak, pine, bush, rock) so each can have its own distances.

## Notes

- Every chunk has its own MultiMesh pair, so choose a *Chunk Size* of 30 to 100 m: smaller culls better but makes more
  draw calls, larger draws more that you can't see.
- Shadows: *Cast Shadows* applies to both the near mesh and the impostor level (shadows end at the light's shadow distance).
- Large worlds: combine with the World Streaming add-on by putting one FoliageScatter per cell scene.

Tests: `godot --headless --path . -s res://tests/run_foliage_tests.gd` (or under `xvfb-run` with a renderer, which
also compares the MultiMesh transforms).
