# Shelter engine: progress tracker

Fork: `singam96/godot`. Working branch: `shelter-engine-dev` (from `codex/shelter-engine-fixes`).
CI runs: dispatch `linux_builds.yml` with `gh workflow run linux_builds.yml -R singam96/godot --ref <branch>`.

## Done
- [x] Check out `codex/shelter-engine-fixes`, create `shelter-engine-dev`
- [x] Add `upstream` remote (godotengine/godot), merge upstream `master` (210 commits, no conflicts)
- [x] Push `shelter-engine-dev` to origin
- [x] Fix strict-warning errors in `scene/3d/lightmap_gi.cpp` (shadowed `layers`, unhandled `CULL_MAX`)

## In progress
- [ ] CI run 43086956536 on `shelter-engine-dev` (after the LightmapGI fix): fix whatever else fails
- [ ] Integrate Grit (https://github.com/singam96/grit) on branch `grit-integration`
  - [x] Copy `modules/grit` (plus its MIT LICENSE) into `modules/grit`
  - [x] Apply `patches/4.7.2-stable/0001-gdscript-native-call-hooks.patch` (5 hunks by `git apply`, 2 ported by hand for 4.8: native-call dispatch in `gdscript_vm.cpp`, friend in `GDScriptFunctionState`)
  - [ ] Get the engine compiling with the module on 4.8 (Grit targets 4.7.2; expect API drift)
  - [ ] Run Grit's module tests (`modules/grit/tests`) in CI
  - [ ] Merge `grit-integration` into `shelter-engine-dev` once green

## Notes
- Grit's `tools/grit.py` workflow assumes a separate 4.7.2 checkout. Here the module lives in-tree, so builds are plain `scons` with the module enabled; `tools/` is not imported.
- Local machine has no `scons` or X11/audio dev libraries, so all compile checks go through GitHub Actions.
- Not yet verified by eye: shadow/MultiMesh/texture-budget rendering changes. Needs a scene run.
