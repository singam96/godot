# Baked direct lamp shadow fixture

Run with an editor executable containing the native extension and a real Forward+ renderer:

```text
godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_baked_direct_shadow_tests.gd
```

The scene is built entirely from native primitives and synthetic textures. It checks standard STATIC light behavior, independent lamp shadow subtraction, preservation of ambient/other contributions, no double direct illumination, owner isolation, disabling, and matching baked/live visibility at a half-shadow edge. It then bakes a tiny UV2 fixture to native texture resources without the editor importer, checks RGB versus RGBA16F visibility output and fully occluded irradiance, and updates probe colors on a stationary dynamic mesh.

Success prints `BAKED_DIRECT_SHADOW_TESTS checks=20 failures=0`. Native bake outputs are written to a unique `user://baked_direct_fixture_*` folder. Run with `-- --baseline-only` on the comparison engine to check the fixture's existing STATIC behavior; success prints `BAKED_DIRECT_BASELINE checks=4 failures=0`.

The fixture does not measure performance. The opt-in path preserves ordinary static shadow casters for correct lighting on moving meshes, so shadow rendering remains a cost. Other renderers and directional lightmaps retain standard behavior.

## Offline/runtime contract

1. Prepare static ArrayMeshes with UV2, normals and assigned node owners. Keep geometry and atlas layout identical between production lighting passes.
2. Bake ordinary environment/time samples with `gi.bake_lightmaps(root, path, true)`. A dynamic sun keeps direct solar light and its shadows live.
3. Bake one STATIC point OmniLight3D at a time with `gi.bake_lightmaps(root, path, true, true)`. This requires zero bounces and disabled environment, directional packing, shadowmask and denoising. It emits RGB unoccluded irradiance and alpha static visibility.
4. Compose interpolated environment lighting and each enabled lamp's `RGB * A` into the main slices of one texture array. Append each lamp's original RGBA contribution slices using the same UVs and exposure. For `S` canonical slices, offsets are `S`, `2*S`, and so on.
5. Set the owner's lightmap textures to one texture array and call `lamp.set_baked_shadow_lightmap(owner_data, lamp_offset)`. The shader subtracts only `RGB * max(baked_visibility - live_visibility, 0)`. Pass `null, -1` to disable. Lamp switches must also remove that lamp's contribution from the composed main slices.

The association is runtime-only, Forward+ only, non-directional only, and requires the light's baked pose/color/energy to match the saved contribution. It does not bake gameplay state or replace moving actors, doors, flashlight lighting or real-time direct illumination on dynamic meshes. Scalar visibility is intended for opaque static casters; arbitrary colored transmissive casters are outside this first path.
