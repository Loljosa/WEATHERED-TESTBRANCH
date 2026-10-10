# Laptop performance: 0.2.4-alpha

> Phase 2.5 now starts with multiple world-seeded procedural sources. See
> [the current generation guide](phase2.5-cloud-generation.md) for defaults,
> source budgets and new commands. Primitive-bubble timings and benchmarks below
> remain historical or legacy comparison results; the solver and legacy controls
> are preserved.

The server now defaults to a smaller **Laptop** preset and **1× simulation speed**.
It retains dynamic condensation, three-dimensional winds, conservative bounded
transport, pressure projection and the same fixed 0.25-second physical timestep.
The preview now starts with a stronger **6 K potential-temperature perturbation**,
which reaches visible cloud water sooner while keeping the initial state clear.
This changes the initial bubble; the saturation adjustment equations and requested
step rate remain unchanged.
Debug clouds remain exact 12×12×12-stud cubes, horizontally centered near the
origin and displayed at Y=424–568 studs. This places the domain 354–498 studs
above terrain at Y=70. Raising the display by 400 studs does not change the
physical atmosphere, cloud timing or simulation cost.

The main cost reduction comes from fewer horizontal cells and fewer requested
steps per wall second. The lower-resolution result is a different discretization,
with fewer visible cloud cells; it is not promised to reproduce the Full field.
The optional Full preset retains the previous physical resolution.

## Studio settings

Before starting, select `ServerScriptService.Weather.WeatherServer` and open
**Properties → Attributes**:

| Setting | Laptop default | How to change it |
| --- | --- | --- |
| `PerformancePreset` | `Laptop` | String, either `Laptop` or `Full`; stop and restart the test |
| `SimulationSpeed` | 1 | Number, 0.25–4; editable live in the server view |
| `CellSizeStuds` | 12 | Display spacing and cube size; stop and restart |
| `CloudBottomStuds` | 424 | Display-domain bottom Y; stop and restart |
| `BackgroundU` / `BackgroundV` | 2 / 1 m/s | Physical X/Z wind; stop and restart |
| `BubbleRelativeHumidity` | 0.999 | Dimensionless moist-core humidity; stop and restart |
| `BubbleTemperaturePerturbation` | 6 K | Peak potential-temperature excess in the warm bubble; stop and restart |
| `CloudShape` / `CloudScale` | Round / 1 | Starting warm/moist source shape and radius multiplier; stop and restart |
| `WeatherCommand` | empty | Live commands, e.g. `wind 8 2`, `spawn Wide Fast`, `form 60` |

Start with Laptop and speed 1. If it still disrupts gameplay, try speed **0.5**
without restarting: this halves the requested number of fixed physical steps.
It also doubles the approximate wall time needed for cloud development. Do not
increase speed to 4 on a machine already struggling to keep up. Speed controls
time progression rather than changing condensation equations or physical dt.
No Command Bar or terminal speed command is required.
The [cloud controls guide](cloud-controls.md) covers live movement, shape/size,
formation presets, developed-cloud preview, pause and reset. Form temporarily
requests at least 2x, which costs more CPU; use it for short previews.

For the isolated engine-only Rojo build, choose **Run** to retain the editor
camera; it contains no floor or spawn. In an existing game with a floor and spawn,
use Play or a test server, then switch Studio to its server view to edit a running
Script's attributes. Look near **(0, 460, 0)** and inspect
`Workspace.WEATHERED_DEBUG_VOXELS`; selecting a Part and pressing **F** focuses it.
To change cloud height, stop the test, edit `CloudBottomStuds` on the original
Script and restart; this setting is read once at startup.

