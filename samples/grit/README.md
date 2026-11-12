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

Exporting is automatic. When a Linux export runs on a Linux machine with the engine source (an editor built in the source tree),
Grit generates the C++, builds an export template with it (`grit/export/build_template`, on by default) and uses that template
for the exported game. If the engine source or SCons is not available, the export still works and runs the scripts in the VM.

```sh
bin/godot.linuxbsd.editor.x86_64 --headless --path samples/grit/flappy --export-release Linux build/flappy
```

The first export compiles the whole engine, later ones only rebuild what changed. Set `grit/export/engine_source_directory`,
`grit/export/scons_command` and `grit/export/scons_arguments` in the project settings if the defaults do not fit your setup.
Exports for other platforms and exports with a custom template are not built automatically: build the template yourself with
`grit_generated` pointing at `.godot/grit/generated`.

Compare VM and native results by running the exported game with and without `GRIT_DISABLE=1`.
See `modules/grit` and https://github.com/singam96/grit for the full workflow.
