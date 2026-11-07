# Baked direct lamp shadow fixture

Run with an editor executable containing the native extension and a real Forward+ renderer:

```text
godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_baked_direct_shadow_tests.gd
```

The scene is built entirely from native primitives and synthetic textures. It checks standard STATIC light behavior, independent lamp shadow subtraction, preservation of ambient/other contributions, no double direct illumination, owner isolation, disabling, and matching baked/live visibility at a half-shadow edge. A spatial checker varies RGB and visibility together, then verifies a fully shadowed surface returns to its ambient reference under both default bicubic and linear filtering. A two-sample sun fixture verifies no double direct light, live actor shadows and illumination, and owner isolation. It then bakes a tiny UV2 fixture to native texture resources without the editor importer, checks both omni and directional direct visibility output, RGB versus RGBA16F output and fully occluded irradiance, and updates probe colors on a stationary dynamic mesh. A final grid verifies twelve simultaneously visible independent lightmaps retain their own colors on devices supporting the larger budget, or eight on the compatibility budget.

Success prints `BAKED_DIRECT_SHADOW_TESTS checks=33 failures=0`. Native bake outputs are written to a unique `user://baked_direct_fixture_*` folder. Run with `-- --baseline-only` on the comparison engine to check the fixture's existing STATIC behavior; success prints `BAKED_DIRECT_BASELINE checks=4 failures=0`.

The fixture does not measure performance. The opt-in path preserves ordinary static shadow casters for correct lighting on moving meshes, so shadow rendering remains a cost. Other renderers and directional lightmaps retain standard behavior.

Forward+ supports 32 visible lightmaps when both sampled-image limits (per stage and per descriptor set) are at least 128. The light and shadowmask array uses 64 image slots, leaving 64 for other scene/material images; it uses the existing shared samplers. Devices below this capability retain the previous eight-map budget. Mobile is unchanged. Run `-- --budget-only` to isolate the grid test; the comparison engine is expected to fail with only eight of twelve colors matched on a capable device.

## Offline/runtime contract

1. Prepare static ArrayMeshes with UV2, normals and assigned node owners. Keep geometry and atlas layout identical between production lighting passes.
2. Bake ordinary environment/time samples with `gi.bake_lightmaps(root, path, true)`. A dynamic sun keeps direct solar light and its shadows live.
3. Bake one STATIC point OmniLight3D at a time with `gi.bake_lightmaps(root, path, true, true)`. This requires zero bounces and disabled environment, directional packing, shadowmask and denoising. It emits RGB unoccluded irradiance and alpha static visibility.
4. Compose interpolated environment lighting and each enabled lamp's `RGB * A` into the main slices of one texture array. Append each lamp's original RGBA contribution slices using the same UVs and exposure. For `S` canonical slices, offsets are `S`, `2*S`, and so on.
5. Set the owner's lightmap textures to one texture array and call `lamp.set_baked_shadow_lightmap(owner_data, lamp_offset)`. The shader applies the main atlas's filter to both RGB and RGB*A, then subtracts only `max(filtered(RGB*A) - filtered(RGB) * live_visibility, 0)`. This reduces to `RGB * max(baked_visibility - live_visibility, 0)` for uniform irradiance and avoids colored residuals where RGB and visibility vary together. Pass `null, -1` to disable. Lamp switches must also remove that lamp's contribution from the composed main slices.

The association is runtime-only, Forward+ only, non-directional only, and requires the light's baked pose/color/energy to match the saved contribution. It does not bake gameplay state or replace moving actors, doors, flashlight lighting or real-time direct illumination on dynamic meshes. Scalar visibility is intended for opaque static casters; arbitrary colored transmissive casters are outside this first path.

## Sampled direct sunlight

Bake the direct sun separately at each time with one STATIC DirectionalLight3D, zero angular size, zero bounces, no environment, no denoiser, and direct visibility enabled. Keep bounced daylight in its independent day samples. Geometry and atlas settings remain identical across all passes.

At runtime append two sun groups after the lamp groups. For adjacent time samples, multiply each group's RGB by its interpolation weight and weather multiplier, preserve each alpha, and add both RGB*A values into the composed base. Do not interpolate RGB and alpha independently before multiplication. For S pages and L lamps, use offsets S*(L+1) and S*(L+2).

Use two directional lights with matching rotations. Keep the world sun BAKE_STATIC with its full shadow caster mask, so it still lights and shadows actors and unmapped world surfaces while mapped geometry receives its direct sun from the bake. Add a zero-energy, BAKE_DYNAMIC, SKY_MODE_LIGHT_ONLY directional whose shadow caster mask contains only moving or unbaked geometry. Associate this second light using `runtime_data.set_baked_sun_shadow_layers(moving_shadow_sun, first_offset, second_offset)` before or after assigning the output array. This association is per data resource and supports multiple homes using the same shadow light. The second light subtracts moving-object occlusion from the two baked samples without overlaying current-direction static shadows. Its caster bit must be present on actors, movable doors and unbaked geometry while remaining absent from mapped static casters. The fixture verifies zero-energy shadows, exclusion of static casters on mapped surfaces, and preservation of their shadows on dynamic actors. Both native shadow passes remain active, so performance must still be measured.
