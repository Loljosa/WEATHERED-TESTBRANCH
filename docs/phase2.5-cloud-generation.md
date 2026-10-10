# Phase 2.5: world-seeded atmospheric cloud sources

Phase 2.5 adds deterministic atmospheric source geometry and bounded ongoing
formation to the existing warm-cloud solver. The new shapes initialize or force
**potential temperature and water vapor**. They never paint cloud water or create
rendered cloud models. The existing microphysics produces `qc`; the existing MAC
winds, pressure projection and conservative transport move the resulting field.

The default development preset remains Laptop. The physical timestep remains
0.25 seconds, and the diagnostic cubes remain 12 studs. This phase does not add
particles, Beams, meshes, volumetric rendering or gameplay integration.

## Ownership and compatibility

Generation is separate from mutable atmospheric state. A source description is
immutable deterministic data: seed-derived ID, world position, extents, base/top,
formation strength, warm/moist targets, noise settings and creation tick.
New descriptions are frozen together with their noise parameter tables. Sampling
that description produces bounded source weights. A source manager caches those
weights/targets, budgets updates, and applies atmospheric forcing. A scheduler
chooses future events from fixed simulation ticks.

The solver retains the Phase 2 numerical sequence:

```text
fixed-tick source work and bounded theta/qv forcing
    -> old-state momentum predictor
    -> MAC pressure projection
    -> conservative bounded scalar transport
    -> saturation adjustment and latent heating
    -> committed state and diagnostic reporting
```

`qc` and `qr` are untouched by injection. Existing winds, hydrostatic pressure,
cloud water and model time survive `spawnseeded`. Explicit regeneration and the
legacy shape/reset commands remain separate operations that replace the model.
The source system adds no per-cell Roblox Instances and no administrative
RemoteEvents. The existing pooled voxel renderer displays the actual `qc` field.

## Files and interfaces

| Module | Responsibility |
| --- | --- |
| `Generation/WorldSeed.lua` | Signed seed validation, canonical/fallback adapter and independent sub-seeds |
| `Generation/SeededNoise.lua` | Reproducible quintic-interpolated 2D/3D value noise and bounded octaves |
| `Generation/CloudHeightmaps.lua` | Independent XZ/XY/YZ shape constraints |
| `Generation/CloudDensityField.lua` | Periodic finite-envelope source weights; no cloud-water generation |
| `Generation/CloudSourceGenerator.lua` | Frozen region/source descriptions and physical-unit validation |
| `server/Simulation/CloudFormationScheduler.lua` | Fixed-tick event opportunities, quiet periods and prepare/commit retry behavior |
| `server/Simulation/CloudSourceManager.lua` | Bounded cached targets, source slots, initialization and ongoing forcing |
| `Simulation.lua` | Atomic theta/qv source application and represented external-input accounting |
| `SimulationController.lua` | Seeded lifecycle, fixed-step source/physics sequencing and movement diagnostics |
| `CloudControls.lua`, `WeatherServer.server.lua`, metadata | Existing server-only commands, canonical seed lookup and startup settings |
| `PerformanceSettings.lua` | Laptop/Full source counts and procedural sample budgets |

The existing momentum, projection, finite-volume transport, saturation adjustment
and pooled diagnostic renderer retain their previous numerical responsibilities.
No gameplay systems are rewritten.

## Canonical world seed

The larger procedural terrain generator is absent from this repository. The
adapter reads the numeric `Workspace.WorldSeed` attribute when supplied; the
weather engine uses development fallback **84219** otherwise. A game world
should set its canonical seed before the weather bootstrap runs. Weather does
not invent a second terrain seed or derive a seed from player position, a clock,
render frames or unseeded `math.random()`.

Accepted seeds are finite signed 32-bit integers, including zero and negative
values. Exact modulo-2^32 hashing uses 16-bit multiplication parts, avoiding loss of
integer precision from directly multiplying two uint32 values in a double. Named
streams and event indices derive signed sub-seeds. Separate deterministic
substreams isolate distribution, source shape and ongoing event generation. The same seed, region, settings and event/step
indices reproduce source descriptions and samples. Mutable atmospheric evolution
is deliberately separate: identical source data alone does not promise bitwise
identical outcomes across different grid resolutions or unrelated runtime
floating-point implementations.