The clear Laptop initial state first develops positive qc at **7 simulated
seconds**, and first crosses the debug threshold at **23.75 simulated seconds**.
The previous 2 K bubble took 45.5 simulated seconds to cross this same threshold:
the new onset is about **48% earlier**. At speed 1 the new timing is approximately
7 and 24 wall seconds if the server keeps up; at speed 0.5 it is approximately
14 and 48 seconds. To tune this startup condition, stop the test, edit
`BubbleTemperaturePerturbation` on the original Script and restart. The core
factory keeps its scientific 2 K default. Use 2 K to reproduce the previous
weaker bubble or 6 K for the validated faster preview. No cloud water is seeded.
Render cadence adds up to one second before a newly visible cell is displayed.
Keep the Output window open and compare its `t` with wall time. The model reports dropped backlog if it falls
behind the requested rate.

Studio has not been run in this development environment. The timings below are
native-host Lune measurements, not a measurement of your laptop or Studio FPS.

## Presets and scheduling

| Property | Laptop, default | Full, optional |
| --- | --- | --- |
| Grid, X×Y×Z | 16×12×16 | 24×12×24 |
| Cells | 3,072 | 6,912 |
| Physical Dx/Dy/Dz | 150/100/150 m | 100/100/100 m |
| Physical domain, X/Y/Z | 2,400/1,200/2,400 m | 2,400/1,200/2,400 m |
| Display cell size | 12 studs | 12 studs |
| Display origin | (−96, 424, −96) studs | (−144, 424, −144) studs |
| Display domain, X/Y/Z | 192/144/192 studs | 288/144/288 studs |
| Maximum steps per Heartbeat | 1 | 2 |
| Soft physics budget per Heartbeat | 8 ms | 8 ms |
| Debug render cadence | 1 Hz wall time | 2 Hz wall time |
| Reachable simulation buffers | 58 / 841,932 bytes | 58 / 1,894,092 bytes |

The horizontal cell count and simulation-buffer bytes fall by approximately
**55.55%**. Vertical resolution and physical extents are unchanged. Physical
meters remain separate from Roblox studs; `u=X`, `v=Z`, `w=Y`. The smaller display
box follows the reduced number of 12-stud debug cells. Both presets span
Y=424–568 studs, with vertical cell centers at Y=430–562.

The budget is **soft**: a numerical step is indivisible and may take longer than
8 ms. The controller checks elapsed time before beginning a second catch-up
step; Laptop never begins more than one. This avoids the previous eight-step
catch-up burst during a stall. It does not guarantee an 8 ms frame or eliminate
all single-step pauses. Excess whole-step backlog is discarded, with dropped
physical time reported and the fractional remainder retained. Backlog warnings
are limited to one per five wall seconds.

The server still runs physics on Heartbeat. Spreading one step over multiple
frames or introducing Actor-based execution would require a separate ownership
and scheduling milestone. The public factory/controller defaults remain
24×12×24 and eight catch-up steps for existing callers; the bootstrap explicitly
selects the Laptop grid and the new execution limits.

## Code changes

- `Simulation/PerformanceSettings.lua` owns tested, immutable Laptop/Full settings.
  `WeatherServer.meta.json` exposes Laptop and speed 1 before Play; the bootstrap
  applies the selected grid, budget and render cadence.
- `Transport.lua` caches geometry and reusable-buffer references outside its hot
  passes. `WarmCloud.lua` avoids evaluating Exner again when represented phase
  transfer is exactly zero. These preserve the previous numerical results.
- Ten numerical modules opt into Roblox native compilation with `--!native`
  while retaining `--!strict`. Studio support and performance must be measured
  separately; the Lune loader already enables native compilation, so the native
  directive's gain is not included in the benchmark.
- `VoxelDebugRenderer.lua` retains each visible cell's Part, caches display
  properties and avoids replicated writes when geometry/opacity are unchanged.
  Opacity is quantized to 0.01 for display only. The renderer creates at most
  32 Parts per update, retains its 1,200-Part cap and reuses released Parts.
  Debug Parts remain noncolliding, nonqueryable and shadow-free.
- Controller diagnostics add work duration, step count, selected maximum steps,
  soft budget and whether that budget blocked further work. Numerical validation,
  solver tolerances and field diagnostics are retained.

## Measured costs

