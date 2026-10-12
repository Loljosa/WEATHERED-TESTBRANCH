# Phase 2.65: continuous atmospheric reconstruction with 3D cloud cubes

The corrected presentation uses **actual three-dimensional Roblox Block Parts**,
with equal positive X/Y/Z dimensions. The user's cube-geometry correction
supersedes the earlier billboard/puff prototype. The cloud renderer contains no
sprites, BillboardGuis, ImageLabels, ParticleEmitters, Balls or Gaussian discs.
Small cubes express reconstructed cloud volume instead of exposing the enormous
rectangular physical cells.

The authoritative atmosphere stays at Phase 2.6: exactly 4028 × 4028 studs,
sixteen logical regions, fixed 0.25-second physical steps, conservative transport,
warm-cloud microphysics, seeded sources and source budgets. Graphics quality
neither changes the solver nor introduces simulated water.

**Studio visual acceptance remains pending.** This environment cannot run Roblox
Studio. Production-module tests verify geometry, reconstruction, resources and
authority; offline cube-face projections verify geometric descriptors. Neither
establishes game appearance, transparency sorting, hardware FPS or network
latency. The manual gate below is required before declaring a completed visual
release. This is an intentional cubic representation, not photorealistic
volumetric rendering.

## Modules and ownership

| Files / representation | Responsibility |
| --- | --- |
| Existing `World/WeatherField.lua`, `WorldCloudSources.lua` | Server theta, qv, qc, qr, physical winds, budgets and transport |
| `Rendering/CloudRenderSnapshot.lua`, server `CloudRenderReplication.lua` | Complete, versioned, quantized authoritative render data |
| `CloudDensityReconstruction.lua` | Continuous spatial/temporal liquid sampling, bounded display density and gradients |
| `CloudSurfaceAnalysis.lua` | Reusable packed local-column cloud base/top envelopes |
| `CloudDetailNoise.lua`, `CloudRenderConfig.lua`, `CloudLighting.lua`, `CloudRenderLOD.lua` | Seeded density-constrained detail, layered cubes, approximate illumination and quality budgets |
| Client `Rendering/CloudRenderer.lua`, `CloudClusterPool.lua` | Pooled genuine cubes, selection, movement, culling, updates and cleanup |
| Client `WorldWeatherClient.lua`, `WeatherClient.client.lua` and metadata | Shared snapshots, local modes/commands, quality and listener lifecycle |
| Existing `World/WorldVoxelDebugRenderer.lua`, sparse `WeatherSnapshot.lua` | Separate coarse-grid diagnostics; never reconstruction input |

Players share one physical atmosphere. Clients may render fewer details without
selecting another seed or running another solver. Late joiners request the
current cached packet through a rate-limited read-only path. No client remote
accepts wind, seed, source or atmospheric-state administration.

Integration modifies server `WorldWeatherBootstrap.lua`,
`WeatherServer.meta.json` and failure cleanup in the retained
`WeatherReplication.lua`; client `WeatherClient.client.lua`,
`WorldWeatherClient.lua` and new `WeatherClient.meta.json`; and the public engine
version in `Atmosphere/init.lua`. `README.md` links the implementation and
validation guide. Existing transport, microphysics, source-generation, pressure
projection and gameplay modules are preserved.

New scripts are `test-cloud-rendering.luau`,
`benchmark-cloud-render-data.luau` and `project-cloud-cubes.luau`. Ten focused
test modules cover density, surface analysis, temporal reconstruction, packet
completeness, render seeding, quality consistency, resources, vertical
preparation, client integration and cubic geometry. `CloudRenderFixture.luau`
and `CloudRenderInstanceSpy.luau` supply production-input/engine-boundary fixtures;
the existing module loader and world bootstrap test adapt to the new integration.

## Complete render data

The preserved Phase 2.6 `WTHR` diagnostic codec selects at most 256/512 strongest
liquid cells. Its omitted cells are **unknown**, not known empty; it cannot
guarantee the eight neighbors required for spatial interpolation.