`seed N` selects the seed for the next explicit seeded initialization;
`regenerate` applies it. Existing clouds continue between those commands. The
weather selection does not change the terrain generator's canonical seed.

## Physical region and Roblox display

Atmospheric coordinates use meters. A finite region has an explicit physical
world origin and `Nx*Dx`, `Ny*Dy`, `Nz*Dz` extents. Sampling uses physical cell
centers:

```text
x_world = originX + (ix + 0.5)*Dx
y_world = originY + (iy + 0.5)*Dy
z_world = originZ + (iz + 0.5)*Dz
```

Physical `u` points along X, `v` along Z and `w` along Y. The display retains
`Grid3D`'s independent Roblox-stud origin and cell size. For a local physical
coordinate, its display displacement is `(x/Dx, y/Dy, z/Dz)*CellSizeStuds`.
Changing display height does not alter pressure, sounding height or advection.
The current region origin is `(-1200,0,-1200)` m in both presets; its X/Z center
is the canonical physical world origin. Future region owners must supply explicit
meter origins rather than infer physical positions from display studs.
The sounding still measures thermodynamic height above the model bottom; changing
the physical origin labels world coordinates rather than recomputing a sea-level
atmospheric column. Absolute-altitude environmental sounding is future work.

| Setting | Laptop, default | Full |
| --- | ---: | ---: |
| Grid X/Y/Z | 16/12/16 | 24/12/24 |
| Physical Dx/Dy/Dz | 150/100/150 m | 100/100/100 m |
| Physical extent X/Y/Z | 2400/1200/2400 m | 2400/1200/2400 m |
| Initial sources | 2 | 3 |
| Maximum configurable initial sources | 4 | 6 |
| Source build samples per fixed step | 128 | 192 |
| Display voxel width | 12 studs | 12 studs |
| Display bottom | Y424 studs | Y424 studs |
| Debug update rate | 1 Hz | 2 Hz |
| Catch-up steps per Heartbeat | 1 | 2 |

The display's vertical extent is Y424–568, with cell centers Y430–562. Terrain
at Y70 therefore lies 354–498 studs below the domain. The source generator requires at least five cells per axis. The physical region
is not an infinite world: only its finite active cells are generated and simulated.
The explicit region interface can later select different regions without adding
unbounded work now.

Horizontal physics boundaries remain periodic in X/Z, and the top/bottom have
sealed normal velocity and scalar flux. Source sampling honors that periodic
region. The domain is a repeating coarse atmospheric box, not an open global
weather model, terrain-aware atmosphere or inflow/outflow simulation.

## Three-axis source shaping

A source combines smooth XZ, XY and YZ constraints with coherent 3D noise.
Each map is a deterministic function sampled at coordinates normalized by source
radii; sampled heightmap tables are not allocated. With independently seeded
noise values `nXZ`, `nTop`, `nXY`, `nYZ` in `[-1,1]`:

```text
footprint = 1 + 0.16*nXZ
lower = descriptorBase + (0.11 + 0.07*nXZ)*Ry
upper = descriptorTop  - (0.11 + 0.08*nTop)*Ry
sideWidth = 1 + 0.14*nXY
depth = 1 + 0.14*nYZ
radial = sqrt((dx/sideWidth)^2 + (dz/depth)^2)
         / (footprint*contour)
```

XZ controls the footprint and different irregular lower/upper surfaces. XY
changes the vertical side width; YZ changes the perpendicular depth. A normalized
three-octave coherent value-noise sample gives
`contour = 1 + amplitude*n3D`, with amplitude 0.12, or 0.24 for Broken. Octave
frequencies double and weights are 1, 0.5 and 0.25, divided by their sum. The
lattice interpolation uses quintic fade `6t^5 - 15t^4 + 10t^3`, producing smooth
continuous samples. XZ footprint/base, XY and YZ maps use two octaves; the top
surface uses a separate coarse XZ sample. Seed-derived offsets separate
shape streams. Optional warp is bounded to 0.08 source radii and defaults to zero.