`lune run scripts/benchmark-atmosphere.luau` uses production modules and
`PerformanceSettings.Resolve`, alternating the order of the two presets. It runs
eight warm-up steps and 80 timed steps per preset, ending at **22 simulated
seconds**. It now reads the wind, humidity, temperature perturbation and display
height from `WeatherServer.meta.json`, so the current run uses the 6 K bubble.
The metadata and production sources are included in its source fingerprint.

### Current 6 K benchmark

The alternating-order comparison uses the same current startup conditions for
both grids: background wind 2/1 m/s, humidity 0.999 and the 6 K warm bubble.
It measures the first 22 simulated seconds, before the Laptop visibility
threshold; it excludes debug rendering, replication and the rest of the game.

| Metric | Laptop | Full |
| --- | ---: | ---: |
| Mean physical step | 28.880 ms | 70.338 ms |
| Maximum physical step | 58.812 ms | 136.361 ms |
| Mean / maximum PCG iterations | 27.11 / 28 | 37.36 / 39 |
| Estimated physics work at 1× | 115.52 ms/wall second | 281.35 ms/wall second |

For these current 6 K conditions, Laptop uses **58.94% less measured step time**
than Full. Comparing Laptop at 1× with Full at 2× under these same conditions
reduces estimated requested physics work by **79.47%**. This compares current
presets and requested rates; it does not compare the old 2 K cloud trajectory
with the new 6 K trajectory or predict a Studio FPS improvement. The estimate
is `mean_step_ms * SimulationSpeed / 0.25`. Stronger bubble-driven flow can
require more pressure iterations even when grid and timestep are unchanged.

### Historical 2 K benchmark

The paired measurements below are historical results for the previous **2 K**
warm bubble at 0.2.2-alpha. The 6 K startup condition changes the trajectory,
wind and pressure workload, so these numbers do not establish its step cost.
Grid sizes, fixed dt, requested speed and owned-buffer totals are unchanged.

Both recorded presets started clear with the same physical domain, background
wind 2/1 m/s, moist-core humidity 0.999 and a 2 K warm bubble. These timings
describe the first 22 simulated seconds, not a complete cloud lifetime or
renderer cost.

| Metric | Laptop | Full |
| --- | ---: | ---: |
| Mean physical step | 25.130 ms | 61.077 ms |
| Maximum physical step | 43.689 ms | 88.316 ms |
| Mean / maximum PCG iterations | 18.96 / 22 | 25.69 / 30 |
| Estimated physics work at 1× | 100.52 ms/wall second | 244.31 ms/wall second |
| Estimated physics work at 2× | 201.04 ms/wall second | 488.62 ms/wall second |

For that historical pair, Laptop's same-host mean step cost was **58.86% lower**.
Combining that ratio with the speed change from Full at 2× to Laptop at 1×
reduced estimated requested physics work by **79.43%** for that run. This estimate
is `mean_step_ms * SimulationSpeed / 0.25`; it excludes rendering, Studio,
replication and the rest of the game, and does not predict an FPS improvement.
Host timings vary between runs and workloads.

A separate alternating old/new full-resolution comparison isolates the cache and
zero-transfer optimizations: **71.930 → 68.154 ms/step** (5.25% lower), with the
FCT transport stage **25.686 → 22.510 ms** (12.36% lower). Its **2,200 exact
buffer/diagnostic checks** pass. This is an exact-result code comparison; the
Laptop-versus-Full comparison deliberately changes spatial resolution.

The standalone benchmark writes ignored `build/performance-benchmark.json` with
source fingerprint, field checksums, solver metrics and timing. To time only one
preset, append `--laptop` or `--full`. Run it separately from long validation jobs
to reduce CPU contention. Native benchmarks do not exercise Roblox Instances.

## Cloud and numerical checks

The production Laptop regression runs **960 fixed steps**, or **240 simulated
seconds**, from the startup wind, humidity and 6 K warm-bubble conditions.
It checks nonnegative, finite fields, pressure convergence, unchanged hydrostatic
pressure, stable buffer ownership, total-water accounting and visible cloud movement.