The independent `WCR2` codec contains every qc sample, including zeros. It rejects
the sparse format and validates version, dimensions, finite geometry/scales and
complete-neighborhood flags. Logical region boundaries require no crop or reseed.

| Component | Encoding |
| --- | --- |
| Header | 128 B: format/version, qc/wind dimensions, signed seed, generation, sequence, simulation/wall/dropped clocks, world geometry, studs/m, physical base, boundary and quantization scales |
| qc | One uint8 per physical cell, X-fast, Z-next, Y-outer ordering |
| Wind | Complete floor(Nx/4) × Ny × floor(Nz/4) lattice, three int16 components in physical m/s |

Square-root liquid companding preserves weak edges better than a linear byte:

`byte = round(255 sqrt(qc / qcMax))`

`qcDecoded = qcMax (byte / 255)^2`

For a zero maximum, all cells are known quantized zeros. A zero byte can also
represent tiny positive liquid rounded below the quantization floor; it does not
assert an exact zero in the unquantized server field. Approximate maximum absolute
error is `qcMax (1/255 + 1/(4×255²))`, with separately validated scale rounding.
The packet is a display approximation, not the numerical water inventory.

| Server preset | qc cells | Wind samples | Complete packet at 1 Hz | Retained diagnostic channel |
| --- | ---: | ---: | ---: | ---: |
| Laptop, 32 × 6 × 32 | 6144 | 384 | 8576 B/s | 4712 B/s |
| Full, 48 × 6 × 48 | 13,824 | 864 | 19,136 B/s | 18,640 B/s |

The two default channels total **13,288 B/s Laptop / 37,776 B/s Full per recipient**
before protocol overhead. No unmeasured compression savings are claimed. Packets
are capped at 64 KiB; stalled frames publish one current packet without a catch-up
burst. Decode retains the payload and scalar metadata instead of one table per
cell. Neither channel replicates Parts or cube-by-cube updates.

## Continuous reconstruction, boundaries and clocks

Eight complete cell-center samples feed bounded trilinear interpolation. Positive
inputs remain positive and cannot overshoot neighboring values. The shared display
reference is `5×10⁻⁵ kg/kg`:

`D(x,y,z,t) = 1 - exp(-qcReconstructed / qcReference)`

An empty liquid field produces zero display density. Vanishing traces are not
renormalized to opaque using a declining current maximum. Centered differences
at one-eighth-cell offsets provide three gradient scalars in display density per
stud, avoiding a vector allocation per physical cell.

X/Z sampling is continuous across internal 1007-stud region lines and periodic
only at the world's outer boundary. Sealed lateral/vertical faces smoothly taper
display support over the outer half-cell and return zero outside the domain.
This display window does not alter numerical boundary conditions.

Generation, signed seed, geometry and sequence govern history. Old/out-of-order
packets reject; regeneration invalidates incompatible history. Server wall
intervals determine playback duration, while simulated intervals determine
displacement. Pausing simulation cannot advance carriers because wall time passes.

Velocity-assisted sampling traces the old field backward and the new field
forward to a common intermediate display time, then blends. The conversion is
the shared **2 studs/m default**. Tracing is bounded to two simulated seconds and
one cell per axis, and never replaces server transport. Stale updates hold
briefly, then fade after ten wall seconds over twenty seconds. There is no
indefinite motion extrapolation.

## Real cubic cloud geometry

Each element is one `Part` with `Shape=Enum.PartType.Block` and equal positive
axis sizes. It is noncolliding, nontouching, nonqueryable and shadow-free.
Positions derive from world-space density and stable seeded identity; camera
position only affects visibility and LOD priority. There is no texture dependency
or camera-facing plane.

| Presentation | Phase 2.6 diagnostics | Corrected Phase 2.65 Cubes |
| --- | --- | --- |
| Shape | One large rectangular cell Part | Smaller equal-axis three-dimensional Block Parts |
| Laptop dimensions | About 119.58 × 22.8 × 119.58 studs | 12/16/24/48-stud cubic subdivision levels |
| Full dimensions | About 79.72 × 22.8 × 79.72 studs | Same geometry and continuous-density settings |
| Largest allowed element | 95% of horizontal cell width | 48 studs per equal axis, constrained by physical vertical bounds |
| Input | Top-K selected coarse cells | Complete continuous-density neighborhoods |
| Role | Exact coarse numerical diagnostics | Requested cubic gameplay representation |