Smoothstep shoulders combine the radial, vertical and unwarped outer envelope.
The final product is in `[0,1]`; it is **source weight**, not cloud-water density
or rendering opacity. Outer support is an ellipse smaller than half the periodic
box, with weights exactly zero outside it. Minimum-image X/Z sampling therefore
has no nonzero-weight seam at its wrapping-coordinate cusp. Source bases/tops
remain within descriptor altitude limits, and first/last layers are protected
from injection. Broad cores and modest edge detail suppress one-cell speckles;
features remain limited by the preset's coarse physical spacing.

Descriptions vary positions, radii, asymmetric surfaces and strength among
Compact, Broad, Broken and Tower families. Horizontal radii are at least two
cells and at most 0.4 of the corresponding domain dimension. Thickness is at
least three vertical cells, within the interior domain. Broken increases contour
variation; it does not guarantee separately detached liquid cells. Noise creates
geometry, while atmospheric evolution determines whether liquid remains connected.

## Atmospheric targets and water accounting

Each cached source supplies a finite potential-temperature target and a finite
total-water target, derived from its bounded weight `s`, environmental sounding
and moisture configuration:

```text
s = geometry_weight*source_intensity*configured_SourceIntensity
theta_target = theta_environment + DeltaTheta*s
q_sat_target = RH_source*qsat(theta_target*Exner(pressure), pressure)
t = min(1, s/0.5)
wetStrength = t*t*(3-2*t)
water_target = min(qv_environment + wetStrength*max(0, q_sat_target-qv_environment),
                   qv_environment + DeltaQv_max*wetStrength)
```

The smooth wet core reaches nearly saturated vapor where `s >= 0.5`, with a
continuous shoulder and vapor capped at saturation for the actual warm target.
This lets a broad wet interior survive coarse-cell advection without painting
liquid or imposing supersaturation. Initial sources combine by positive relaxation
toward these targets. After their
initial theta/qv injection, an explicit time-zero checkpoint defines the initial
water inventory and resets external-input ledgers. Only later ongoing injection
is recorded as external forcing; ongoing events never reset this baseline. Default descriptions vary peak theta excess between
5 and 7 K, intensity between 0.85 and 1, upper vapor increment between 0.018
and 0.022 kg/kg, and target RH 0.9999. These are source parameters, not a
guarantee that every cell receives the maximum increment. Cloud water starts at zero in a newly clear atmosphere.
The source applies positive theta/vapor increments only while its targets and
external budgets allow them. It does not inject wind, pressure, `qc` or `qr`.
Existing liquid contributes to the target's water inventory, so an already moist
cloud is not repeatedly treated as dry air needing fresh vapor.

All values retain physical units:

- `theta`: Kelvin, potential temperature.
- `qv`, `qc`, `qr`: kg water per kg dry air mixing ratios.
- Thermodynamic pressure: absolute Pascals, unchanged by projection.
- Wind: m/s; physical spacing and source extents: meters.
- Scheduler age: fixed ticks or simulated seconds, independent of render cadence.

For active overlapping sources, cached targets merge by maximum rather than
adding their perturbations; support weights merge by maximum as well. Outside
source support no ongoing injection occurs, even if transported air has cooled
below the environmental target. With relaxation `f = dt/8 s` during the default
eight-second event lifetime:

```text
dTheta_requested = f*s_merged*max(0, theta_target-theta)
dQv_requested = f*s_merged*max(0, water_target-(qv+qc+qr))
```

The intended increments are bounded by positive deficits toward target and
remaining cumulative budgets. A first pass sums requested increments; separate
water and theta budget factors `min(1, remainingBudget/requestedSum)` scale all
cells proportionally in a second pass. This avoids favoring early buffer indices
when a lifetime budget runs low. Float32 writes select the lower neighbor when
nearest rounding would exceed **any requested/proportional allowance**, including
exact-budget equality. Actual represented deltas are recorded; residual
remaining-budget checks cover roundoff. Requests below a field's float32 spacing
can produce zero represented addition rather than overspending their allowance. The finite duration does not promise exact target attainment:
repeated relaxation approaches the target gradually. Diagnostics account the **represented float32 increments actually
committed**, rather than the ideal double-precision requests. The water ledger
retains the original unweighted fixed-density interpretation:

```text
WaterSum = sum_cells(qv + qc + qr)
ExpectedWaterSum = InitialWaterSum + ExternalWaterSum
NumericalWaterError = WaterSum - ExpectedWaterSum
WaterDriftFraction = NumericalWaterError/InitialWaterSum
RawWaterChangeFraction = (WaterSum-InitialWaterSum)/InitialWaterSum
dEnthalpy = cp*Exner(pressure)*dTheta_represented + Lv*dQv_represented
```

The raw water change and the source-adjusted numerical error are separate
measurements. A legitimate external source must not disappear into a modified
baseline. `ExternalThetaSum` records summed source theta increases. An
approximate source enthalpy diagnostic records increments in `cp*T + Lv*qv`;
it is a summed specific-energy proxy, not physical domain joules or a claim of
compressible moist-energy conservation.

Constant reference density and uniform volumes make these cell sums useful for
the Boussinesq prototype. They are not density-weighted water mass. Pressure
projection supplies the divergence constraint for the existing conservative
transport; Phase 2.5 does not introduce stratified density continuity. Drag and
viscosity still dissipate momentum without converting that loss into heat;
prescribed pressure, operator splitting and source forcing preclude a global
compressible energy budget.

Cumulative lifetime budgets allow at most 15% of initialized `WaterSum` as
additional water and `3 K*CellCount` as summed source theta increase. These
positive additions are separate from latent heating. Finite sealed-box budgets
deliberately limit sustained weather. Sources can
introduce warm/moist air while budget remains, but they cannot add unbounded
water or heating indefinitely. There is no precipitation sink or open-boundary
ventilation in this phase. Budget exhaustion is reported rather than silently
ignored or hidden as numerical drift.

## Deterministic ongoing formation

Automatic opportunities occur every 180 fixed ticks, or 45 simulated seconds.
A seed-derived draw gives a 0.7 formation probability; the remaining
opportunities are quiet. Manual and automatic source IDs share a bounded
monotonic source event index. Schedule draws use an independent named seed
stream and opportunity counter. The seed and committed opportunity index decide
whether a fixed-tick opportunity forms a source. Pausing stops
simulated event progress. Dropped wall-time backlog does not create missed-time
batches: only committed physical steps advance the scheduler. Quiet periods
allow reduced or absent formation.

Source descriptions are generated outside cell physics. At most two source slots
can be pending, building or actively forcing. A per-step sample budget builds
reusable target buffers incrementally; one cache takes 24 Laptop steps (6
simulated seconds) or 36 Full steps (9 seconds) when it has the full budget. A new
source becomes active only after its bounded construction completes. Several
regions may then force concurrently until their finite duration/targets/budgets
are reached. New sources retain the existing atmosphere and model time.

Turning `autoclouds off` disables new scheduled events; it does not delete cloud
water already in the atmosphere or already accepted sources. Disabled scheduled
opportunities are skipped, not replayed on re-enabling. A full queue skips an
automatic event rather than building an unbounded backlog. Manual `spawnseeded`
uses the next shared source event index and reports acceptance or the bounded
queue limit. Reproducing a run with manual commands therefore requires the same
command order and committed ticks. Explicit reset
or regenerate discards the previous atmosphere and its scheduler state.
`regenerate` starts the selected seeded atmosphere; legacy `reset` returns to
the primitive-source experiment rather than regenerating seeded sources.
Scheduler preparation is idempotent. Source ages, tick/event counters and input
ledgers advance only after a successful physical step. A failed numerical step
can retain already compiled private source geometry, but does not advance the
public physical state or double-count its input on retry.

## Developer controls and Studio test

Build using the Rokit-provided CLI:

```bash
rokit install
npm ci
npx stylua src
npx stylua --check src scripts tests
lune run scripts/test-atmosphere.luau
rojo build default.project.json -o build/WEATHERED.rbxlx
git diff --check
```

