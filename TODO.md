# Shelter engine: progress tracker

Fork: `singam96/godot`. Working branch: `shelter-engine-dev` (from `codex/shelter-engine-fixes`).
CI runs: dispatch `linux_builds.yml` with `gh workflow run linux_builds.yml -R singam96/godot --ref <branch>`.

## Done
- [x] Check out `codex/shelter-engine-fixes`, create `shelter-engine-dev`
- [x] Add `upstream` remote (godotengine/godot), merge upstream `master` (210 commits, no conflicts)
- [x] Push `shelter-engine-dev` to origin
- [x] Fix strict-warning errors in `scene/3d/lightmap_gi.cpp` (shadowed `layers`, unhandled `CULL_MAX`)

## Grit integration (done)
- [x] Copy `modules/grit` (plus its MIT LICENSE), apply the native-call engine patch (two hunks ported by hand for 4.8)
- [x] Port the module to Godot 4.8 API changes; Linux Builds green (editor, unit tests, doc check, sanitizers, Mono)
- [x] Module tests run in CI
- [x] Sample projects in `samples/grit` (flappy, benchmark); `Grit Samples` workflow builds the editor, runs each in the VM, exports (generates C++), builds a template with the native code, runs it and diffs the results: green
- [x] Merge `grit-integration` into `shelter-engine-dev`, then both into `master`

## Notes
- Grit's `tools/grit.py` workflow assumes a separate 4.7.2 checkout. Here the module lives in-tree, so builds are plain `scons` with the module enabled; `tools/` is not imported.
- Local machine has no `scons` or X11/audio dev libraries, so all compile checks go through GitHub Actions.
- `get_stack()` is not populated by native code; the sample comparison skips that probe. Native vs VM is compared against a debug template (release templates differ on `is_debug_build()` paths).
- Not yet verified by eye: shadow/MultiMesh/texture-budget rendering changes. Needs a scene run.