The rendering hierarchy uses world-aligned 48-stud cubic macroregions and
uniform subdivision along **all three axes**, N=1..4, producing 48/24/16/12-stud
Blocks. It is a bounded display hierarchy, not additional physical atmospheric
cells. Occupancy and density gradients concentrate detail on useful cloudy
material; time-sliced selection avoids a synchronous full fine-world sweep.
Cold startup can publish partial candidates so a first cloud does not wait for
a complete pass. Once established, a cloud keeps its valid selection until a
complete frontier replaces it atomically. An unfinished next pass cannot evict
valid cubes and make a paused cloud cyclically shrink. Existing cubes continue
sampling current qc, fading/evaporating and following wind during that scan.
Newly useful geometry may wait for a full bounded pass; this latency must be
measured separately from the cadence of existing-cube updates.

Column caches estimate local base/top from decoded liquid above `10⁻⁷ kg/kg` and
interpolate neighboring occupied envelopes. A candidate still requires positive
local reconstructed density, so the envelope cannot fill an empty gap. Cubes
remain inside the vertical physical bounds, and the renderer cannot stretch the
72 m layer into a fictitious tower.

`h = clamp((y - localBase) / max(localTop - localBase, epsilon), 0, 1)`

Default lower/middle/upper proportions are 25% / 40% / 35%. C1-continuous artistic
settings desire sides 12→14→20→24 studs and progressively lower sampling density
above; available subdivision levels approximate those targets without flattening
any axis. They express local liquid geometry, not six-layer resolved turbulence.

Broad/contour/fine coherent noise uses roughly 240/72/23-stud horizontal scales.
It only attenuates existing density, never introducing qc or permanent bright
islands. Quality permits one/two/three noise calls per selected point. Identity
does not depend on players or logical region activation. Noise is world-stationary;
bounded wind carriers and temporal density drive motion. Moved centers continually
resample qc and retire/reanchor before half a coarse cell, preventing persistent
clouds left in dry air. Formation and evaporation control gradual opacity.

This is an intentional faceted cubic silhouette. Transparency should be subtle
in dense material and fade at thin boundaries; it needs real Studio review.
Alpha cube sorting/overdraw differs from sprites and still carries GPU costs.

## Basic illumination

Neutral Part color combines ambient brightness, sun direction, `-gradient(D)`,
local height and bounded density/thickness attenuation. Upper material brightens
and denser lower material darkens without a black underside. High/Ultra can cache
two/three selected samples toward the sun. This is per-cube approximate shading,
not multiple scattering or per-pixel integration. No uploaded texture or invented
asset identifier is needed; native Part lighting must be inspected in Studio.

## Quality, resource caps and local commands

| Graphics | Active cubes | Clusters | Retained cubes | Creates / updates per refresh | Refresh | View distance |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Mobile | 256 | 32 | 288 | 6 / 64 | 5 Hz | 1500 studs |
| Balanced | 512 | 48 | 576 | 8 / 96 | 8 Hz | 2200 studs |
| High | 768 | 64 | 864 | 12 / 128 | 10 Hz | 3000 studs |
| Ultra | 1280 | 96 | 1408 | 16 / 192 | 12 Hz | 5000 studs |

One cube owns one Part plus a single Folder per pool: maximum retained allocation
is 289/577/865/1409 Instances. There are zero emitters, particles and image objects.
Packed selection buffers, bounded slices and creation caps limit bursts. Soft
CPU budgets are 2/3/4/5 ms and cannot interrupt an operation or runtime pause.
LOD hysteresis limits repeated rebuilding. Mobile may omit far detail while
sharing the same underlying cloud positions. A full pool refresh spans multiple
scheduled updates; actual motion latency and transparency cost need profiling.

