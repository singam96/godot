# Impostors

Replaces far-away objects with a camera-facing quad that shows a baked picture of the object. Made for trees,
foliage, props and, at long range, buildings or whole HLOD clusters.

## Install

Copy `addons/impostors/` into your project and enable **Impostors** in the Plugins settings.

## Bake

1. Select a node (not the scene root) with the object below it, such as a tree or an `HLODCluster`.
2. Press **Bake Impostor** in the 3D toolbar, choose the number of views, the elevation rows, the view size and the
   switch distance. The object is rendered from all sides into an atlas, saved to `res://impostors/`.
3. An **Impostor3D** node is added next to the object. Beyond *Switch Distance* it draws the quad and the real
   object is hidden, so exactly one of them is drawn. *Switch Margin* adds hysteresis; *Fade Mode* cross-fades
   (Forward+ only).

Settings guide: trees and foliage look fine with 12 views and 2 rows; buildings and other objects with flat sides need
more (16 to 24 views). 256 px views are a good start; bigger is only needed for impostors that stay large on screen.

## Thousands of trees

Bake one tree, then draw all the far copies with one draw call:

```gdscript
var transforms: Array[Transform3D] = [...]   # position, Y rotation and scale of each tree
var mmi := MultiMeshInstance3D.new()
mmi.multimesh = data.create_multimesh(transforms)   # data is the baked ImpostorData
mmi.visibility_range_begin = 150.0                  # same distance as the real trees' visibility_range_end
```

Each instance's rotation picks the right view, so rotated trees look right.

## With HLOD

Bake an `HLODCluster` and set the Impostor3D's target to it. The cluster then has three levels: the real objects
nearby, its merged HLOD proxy in the middle, and the impostor beyond the impostor's switch distance. Keep the
impostor distance well above the cluster's own switch distance.

## Limits

- Lighting: with *Lit* on (the default) the bake also stores the object's normals, and the impostor is lit by the
  scene's lights, ambient light, global illumination and fog like a real object, and receives shadows from other
  objects. It is diffuse only (no specular or reflections), it does not cast shadows, and the color atlas is baked
  with flat ambient light, so metals and emission look flatter. Turn *Lit* off for a cheaper, unlit impostor
  (`ImpostorData.lit = false`), or old data without normals, which falls back to unlit by itself. The normal atlas
  doubles the bake time and the file size.
- Views are blended, so you may see a soft ghost between angles with few views. Add views or rows to reduce it.
- The quad is a flat camera-facing billboard with no depth; where impostors overlap each other or real geometry
  the intersection is a straight line.
- Meant for the far distance. Keep the switch distance high enough that parallax isn't visible.
- Baking needs a running renderer, so it works in the editor but not with `--headless`.
- Alpha is cut at 50%, so thin leaves can look slightly thinner in the distance.

## Tests

```bash
xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_impostor_tests.gd
```
