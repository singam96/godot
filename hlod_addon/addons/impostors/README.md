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

## Shadows

**Casting.** Impostors cast shadows (*Cast Shadows* on the Impostor3D, on by default). A hidden shadows-only copy of
the quad faces the light and shows the baked view that looks along it, so the object's cut-out silhouette is what falls
on the ground, in the right place: in a test the shadow of a baked sphere had the same area as the real one (1814 vs
1813 pixels).

- The shadow is only as accurate as the baked views near the sun. Trees are forgiving; long thin objects are not.
  Choose *Min/Max Elevation* so that the rows cover the sun's elevation, and use 3 to 4 rows. With 12 views and 4 rows a
  12 m long box's shadow was within 9% of the real one; with only 2 rows (10 and 55 degrees) it was 19% too small.
- Shadows stop at the light's *Shadow Max Distance*, so impostors beyond it cast none, and they cost shadow-map time
  like any other caster. Turn *Cast Shadows* off for impostors that are far enough not to matter.
- Point and spot lights work the same way, but I only tested a directional light.

**Receiving.** Nothing about shadows is baked into the pictures: the bake uses flat ambient light and stores only color
and normals. Shadows on an impostor are worked out live from your scene's shadow maps, and by default an impostor
*does not receive* them (`ImpostorData.receive_shadows = false`). The reason: a flat camera-facing quad would sit inside
the shadow of its own light-facing copy and come out dark. Receiving shadows needs that copy to be moved back along the
light ray, which also cuts the lower part off the shadow the impostor casts (a tree's base, where the shadow matters most).
Set `receive_shadows = true` if shadows from other objects (a mountain, a building) falling on far objects matter more
than the exact shadow they cast. Either way:

- By default the impostor is a flat quad, so a received shadow is looked up across the plane through the object's
  center. *Receive Detail* (`ImpostorData.receive_detail`, with `receive_shadows` on) subdivides the quad and pushes
  its vertices to the baked surface, so shadows are looked up by region (see Depth and occlusion below).

## Depth and occlusion

With *Depth and ambient occlusion* on (the default when lit), the bake adds a third pass that stores, per pixel, the
depth of the surface and an ambient occlusion value (the engine's SSAO, so it needs the Forward+ renderer; with another
renderer the occlusion is simply 1.0).

- **Depth buffer.** The impostor writes the real depth of each pixel, so it intersects other geometry and other
  impostors the way the real object would, instead of being a flat plane at its center: a cube inside a baked sphere
  stays hidden (tested). Written for the Forward+ and Mobile renderers.
- **Ambient occlusion** darkens the ambient light in creases and deep inside the object, like leaves shading each
  other. `ao_strength` scales it, and `ao_light_affect` (default 0.4) lets part of it darken direct light too, as a
  stand-in for self-shadowing from the sun. The sun's own shadows inside the object are *not* baked: that would need a
  bake per sun direction, so this is an approximation.
- **Received shadows by region.** A shader cannot change the position that shadow lookups use (it is read-only in the
  fragment stage), so true per-pixel received shadows are not possible. *Receive Detail* n builds the quad as n x n
  cells and moves its vertices to the baked surface in the vertex shader. With 16 cells, a shadow band on a sphere landed
  almost where it does on the real sphere (mean error 0.06 against 0.38 for the flat quad). It costs 2 x n x n
  triangles per impostor, so use it for a few big, important impostors, not for thousands of trees.
- The bake takes three passes instead of two and the file has a third atlas.

## Limits

- Lighting: with *Lit* on (the default) the bake also stores the object's normals, and the impostor is lit by the
  scene's lights, ambient light, global illumination and fog like a real object, and receives shadows from other
  objects. It is diffuse only (no specular or reflections), and the color atlas is baked
  with flat ambient light, so metals and emission look flatter. Turn *Lit* off for a cheaper, unlit impostor
  (`ImpostorData.lit = false`), or old data without normals, which falls back to unlit by itself. The normal atlas
  doubles the bake time and the file size.
- Views are blended, so you may see a soft ghost between angles with few views. Add views or rows to reduce it.
- The quad is a flat camera-facing billboard. With depth baked (the default for lit impostors) it intersects other
  geometry correctly; without it, where impostors overlap each other or real geometry the intersection is a straight line.
- Meant for the far distance. Keep the switch distance high enough that parallax isn't visible.
- Baking needs a running renderer, so it works in the editor but not with `--headless`.
- Alpha is cut at 50%, so thin leaves can look slightly thinner in the distance.

## Tests

```bash
xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_impostor_tests.gd
xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_impostor_depth_tests.gd
```