`Cubes` is default. `Smooth` is a compatibility alias for the same renderer.
`Voxels` chooses preserved coarse Parts, `HybridDebug` deliberately enables both,
and `Off` hides local cloud geometry. Modes never reset the atmospheric field.
Region/vector overlays remain diagnostics; meteorological commands stay server-only.

In Studio's **client** Command Bar:

```lua
local controls = game.Players.LocalPlayer.PlayerScripts.Weather.WeatherClient.CloudVisualControls
print(controls:Invoke("cloudrender cubes"))
print(controls:Invoke("cloudquality mobile"))
print(controls:Invoke("clouddebug density"))
print(controls:Invoke("cloudrenderstats"))
print(controls:Invoke("cloudsnapshots"))
```

Other debug choices are gradients, bounds and off. The LocalScript's
`CloudRenderCommand` attribute also accepts commands. Client quality does not
modify weather. Meteorological commands retain the server Script's
`WeatherCommand` and `WeatherControls` interfaces.

## Vertical preparation

Release physics retains six levels over **72 meters**, displayed at Y424–568 with
2 studs/m. Absolute hydrostatic pressure remains separate from MAC pressure
correction. Optional one-way MAC detail remains off by default; graphics do not
enable it.

The production `cloud-vertical-preparation` probe compares 8 levels/240 m and
12 levels/480 m using real pressure, theta, saturation, sources, conservative
transport, CFL, boundaries and inventories. It is preparation, not a default
change. Across three 60-second scenarios it passed 347,240 checks; packed
field/source storage was 1,606,384 / 2,133,312 / 3,187,168 B and maximum corrected
water drift approximately 2.15×10⁻¹⁴ / 3.31×10⁻¹⁴ / 1.47×10⁻¹³. Exploratory
concurrent timings are not an isolated performance comparison. Prescribed coarse
circulation in every case does not demonstrate resolved deep convection.

## Checks and reproducible benchmark

```bash
rokit install
npm ci
npx stylua --check src scripts tests
lune run scripts/test-atmosphere.luau
lune run scripts/test-seeded-clouds.luau
lune run scripts/test-world-weather.luau
lune run scripts/test-cloud-rendering.luau
rojo build default.project.json -o build/WEATHERED.rbxlx
git diff --check
```

The runner executes production modules and replaces only Roblox service/Instance
boundaries. It covers bounded density, columns, packet clocks/order/generation,
complete neighborhoods, seeded detail, quality consistency, actual equal-axis
Block geometry, resource caps, cleanup, client controls and legacy diagnostics.
Fingerprints detect source/test changes during final runs.

For a frozen matching Phase 2.6 comparison without switching branches:

```bash
phase26_snapshot=$(mktemp -d)
git archive bba3a693f5c01f5425488959e06bb68778995e6b | tar -x -C "$phase26_snapshot"
lune run scripts/benchmark-cloud-render-data.luau --baseline "$phase26_snapshot"
```

Seed 84219, Scattered, wind 8/2 m/s, eight warmup plus 232 timed steps produce
60 simulated seconds. Matching field/face buffers must be byte-identical. Codec,
publication, reconstruction, noise, lighting and cube work are measured outside
physical step timing, across Ground/Side/Above/Close/Inside views. Direct steps
have no wall accumulator backlog; controller drops remain a Studio measure.

Final cube results belong in `build/phase265-render-benchmark.json`.
`build/phase265-cube-preview.json` contains actual Block Part positions, equal
XYZ sizes, color and transparency. Offline previews must project cube mesh faces,
never substitute circles, Gaussian discs, billboards or spheres. They are not
Studio captures or GPU measurements.

Earlier puff measurements survive under `build/prototype-*` as **historical,
superseded experiments**. Their CPU/object counts do not validate this renderer.
The isolated full **cube** benchmark passed on Lune 0.10.5 on an Intel Xeon
Platinum 8573C execution host with three visible CPUs. It verified matching
physical fields/faces byte-for-byte, fixed buffer counts, nonmutating visual
work, genuine equal-axis Block geometry and clean shutdown for all forty
quality/view/preset scenarios. Studio/GPU/FPS/visual acceptance remain untested.