Open `build/WEATHERED.rbxlx` in Roblox Studio. The isolated engine place contains
no floor/spawn, so choose **Run**. In the larger game choose Play and switch to
Studio's **server** view. Select
`ServerScriptService.Weather.WeatherServer`, open **Properties → Attributes**,
and keep **Output** visible. Set `WeatherCommand` to a command and press Enter;
it clears for reuse, and `LastWeatherMessage` gives its response.

| Command | Meaning |
| --- | --- |
| `seed 84219` | Select the seed for the next explicit seeded initialization |
| `regenerate` | Intentionally replace the atmosphere using selected seed/settings |
| `spawnseeded` | Queue one additional deterministic warm/moist source without reset |
| `cloudcount 4` | Select initial count within the current preset's validated limit |
| `autoclouds on` / `autoclouds off` | Enable/disable future automatic source scheduling |
| `seedstatus` | Print seed, generation settings, queue, scheduler and source budgets |
| `wind 8 2` | Change live physical X/Z wind to 8/2 m/s; retain existing clouds |
| `speed 0.5` / `speed 1` | Reduce/restore playback; fixed physics dt stays 0.25 s |
| `pause` / `resume` | Hold/continue the atmosphere without accumulating paused backlog |
| `status` | Print numerical, movement, source and dropped-time diagnostics |
| `reset` | Legacy primitive-source reset; intentionally replaces atmosphere and disables its seeded manager |
| `spawn Wide Fast` | Legacy single primitive source experiment; explicitly resets |
| `help` | Show full command list and accepted ranges |

Startup attributes on the stopped `WeatherServer` Script:

| Attribute | Default and interpretation |
| --- | --- |
| `WorldSeed` | 84219 fallback; canonical `Workspace.WorldSeed` takes startup priority |
| `CloudSourceCount` | 0 selects preset default; explicit 1–4 Laptop or 1–6 Full |
| `AutoClouds` | true; enables fixed-tick automatic opportunities |
| `SourceIntensity` | 1; bounded 0–1 multiplier for all initial/ongoing source weights |
| `WorldRegionOriginXMeters` / `YMeters` / `ZMeters` | -1200 / 0 / -1200 physical world meters |
| `BackgroundU` / `BackgroundV` | 2 / 1 physical m/s; existing shear attributes remain available |
| `PerformancePreset` / `SimulationSpeed` | Laptop / 1; playback remains editable live |
| `CellSizeStuds` / `CloudBottomStuds` | 12 / 424 Roblox studs; independent of physical region origin |

`CloudShape`, `CloudScale`, `BubbleRelativeHumidity` and
`BubbleTemperaturePerturbation` configure the retained primitive experiment.
Seeded initialization disables that single bubble. Changing seed/count selects
next initialization values, separately reported by `seedstatus`; it does not
secretly mutate the active seed/count or terrain seed.

The same server-only BindableFunction remains available in Studio's server
Command Bar:

```lua
local controls = game.ServerScriptService.Weather.WeatherServer.WeatherControls
controls:Invoke("seed", 84219)
controls:Invoke("regenerate")
controls:Invoke("spawnseeded")
controls:Invoke("autoclouds", "off")
controls:Invoke("wind", 8, 2)
local diagnostics = controls:Invoke("status")
```

Suggested manual validation:

1. Keep `PerformancePreset=Laptop`, `SimulationSpeed=1`, 12-stud cubes and
   Y424 bottom. Select a numeric canonical `Workspace.WorldSeed` before Run, or
   use the documented fallback. Record `seedstatus`.
2. Run from clear state. Focus near `(0,470,0)` or select a Part in
   `Workspace.WEATHERED_DEBUG_VOXELS` and press **F**. Confirm visible cells only
   appear when `qc` crosses the debug threshold.
3. Record simulation time and cloud cells using `status`. Issue `spawnseeded`.
   Confirm time continues, existing cloud cells remain, and a source is queued
   rather than the entire atmosphere returning to clear time zero.
4. Let automatic events proceed, then turn them off. Confirm existing `qc`
   continues evolving while new scheduled events stop. Inspect external input
   counters, remaining budgets and source-adjusted water error.
