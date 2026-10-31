# Perf Overlay

An in-game overlay that shows what a frame costs and compares it with your budgets, so you can see which area of an
open world is too heavy.

## Install

Copy `addons/perf_overlay/` into your project and enable **Perf Overlay**. It registers an autoload named
`PerfOverlay`. Press **F3** in a running game to show or hide it.

## What it shows

- FPS, frame time, script and physics time.
- Draw calls, triangles and objects drawn this frame, each against a budget: green up to 80%, yellow up to 100%, red above.
- Node count and VRAM use of textures and buffers.
- A graph of the last 180 frames with the budget line, and a count of **hitches** (frames longer than 2x the budget)
  in the last 10 seconds.
- With *Streamer* set to a `WorldStreamer`: loaded detail and far cells, and whether it is still loading.

Set the budgets on the autoload node (Project Settings > Globals > Autoload does not show exports; set them from a
script: `PerfOverlay.draw_calls = 2000`). The numbers to start from: 2500 draw calls and 3M triangles for a mid-range
PC; much less for mobile.

## Use it to decide

If draw calls are over budget: more MultiMesh, HLOD or occluders. If triangles are over: more LOD/HLOD/impostors.
If only hitches show up: check streaming (frame budget, prewarm). If script time dominates: look at your own code.

`snapshot()` returns all numbers as a Dictionary, `evaluate(snapshot)` the statuses, handy for automated performance
tests that fail a build when a scene is over budget.

Tests: `godot --headless --path . -s res://tests/run_overlay_tests.gd`