| Matching 60-second numerical run | Mean / median / p95 incl. source work | Largest physical step | Field/source packed buffers |
| --- | ---: | ---: | ---: |
| Frozen Phase 2.6 Laptop | 21.170 / 19.879 / 30.103 ms | 38.398 ms | 43 / 1,606,384 B |
| Corrected Phase 2.65 Laptop | 21.344 / 19.923 / 30.169 ms | 39.721 ms | 43 / 1,606,384 B |
| Frozen Phase 2.6 Full | 46.351 / 44.215 / 64.554 ms | 97.792 ms | 43 / 3,607,152 B |
| Corrected Phase 2.65 Full | 45.535 / 43.676 / 57.245 ms | 120.078 ms | 43 / 3,607,152 B |

These small differences are host timing observations, not a claimed numerical
optimization: the matched physical results are byte-identical. Current core /
source mean splits are 20.981 / 0.363 ms Laptop and 44.959 / 0.576 ms Full. Initial
source construction costs 164.874 / 424.675 ms, compared with 182.493 / 433.102 ms
in the matching baseline. The presets keep 6/8 initial sources, sixteen bookkeeping
regions, at most two pending events, and 128/192 build samples per committed step.
Per one-substep tick the scalar updates/microphysics calls remain 24,576/6144 and
55,296/13,824. Neither architecture enabled local MAC detail during this run.

Both needed one CFL substep and produced the same source-corrected water drift
fractions, +1.22018×10⁻¹⁴ Laptop and −4.19038×10⁻¹⁴ Full. These are constant-density
unweighted mixing-ratio inventories, not kilograms. Direct stepping has no
wall-frame backlog; zero dropped time in this fixture is not a claim that Studio's
controller drops no steps. Both physical means still exceed the controller's
soft 8 ms catch-up budget, which cannot interrupt a single step.

| Render data, 20 samples | Laptop | Full |
| --- | ---: | ---: |
| Frozen sparse encoding mean | 1.210 ms | 2.675 ms |
| Complete encoding mean | 2.493 ms | 5.523 ms |
| Complete decoding mean | 0.008 ms | 0.007 ms |
| Frozen publication mean, transport spy | 2.730 ms | 4.959 ms |
| Complete publication mean, transport spy | 2.733 ms | 5.343 ms |
| Old transmitted / above-diagnostic-threshold cells | 256 / 877 | 512 / 2079 |
| Complete positive samples retained | 1466 / 1466 | 3410 / 3410 |
| Maximum qc quantization error | 1.421×10⁻⁷ kg/kg | 1.522×10⁻⁷ kg/kg |
| qc root-mean-square error | 2.619×10⁻⁸ kg/kg | 2.826×10⁻⁸ kg/kg |
| Two retained complete packets | 17,152 B | 38,272 B |
| Packed column cache | 9216 B | 20,736 B |

No positive samples quantized to zero in these particular fields; the format
still permits sufficiently tiny values to round to zero. Publication executes
the actual server class with a byte-counting transport spy. Roblox networking,
protocol overhead, compression and real latency are not measured by that spy.

A 2048-point batch costs 12.925 / 10.891 ms for continuous density, 54.147 / 45.674
ms for two-scale Balanced noise, and 1.177 / 0.874 ms for lighting. Gradient batches
use 256 points and cost 10.284 / 9.128 ms. Column construction costs 0.634 / 1.144
ms. These intentionally large operation batches are **not** a per-frame work list;
the actual renderer uses bounded updates, cached channels and time slicing.

The native cube test invokes the real renderer at sixty frame calls/s for sixteen
logical wall seconds per scenario. One-Hz complete snapshots hold the actual
final qc field and simulated time fixed, matching a paused simulation and avoiding
a misleading stale-data disappearance. Each view is anchored to the actual
maximum-qc cell; the global centroid could instead lie in clear space between
independent clouds. Spy properties record real geometry logic while replacing
the Roblox engine boundary. This is not a real Instance allocation or GPU test.