5. Set `wind 8 2` and observe over simulated minutes, then reverse the wind.
   Compare centroid/displacement, winds and model time instead of judging a
   single debug frame. Pause/resume and verify scheduler time also pauses.
6. Select `seed 84219`, choose a valid cloud count, and regenerate twice. Compare
   source IDs/positions/settings. Repeat with seed zero and a negative integer,
   then a different seed; the distribution should change.
7. Stop and choose Full only after measuring Laptop. Record Studio MicroProfiler
   physics cost, FPS, visible Part count and dropped simulated time with the
   rest of the game active. The automated CLI tests cannot supply those results.

Live runtime attribute edits are discarded when Studio stops. Change original
startup attributes while stopped to retain defaults. Developer command failures
retain the running atmosphere; numerical failures stop its Heartbeat and require
a restart after addressing the error.

## Movement diagnostics and performance limits

At the Laptop horizontal spacing of 150 m, 2 m/s takes **75 simulated seconds**
to traverse one horizontal cell. Its display speed is only 0.16 studs/s; 8 m/s
maps to 0.64 studs/s. The 1 Hz display occupies fixed grid cubes, so liquid can
move within cells before occupancy/transparency changes become obvious. Wind
is never multiplied solely to make the cubes look animated.

Diagnostics distinguish simulation time, requested playback and dropped time;
face velocity extrema; periodic cloud-water centroid and displacement; cloud
cells and species sums; source counters/budgets; and pressure/CFL results.
Condensation, evaporation, merging and multiple sources change centroid weights.
A qc centroid is not a parcel path, and a horizontally uniform or symmetric cloud
may have no unique circular centroid. `CloudCentroidX/Y/Z` are meters from the
model corner; add the region origin for physical world coordinates. Controller
`CloudCentroidDeltaXMeters/YMeters/ZMeters` and the corresponding `XStuds/YStuds/
ZStuds` fields report changes over `CloudCentroidDeltaSeconds`, with
`CloudMovementDefined` marking valid samples. Repeated status calls at the same
model time reuse that diagnostic interval rather than advancing a motion track. Periodic displacement must be interpreted
with the finite box and sampling interval in mind.

Packed atmospheric buffers, reused solver scratch, bounded source target buffers
and a limited queue prevent per-step growth. Initial generation is startup work;
ongoing construction samples only its configured budget per fixed step. Each
inside-support geometry evaluation uses at most seven single-octave 2D noise samples plus three
3D samples (52 lattice samples), with one optional 3D warp call (eight additional
lattice samples). Early finite-envelope exits skip these evaluations entirely. Neither
preset increases grid resolution. Debug rendering retains its 1200-Part pool cap
and 32 new Parts per update. Laptop's one-step Heartbeat and soft 8 ms catch-up
budget remain: an indivisible numerical step can still exceed 8 ms.

Native Lune timings exclude Roblox debug rendering, replication, the rest of the
game and Studio overhead. They must be measured against matching Phase 2 and
Phase 2.5 presets, separating procedural generation/setup cost from physical
step cost. `scripts/benchmark-seeded-clouds.luau` compares frozen Phase 2, current
legacy conditions and current seeded conditions in alternating order; it checks
that the legacy trajectory is byte-identical before interpreting timings. The
seeded comparison changes initial physics, so its cost includes changed pressure
work rather than isolating the generator alone. The paired run uses 2/3 initial
Laptop/Full sources, eight warm-up steps and 232 measured steps, ending at 60
simulated seconds. It queues a manual source at 29.75 seconds and includes later
automatic opportunities. `CoreStep` includes the full `Simulation:Step`, including
source forcing; `SourceScheduler` includes description, noise-cache construction,
target merging and manager commit; `Combined` includes both. Renderer and other
game work remain excluded. Passing tests and Rojo build do not establish acceptable laptop FPS.

For a reproducible paired benchmark, freeze the pre-Phase-2.5 commit without
changing branches or the working checkout:

```bash
mkdir -p build/phase2-frozen
git archive 5beaa64ac567dd7e73ceec2e503688474ba37d41 | tar -x -C build/phase2-frozen
lune run scripts/benchmark-seeded-clouds.luau --baseline build/phase2-frozen
```

The frozen snapshot is ignored build data, not a new branch. Run timing while
other numerical suites are idle. The focused seeded runner is
`lune run scripts/test-seeded-clouds.luau`, or append `--quick` for compact
smoke evolution. The main `test-atmosphere` runner includes the same checks.

## Validation records

The default Laptop seed 84219 starts with `qc=0` and maximum initial RH
0.999900863, below saturation. Its maximum initial theta excess is 6.52243 K.
Production-module onset measurements in `build/phase25-onset.json` give:

| Physical wind U/V | First positive qc | First visible cell (`qc >= 0.00005 kg/kg`) |
| --- | ---: | ---: |
| 2/1 m/s | 0.25 s | 11.50 s |
| 8/2 m/s | 0.25 s | 13.75 s |

The first tiny liquid appears during the first real transport/phase step; it is
not initialized as visible cloud. At 1× the onset approaches wall seconds only
when the server keeps up, with up to one extra second of debug display delay.
Other seeds, counts and intensity settings have different onset times.

The focused deterministic geometry suite passes **28,605 checks** against real
production modules through `RobloxModuleLoader`. Coverage includes signed
zero/negative seeds, independent arbitrary-precision reference hash vectors,
all four source families, independent plane dimensions, smooth zero/nonzero
boundaries, both periodic seams, bounded warped weights, invalid coordinates
and six-neighbor connectivity with no isolated cells above source weight 0.01.
A separate scratch stress sampled 629,760 Laptop cells across 205 sources, seeds
-20 through 20, and maximum warp 0.08, finding zero isolated above-threshold cells.
These geometry checks do not claim that physics can never fragment liquid.

Evolution checks run production source manager, MAC momentum/projection,
conservative transport and microphysics. They verify clear initial liquid,
repeated deterministic trajectories, nonreset queueing/injection, preservation
of old cloud-water bytes during injection, measured external inputs, budget
equality/proportionality, failed-step rollback/retry, bounded work/storage and
finite long-run fields. Motion is measured from the liquid field under configured
wind. A controlled drying fixture passes naturally generated liquid into the
production warm-cloud evaporation function and checks parcel-water preservation.
It demonstrates evaporation in unfavorable air, rather than proving a complete
self-sustaining storm lifecycle or Studio-visible merging of named clouds.
Final production-module validation passed:

| Run | Result | Scope |
| --- | ---: | --- |
| `test-seeded-clouds.luau` | 55,217 checks | All new geometry, scheduler, controls and full seeded evolution checks |
| `test-atmosphere.luau --quick` | 110,822 checks | Existing numerical/renderer/controller checks plus seeded smoke evolution |
| Earlier `test-atmosphere.luau` | 8,240,822 checks | Full legacy matrix and seeded evolution, before the final source-rounding correction |

The final correction prevents nearest float32 rounding from exceeding an exact
source-input allowance. The focused full run and main quick run were repeated
after it, including new equality and near-equality budget regressions. The earlier
main full run is retained as `build/phase25-full-pre-rounding-fix.log` and is not
presented as an exact-final-source rerun. Final focused evidence is in
`build/phase25-final-seeded-tests.log` and `build/phase25-evolution.json`; the
main quick log is `build/phase25-final-quick-tests.log`. Reports record source
fingerprints so a passing result can be matched to its tested implementation.

The final seeded trajectories use seed 84219, wind U/V=8/2 m/s, automatic
opportunities and one manual queued source without resetting the model. Laptop
runs 960 steps; Full runs 160 steps and is a smoke run rather than a 240-second
Full validation. They start with no cloud water:

| Measurement | Laptop, 240 s | Full, 40 s |
| --- | ---: | ---: |
| First visible liquid cell | 13.75 s | 12.75 s |
| Final cells above debug threshold | 9 | 89 |
| External vapor, unweighted summed kg/kg | 1.26519267 | 0.792967101 |
| Raw total-water increase | +2.98070241% | +0.817471733% |
| External-input-corrected water drift | +0.00000294685% | -0.000000894413% |
| Maximum projection residual RMS | 3.06930e-10 s^-1 | 2.55455e-10 s^-1 |
| Maximum cell divergence after projection | 8.09630e-9 s^-1 | 1.19209e-8 s^-1 |
| Maximum reported Courant number | 0.0255463 | 0.0350115 |
| Maximum source samples in a step | 128 | 192 |
| Owned packed-buffer count / bytes | 67 / 952,524 | 67 / 2,142,924 |

Source storage accounts for nine reusable float32 buffers: 110,592 additional
bytes for Laptop and 248,832 for Full. Owned storage remains unchanged throughout
these runs. No new renderer objects are created by source generation.

Laptop's periodic liquid centroid changes by +262.786 m in X and +46.840 m in Z
between 30 and 60 simulated seconds, before ongoing source input begins. Full's
30-to-40-second centroid changes by +71.726 m in X and +19.156 m in Z during a
queued formation event. Both measurements come from the liquid field under real
transport; growth, ongoing formation and evaporation also affect their values.
They do not identify individual cloud
trajectories or prove Studio-visible motion.

The isolated paired benchmark passed byte-identical legacy trajectory checks for
both presets. It compares frozen commit
`5beaa64ac567dd7e73ceec2e503688474ba37d41` with the final production source and
records its evidence in `build/phase25-benchmark.json` and `.log`:

| Native timing, ms/step | Laptop | Full |
| --- | ---: | ---: |
| Frozen Phase 2 combined mean | 35.358 | 89.614 |
| Current legacy combined mean | 36.151 | 86.879 |
| Current seeded combined mean | 37.282 | 91.972 |
| Current seeded combined median | 34.276 | 87.375 |
| Current seeded combined p95 | 54.066 | 127.980 |
| Seeded versus frozen mean difference | +5.443% | +2.631% |
| Seeded scheduler/cache mean | 0.377 | 0.310 |
| Initial source/noise setup | 24.033 | 96.003 |
| Maximum scheduler/cache observation | 52.207 | 11.453 |

The legacy runs use identical initial conditions, including 6 K, RH 0.999,
Round and wind 8/2 m/s, and end with identical physical-state bytes. Their mean
timings differ by +2.244% Laptop and -3.052% Full despite that identical work;
these are single-host observations, not a statistically established regression
bound. Seeded conditions have different spatial perturbations and pressure work,
so the seeded comparison includes the changed physical scenario. It does not
isolate generator overhead or prove solver acceleration.

Ongoing source work is bounded by sample counts, but that does not impose a
hard wall-time cap. The observed 52.207 ms Laptop scheduler/cache outlier is
unattributed; runtime/host overhead is included in that measurement. Numerical
steps also exceed the soft 8 ms controller budget on this host. Native
measurements exclude diagnostic sampling, Parts, replication, Studio and other
game systems, and do not promise acceptable FPS on the user's laptop. Roblox
gains from `--!native` directives were not measured.

Historical Phase 2 measurements remain in
[phase2-dynamics.md](phase2-dynamics.md), [laptop-performance.md](laptop-performance.md)
and [cloud-controls.md](cloud-controls.md); they must not be presented as new
Phase 2.5 results. Studio was unavailable for this validation.

## Remaining limits and next milestone

This is a finite, repeating coarse atmosphere with deliberately bounded forcing.
It does not provide infinite-world chunks, terrain interaction, a hydrological
cycle, rain fallout, surface energy exchange or real-world weather prediction.
Noise influences source geometry; it does not prescribe permanent liquid shape.
The early-onset diagnostics and native benchmarks cannot establish how the debug
clouds look or how smoothly they appear to move in Roblox Studio.
Natural liquid motion, merging and dissipation depend on thermodynamic conditions
and resolved winds. The first-order split model and grid still lose small-scale
features through numerical diffusion.

The next numerical milestone should establish a balanced surface/precipitation
water and energy budget, profiling in the larger Studio game before expanding
domains or adding final cloud rendering. Final particles and volumetrics remain
a separate task.
