# Grit sample projects

- `flappy/`: a small Flappy Bird clone (inner class, typed arrays, vector math, signals with lambdas, `await`). No assets.
  Headless runs play 120000 physics steps with a fixed seed and print the result and time.
- `benchmark/`: micro benchmarks (loops, math, containers, node properties) plus semantic checks, run in the VM and natively.

Both projects ship export presets (`Linux`, and for flappy also `Linux Stripped` and `Windows Desktop`).

## Run with the regular GDScript VM

```sh
bin/godot.linuxbsd.editor.x86_64 --path samples/grit/flappy
bin/godot.linuxbsd.editor.x86_64 --headless --path samples/grit/benchmark
```

## Native (Grit) export

Exporting writes the generated C++ to `samples/grit/<project>/.godot/grit/generated`. Build an export template with it, then select
that template in the preset:

```sh
bin/godot.linuxbsd.editor.x86_64 --headless --path samples/grit/flappy --export-pack Linux build/flappy.pck
scons platform=linuxbsd target=template_release module_grit_enabled=yes grit_generated=samples/grit/flappy/.godot/grit/generated
```

Compare VM and native results by running the exported game with and without `GRIT_DISABLE=1`.
See `modules/grit` and https://github.com/singam96/grit for the full workflow.