| Laptop quality, five camera views | Scheduled update mean range | p95 range | Largest observed call | Peak cubes / live spy Instances | Packed renderer data incl. packets |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mobile | 2.074–2.199 ms | 2.454–3.312 ms | 4.203 ms | 132 / 133 | 91,136 B |
| Balanced | 3.057–3.216 ms | 3.493–4.009 ms | 12.648 ms | 326 / 327 | 133,376 B |
| High | 4.068–4.088 ms | 4.313–4.448 ms | 5.780 ms | 526 / 527 | 175,616 B |
| Ultra | 5.080–5.120 ms | 5.353–5.651 ms | 8.091 ms | 746 / 747 | 260,096 B |

| Full source-data preset, five views | Scheduled update mean range | p95 range | Largest observed call | Peak cubes / live spy Instances | Packed renderer data incl. packets |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mobile | 2.033–2.155 ms | 2.266–3.173 ms | 3.768 ms | 153 / 154 | 123,776 B |
| Balanced | 3.058–3.533 ms | 3.296–4.215 ms | 45.745 ms | 321 / 322 | 166,016 B |
| High | 4.077–4.172 ms | 4.404–4.962 ms | 7.010 ms | 432 / 433 | 208,256 B |
| Ultra | 5.080–5.110 ms | 5.343–5.567 ms | 7.217 ms | 810 / 811 | 292,736 B |

These figures are scheduled updates at 5/8/10/12 Hz, not every video frame. Mean
cost over all sixty frame calls/s ranges from 0.171–0.182 ms Mobile to 1.017–1.025
ms Ultra on Laptop data, and 0.168–0.178 to 1.017–1.024 ms on Full data. Packed
bytes exclude Lua metadata, engine Parts, textures, the game and runtime memory.
The configured caps are higher than peak allocations observed in this short run;
the figures do not imply every allowed cube was populated in sixteen seconds.

The **45.745 ms Full/Balanced spike is retained**. Scheduling or garbage collection
may contribute, but this benchmark does not isolate the cause. Most scheduled
updates slightly exceeded their soft limits by finishing one ongoing operation;
the report records every overrun. Do not infer smooth mobile/Studio performance
from these figures. Actual transparent-face overdraw, engine property cost and
target-device allocation/GC behavior remain unmeasured.

The frozen actual voxel renderer averaged 0.676 ms Laptop / 1.571 ms Full per
five-Hz update, with 256/512 visible Parts and 257/513 live spy Instances. Cubic
reconstruction takes more CPU than directly displaying the strongest physical
cells; Mobile is cheaper than Ultra, while numerical server work stays unchanged.
It is a geometry-quality tradeoff, not a claim to accelerate the old diagnostics.

The cube preview contains 191 actual Ultra Parts at the sampled endpoint plus
256 matching old diagnostic rectangles. At that endpoint a first complete
frontier had replaced provisional geometry and its creation budget was filling
the new topology; it is not a fully populated 1280-cube scene. Separate regression
tests verify established valid IDs persist across later complete frontiers rather
than flickering out during incomplete passes. The proof is actual XYZ mesh data,
not a photograph or a shader approximation of hypothetical clouds.

To reproduce its five-view mesh comparison:

```bash
lune run scripts/project-cloud-cubes.luau
```

The resulting `build/phase265-cubic-geometry.svg` projects each Part's eight
corners and six faces with near-plane clipping and depth sorting. It compares
the legacy rectangles with the actual new cubes at ground, side, above, close
and inside/boundary viewpoints. The captured natural field is thin: cube centers
span 12 studs vertically and their 12-stud sides give about 24 studs of visible
height in this selection. That is evidence of genuine 3D cubes in a shallow
cloud, **not** resolved towering cumulus or the full allowed vertical extent.

The corrected `0.2.65-alpha` source passed the final applicable CLI gates:

