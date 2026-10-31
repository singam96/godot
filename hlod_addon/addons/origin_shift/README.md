# Origin Shift

Float precision gets worse the farther you are from the origin: a few kilometers out, meshes jitter, physics gets
noisy, shadows crawl and animations wobble. This add-on moves the whole world back toward the origin whenever the
player strays too far, and remembers the total offset in 64-bit numbers, so absolute coordinates stay exact.

## Install

Copy `addons/origin_shift/` into your project and enable it (the plugin itself does nothing in the editor; the
`OriginShifter` node works at run time).

## Use

1. Put everything in your world under one `Node3D` (the *world root*). The player can be below it too.
2. Add an **OriginShifter** node. Set *Target* (usually the player), *World Root*, and optionally *Extra Nodes* that
   live outside the world root (a camera rig). *Threshold* is the distance from the origin where a shift happens
   (default 2000 m); shifts are multiples of *Snap* (default 500 m).
3. Use `to_absolute(pos)`, `to_local_position(abs)` and `get_absolute_position(node)` wherever you need true coordinates
   (save games, maps, multiplayer). They return or take `[x, y, z]` as 64-bit floats.
4. Connect to `origin_shifted(shift)` to fix anything that does not follow the world root, such as particles using
   world-space coordinates, trails, or cached positions in your own scripts.

The **World Streaming** add-on works unchanged when its `WorldStreamer` sits below the world root: cells move with it.
Shifts happen between physics frames; bodies are moved, not simulated across the jump.

## What it can't do

- Things that are not below the world root, the extra nodes or the target are not moved.
- A shift is a teleport of everything at once. Anything that stores absolute positions in 32-bit floats (your own
  caches, navigation links, saved transforms) has to be converted with `to_absolute`.
- Physics bodies resting on each other keep their relative positions, but a very large jump in one frame can disturb
  joints; use a large *Snap* so shifts are rare.

## Alternative: double-precision engine

Godot can be compiled with 64-bit coordinates (`scons precision=double`), which removes the problem for worlds of
hundreds of kilometers without any shifting. It needs your own engine build and export templates, and it doubles the
size of vectors and transforms (a bit slower, more memory). If you already build the engine, prefer this and skip the add-on.

Tests: `godot --headless --path . -s res://tests/run_origin_tests.gd`