| Laptop result at 240 simulated seconds | Measurement |
| --- | ---: |
| First positive qc / first visible cell | 7 / 23.75 simulated seconds |
| Visible cells, `qc >= 0.00005 kg/kg` | 32 |
| Final peak qc | 0.000945690 kg/kg |
| Final unweighted total-water sum drift | −0.00001067% |
| Final pressure residual, RMS / maximum | 2.15×10⁻¹⁰ / 8.00×10⁻¹⁰ s⁻¹ |
| Requested pressure residual target | 1×10⁻⁹ s⁻¹ |
| Final committed-face divergence, RMS / maximum | 6.28×10⁻¹⁰ / 2.78×10⁻⁹ s⁻¹ |
| Maximum PCG iterations over the run | 50 |
| Maximum momentum/scalar Courant number | 0.01400 |

Water drift is an unweighted kg/kg sum under the model's fixed-density
approximation; it is not a density-weighted physical mass measurement. Condensing
and evaporating cloud weights change the qc centroid, so it is not a parcel track.
Between **30 and 240 simulated seconds**, the qc-weighted centroid moves
**(427.14, 388.70, 199.78) physical meters** in X/Y/Z, equivalent to approximately
**(34.17, 46.64, 15.98) display studs** with the Laptop mapping. The focused
240-second validation averaged **34.81 ms/step** on the contended native host,
with a maximum 529.40 ms step. It is not a matched performance comparison with
the earlier 2 K runs and does not measure Studio FPS. The warmer bubble produces
more visible debug Parts and stronger flow, which can require more projection work.
Full retains more spatial detail and more visible cells. A cheaper 12×12×12,
200-meter-horizontal trial was rejected because the useful visible cloud mostly
disappeared by 240 seconds.

Production tests also cover the budget with deterministic clocks, fixed dt,
dropped-time accounting, live speed changes and exact grid/world conversions.
Renderer tests use the production renderer with lightweight Instance substitutes:
33 checks cover reuse, creation limits, changing geometry and zero redundant
writes for an unchanged render. They do not replace Studio graphics profiling.

Run validation and build from the repository root:

```bash
rokit install
npm ci
npx stylua src
npx stylua --check src scripts tests
lune run scripts/test-atmosphere.luau --preview-only
lune run scripts/benchmark-atmosphere.luau
mkdir -p build
rojo build default.project.json -o build/WEATHERED.rbxlx
git diff --check
git status --short --branch
```

The focused `--preview-only` run includes all short mathematics, operator, API,
controller, command/bootstrap and renderer checks plus the **240-second 6 K Laptop scenario**
and the **240-second Wide/Fast wind/reversal case**, with a matched Normal comparison,
passing **886,410 checks**. It writes `build/fast-preview-validation.json` and
`build/laptop-validation.json`, alongside `build/cloud-controls-validation.json`, including source and test fingerprints. Generated reports and place files are
Git-ignored. For only the short checks, use
`lune run scripts/test-atmosphere.luau --quick`, which passes **72,458 checks**.

Running the test script without options still runs all six long scenarios:
scientific baseline, weak wind, strong wind/shear, the legacy 2 K Full-grid
preview, the current 6 K Laptop preview and the command-driven Wide/Fast case.
The earlier 0.2.2-alpha full suite passed **8,166,682 checks** with the previous
2 K preview; its Full-grid results remain historical reference data in
`build/phase2-validation.json`, and are not a claim of rerunning the current source
for those unchanged trajectories.
See [Phase 2 dynamics](phase2-dynamics.md) for the numerical equations, boundaries,
water/energy assumptions and historical full-grid measurements.

Pressure projection and bounded transport remain the main CPU costs. Profile
the Laptop preset in Studio before raising resolution or requested speed. The
next performance milestone should investigate interruptible step scheduling and
the solver using measured Studio data while preserving the validated budgets.
