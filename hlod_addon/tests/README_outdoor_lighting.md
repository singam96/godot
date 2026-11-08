# Opt-in baked outdoor lighting

`RenderingServer.environment_set_baked_outdoor_lighting(env, sun_base, textures,
parameters, pages, receiver_mask, moving_mask)` is a Forward+ extension. Passing
an empty sun RID clears it. The host keeps texture resources alive until clearing
the environment. The source sun RID is `DirectionalLight3D.get_light_rid()`.

Textures: coarse static reverse-Z depth array, persistent fine-depth page pool,
optional coarse RGBA ambient field and persistent fine ambient-field page pool.
Depth is raw linear-normalized reverse Z, with zero for empty. The ambient field
contains ground height and sky visibility at 0.5/8/24 m above ground; visibility
returns gradually to one above 24–40 m. Texture data is immutable except for
bounded page-pool uploads. Metadata/time changes never recreate these textures.

The 80-float header is twenty vec4s: two column-major world-to-map matrices (0–7),
two ambient RGB coefficients (8–9), two solar RGB radiances/coarse-layer indices
(10–11), two world-space directions toward the sun/normal biases (12–13), time
blend/two normalized-depth biases/tile gutter (14), two sun-grid dimensions (15),
weather sun gain (16), weather ambient gain/static shadow opacity (17), ambient
world-XZ rectangle (18), and ambient grid dimensions/enabled/gutter (19).

The page table stores sample A, sample B, then ambient grid, in row-major order.
Each dimension is bounded by 32; maximum 3,072 entries. Negative entries fall
back to the corresponding shipped coarse field. Page indices are published only
after their image upload. Compare individual depth taps, then filter visibility;
never average depth values. Sun irradiance weights each sample's RGB, cosine and
visibility before blending. Actor visibility is weighted by contributing sampled
radiance, so a zero-energy night sample cannot dilute a daytime shadow.

Static receivers reconstruct diffuse irradiance and spatial sky fill instead of
ordinary sunlight/ambient; the renderer applies exposure and albedo once. Moving
objects retain their material lighting and combine cached static visibility with
live moving visibility. Outdoor actors also receive the baked sky field;
existing SH captures, lightmaps, SDFGI/VoxelGI and custom irradiance retain priority.
Ordinary RGB lightmaps are excluded. Their existing sun
subtraction helper remains moving-only, allowing one shared primary sun.
Separate filtered masks combine conservatively by minimum, consistent with SSCS;
this is not exact correlated PCF union. The ambient field approximates sky
occlusion, not a bake of all diffuse interreflection. Other renderers ignore the
opt-in data. Materials should use matte diffuse shading; specular/refraction and
other genuinely changing lights remain on the normal rendering path.

Procedural checks:

```
godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_outdoor_shader_tests.gd
godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_outdoor_shader_tests.gd -- --negative-control
godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_outdoor_baked_tests.gd
```

The shader check compiles the actual sampler and reconstruction functions in
vertex/fragment/compute stages, including the actual native call sites and packed
mat3x4 camera context. Its negative control removes the actual header
field and must fail all three stages. `run_outdoor_baked_tests.gd` checks native
binding, radiance/cosine interpolation, moving-receiver occlusion, fine/coarse
fallback, sunrise weighting, environment ownership and disabling. Run the existing
baked-direct and context fixtures as well; these tests do not establish FPS.
`--negative-context-control` deliberately restores the invalid packed-camera
multiplication and must reject all three stages. This guards the first rendered
candidate's compilation failure before another engine rebuild.

Light3D initializes its visual instance directly and leaves the inherited
VisualInstance3D base RID empty. Use the explicit get_light_rid() binding; an
empty sun RID intentionally clears the environment cache.

Rendered acceptance on 0c7a72d: 27 checks cover static/actor sampled visibility,
per-sample normals, coarse/fine fallbacks, disabled live shadows, environment
ownership, sky fields and live moving-only shadows. Existing lamp/home shadow
fixture: 39 checks; bake context: 13 checks. All pass without shader diagnostics.

Receiver-plane depth correction is applied to each comparison tap, including
the fine-page coordinate scale. A sloped-depth fixture fails on 0c7a72d without
this correction; increasing a global normal offset is not used to hide it.