| Validation | Actual outcome |
| --- | --- |
| Full new reconstruction/render/client/cubic/vertical suite | 498,026 checks passed |
| Final legacy atmospheric quick suite | 110,822 checks passed |
| Final seeded-cloud full suite | 55,217 checks passed |
| Final world-weather full suite | 177,722 checks passed |
| Earlier full atmospheric suite | 8,240,846 checks passed; physical numerical modules unchanged by cube correction |
| StyLua check of src/scripts/tests | Passed |
| Rojo CLI build | Passed; `build/WEATHERED.rbxlx` |
| `git diff --check` | Passed |
| Actual cube-face five-view projection | Passed; SVG and derived PNG |
| Roblox Studio / device FPS / GPU transparency | Unavailable; not claimed passed |

The new suite includes 133,107 geometry/transport assertions and 3983 resource
assertions in this run. Some per-resource assertion counts depend on the actual
time-sliced visible workload; their checks still require the same budgets and
geometry properties. Static paused-cloud regressions preserve established valid
IDs across at least two completed frontiers on all qualities. The cubic-motion
production scenario moves the physical field's centroid 866.31 m over 120 seconds,
records internal qc flux 0.00263424 and source-free water drift about −3.87×10⁻¹⁶;
251 retained visible cube centers also move with sampled wind. The liquid fixture
in that manufactured transport test is test input, not production qc painting.

The build and engine version identify a tested implementation candidate. Its
Studio visual release gate remains pending; no angle, mobile or integrated-GPU
appearance/FPS test has been substituted by native tests or an offline image.

## Required Studio review

Open the CLI build and use **Play/F5**. Keep Laptop physics and local MAC detail
off. Confirm Cubes is default, qc forms naturally and coarse voxel geometry is
hidden. The isolated build has no terrain; use a fixed camera if it falls.

| View / action | Inspect and record |
| --- | --- |
| Ground | Real cubic volume, irregular outline, no coarse cell rectangles; screenshot and frame times |
| Side | Equal-axis cubes, layered depth, shallow physical limits and transparency |
| Above | Cube top/side faces, larger upper pieces, no cards or rigid layer seams |
| Close | Positive depth, small lower cubes, overlap/color sorting and creation spikes |
| Inside | Worst transparent fill, comfortable opacity; MicroProfiler capture |
| Orbit / look away and back | Stable seed, culling, LOD hysteresis and bounded resources |
| Wind 8/2 then reverse | Real centroid/region flux direction and attached cubes; m/s-to-stud scale |
| Pause/resume / delayed packets | Timeline holds, stale fade and bounded recovery |
| Add source / regenerate | Existing clouds/time survive additions; reset clears incompatible history |
| Cubes/Voxels/HybridDebug/Off | Only intended representations; qc stays unchanged |
| Two players / late join | Same field/seed/generation/movement, independent quality and current cached data |
| Mobile / Iris Xe / RTX 3050 Ti / stronger PC | Mean/median/p95 frame time, worst spike, object/network/transparency cost per quality |

Example Studio **client** camera:

```lua
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable
camera.CFrame = CFrame.lookAt(Vector3.new(0, 220, 900), Vector3.new(0, 490, 0))
```

Use Y480 for side/inside and Y750 for above; restore `Enum.CameraType.Custom`.
For server numerical commands invoke
`game.ServerScriptService.Weather.WeatherServer.WeatherControls` in the **server**
Command Bar. Cube motion alone does not prove physical transport; inspect field
and region diagnostics.

## Remaining limits

The requested cubic style has faceted silhouettes and approximate illumination.
Continuous reconstruction cannot recover unresolved vortices; six physical levels
stay shallow. Quantization can round tiny liquid to zero, and quality caps can
omit distant detail. Real alpha sorting, overdraw, engine object cost, network
overhead and device FPS require Studio testing. Passing CLI checks/builds does
not imply photorealism or acceptable mobile performance.

The next milestone should use actual Studio results to tune cubic sampling,
transparency, movement cadence and budgets, with atmospheric numerical changes
validated separately. Deeper buoyancy-driven dynamics and volumetric light
transport remain future work.
