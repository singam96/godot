# Baked direct lamp shadow fixture

Run with an editor executable containing the native extension and a real Forward+ renderer:

```text
godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_baked_direct_shadow_tests.gd
```

Before rebuilding, run `godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_directional_shadow_shader_tests.gd`. This reads the actual native directional shadow helper, native directional light struct and both actual call sites, then compiles their fragment shader interfaces under four variants. Success prints `DIRECTIONAL_SHADOW_CALLS_OK variants=4 calls=2`. Add `-- --negative-control` to deliberately remove the default caller's scene arguments in memory and verify compilation rejects it. Sampling functions are isolated stubs; the rendered fixture above remains the complete pipeline check.

`godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_lightmapper_shader_tests.gd` compiles the complete current native lightmapper compute source under all seven stages and six option combinations. Success prints `LIGHTMAPPER_SHADER_TESTS checks=42 failures=0`. Its `-- --negative-control` removes the context triangle field in memory and must print `LIGHTMAPPER_SHADER_NEGATIVE_CONTROL_OK`.

The scene is built entirely from native primitives and synthetic textures. It checks standard STATIC light behavior, independent lamp shadow subtraction, preservation of ambient/other contributions, no double direct illumination, owner isolation, disabling, and matching baked/live visibility at a half-shadow edge. A spatial checker varies RGB and visibility together, then verifies a fully shadowed surface returns to its ambient reference under both default bicubic and linear filtering. A two-sample sun fixture verifies no double direct light, live actor shadows and illumination, and owner isolation. An unmapped custom-light panel verifies that zero-energy shadow-only directionals skip regular lighting, while positive, tiny-positive and negative energy still execute it. The mapped shadow subtraction remains independent. It then bakes a tiny UV2 fixture to native texture resources without the editor importer, checks both omni and directional direct visibility output, RGB versus RGBA16F output and fully occluded irradiance, and updates probe colors on a stationary dynamic mesh. A final grid verifies twelve simultaneously visible independent lightmaps retain their own colors on devices supporting the larger budget, or eight on the compatibility budget.

Success prints `BAKED_DIRECT_SHADOW_TESTS checks=39 failures=0`. Native bake outputs are written to a unique `user://baked_direct_fixture_*` folder. Run with `-- --baseline-only` on the comparison engine to check the fixture's existing STATIC behavior; success prints `BAKED_DIRECT_BASELINE checks=4 failures=0`.

The fixture does not measure performance. The opt-in path preserves ordinary static shadow casters for correct lighting on moving meshes, so shadow rendering remains a cost. Other renderers and directional lightmaps retain standard behavior.

The orthographic fixture camera uses a 30 m far plane; directional shadow max distance does not shorten an orthographic camera's shadow frustum. Before the first synchronous bake, the fixture waits for a process frame and post-draw so newly created materials have render-thread uniform sets. Offline tools creating new meshes/materials should do the same before calling `bake_lightmaps`.

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

## Nearby static occlusion context

Call `gi.bake_lightmaps(receiver_root, path, true, direct_visibility, context_root)` with a separate sibling hierarchy containing a bounded set of nearby terrain, trees and neighboring walls. Context accepts finished MeshInstance3D meshes and MultiMeshInstance3D transforms without UV2 or owners. It includes every instance regardless of runtime visibility; exclude receiver duplicates, shadow proxies and impostors when preparing the hierarchy. The context must be inside the scene tree for global transforms. It is acceleration-only: no atlas users, receiver slices, seams, capture bounds or probe positions are added. Rays can reach context outside the receiver's bounds. Opaque context absorbs indirect rays without reflecting or emitting light.

Provide BaseMaterial3D opaque or alpha-scissor materials, converting custom shaders to matching offline StandardMaterial3D overrides. Cutouts use albedo texture alpha, albedo color alpha, cutoff, UV1 scale/offset and repeat/clamp. A nearest-sampled 128 by 128 mask is prepared once per material; absent textures use constant albedo alpha. Arbitrary shader logic, triplanar cutouts, translucency and colored transmission are rejected or unsupported. Holes are rejected inside the triangle traversal itself, so direct, indirect, probe and unocclusion rays all pass through them without spending transparency-ray retries.

Run `godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_bake_context_tests.gd`. This entirely procedural bake checks a UV1-only cutout with a central hole, ownerless opaque geometry, a transformed runtime-hidden MultiMesh 20 m above the receiver, neutral white irradiance, and unchanged receiver/probe layout across direct RGBA and denoised one-bounce daylight. Success prints `BAKE_CONTEXT_TESTS checks=13 failures=0`. Outputs use a unique `user://bake_context_fixture_*` folder. The test requires a build containing the five-argument API; script and complete compute shader checks can run before rebuilding, but the actual context bake requires the rebuilt editor.

## Zero-energy runtime shading

Forward+ skips exact-zero directional energy in its ordinary vertex, shadow and
fragment-light loops. Baked-sun owner sampling remains independent and continues
to render moving shadows. Exact equality preserves faint and negative lights.
This avoids needless normal shadow/BRDF work and prevents a shadow-only light
from invoking energy-independent custom `light()` callbacks on unmapped meshes.
The old C621 editor fails exactly the zero-energy panel check (39 checks, one
expected failure); it remains a compatible offline baker because these changes
do not alter the lightmapper, serialized data or native association APIs.
