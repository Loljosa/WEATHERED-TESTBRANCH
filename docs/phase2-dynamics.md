# Phase 2: three-dimensional atmospheric dynamics

Phase 2 combines staggered winds, a pressure projection and conservative scalar
transport. This revision improves scalar accuracy, pressure-solver cost,
float32 phase conversion and failed-step isolation. The current 0.2.2-alpha
bootstrap adds a Laptop preset and bounded frame work. Cloud water still comes
from condensation of an initially clear warm/moist perturbation.

The Studio bootstrap uses a compact preview above normal terrain. Its debug Parts represent
the atmospheric field and have no collision or gameplay role. No inventory,
movement, world generation, existing rain or final rendering system is changed.

## Studio preview and controls

The built place supplies attributes on
`ServerScriptService.Weather.WeatherServer`. Set them in **Properties → Attributes**
before starting the test:

| Attribute | Default | Meaning |
| --- | --- | --- |
| `PerformancePreset` | `Laptop` | Startup-only String: `Laptop` or `Full`, selecting grid and execution settings |
| `CellSizeStuds` | 12 | Display spacing and exact debug Part width/height/depth, Roblox studs |
| `CloudBottomStuds` | 424 | Bottom of the display domain, workspace Y studs |
| `BackgroundU` | 2 | Background wind along X, physical m/s |
| `BackgroundV` | 1 | Background wind along Z, physical m/s |
| `ShearU` | 0 | Change in U per physical meter of height, `(m/s)/m` |
| `ShearV` | 0 | Change in V per physical meter of height, `(m/s)/m` |
| `BubbleRelativeHumidity` | 0.999 | Relative humidity of the warm/moist core, dimensionless |
| `SimulationSpeed` | 1 | Requested simulated seconds per wall second |

All values except `SimulationSpeed` are read once at startup. Stop the test, change
the original Script's attributes and restart to change initial conditions.
The core factory retains its scientific defaults: zero wind and perturbation
relative humidity 0.98. The preview's wetter core and 2/1 m/s wind are explicit
bootstrap settings.

`SimulationSpeed` can also change during a test, between **0.25 and 4**. In Play,
switch Studio to its server view; select the running Script and edit that Number
attribute in Properties. For example, 1 runs at normal model time, 2 requests
twice as many fixed steps, and 0.5 slows the model. Invalid live edits warn and
retain the previous valid value. Editing the running copy lasts for that test
session; set the original Script before starting for a saved preset. No terminal or
Command Bar speed command is needed.

Speed changes step count, never the **0.25-second** physical timestep. The default
Laptop preset permits at most **one step per Heartbeat**; Full permits at most two.
Both apply a soft **8 ms** physics budget between steps. A physical step cannot be
interrupted, so its duration may exceed the budget. Excess whole-step backlog is
dropped and reported as physical simulation time, retaining the fractional
remainder. Debug rendering runs at **1 Hz in Laptop**, **2 Hz in Full**, and
diagnostics print every ten wall seconds independently of simulation speed.
The controller API default remains eight steps for existing callers that do
not supply execution options. See [Laptop performance](laptop-performance.md)
for measured costs and the limitations of this scheduling budget.

### Exact Studio test

Studio has not been run in this development environment.

1. Open `build/WEATHERED.rbxlx` in Studio, or connect the **Studio Rojo plugin** to
   the existing CLI sync server. Remote Studio must reach the Codespace's Rojo
   port. The VS Code Rojo extension is unnecessary.
2. Confirm Core face/geometry and Dynamics modules appear under
   `ReplicatedStorage.Shared.Atmosphere`. Disable any separately installed old
   voxel bootstrap so only one atmosphere engine runs.
3. Check the attributes above in Properties and open **View → Output**. For the
   isolated build, use **Run** from the Test toolbar: server scripts execute
   without an avatar, and the editor camera remains available. This engine-only
   place has no floor or SpawnLocation. Use **Play** or a test server with one
   player when syncing into an existing game place with a floor and spawn.
   Startup should identify **0.2.2-alpha**. The atmosphere starts cloud-free.
4. Look near workspace **(0, 460, 0)** and watch
   `Workspace.WEATHERED_DEBUG_VOXELS`. Thin cloud cells should appear above the
   center and move in positive X and Z. Select a Part and press **F** to focus it
   if needed. Each default debug Part is exactly **12 × 12 × 12 studs**.
5. Compare the diagnostics' **simulation time** with measured cloud timing below.
   The debug threshold is `qc >= 0.00005 kg/kg`. Wall time depends on speed and
   whether the server can keep up. The Laptop preset first reaches this threshold
   at **45.5 simulated seconds**, about 46 wall seconds at 1× if the server keeps up.
6. Select the running Script (switch to server view in Play), and change its
   `SimulationSpeed` from 1 to 0.5. Confirm the speed diagnostic changes,
   physical dt stays 0.25 s, and
   cloud evolution slows while debug cadence remains unchanged.
   Catch-up warnings mean model time has fallen behind the requested rate.
7. Continue through **240 simulated seconds**. Check finite wind, small divergence
   of committed faces, nonnegative water, nearly constant water inventory and no
   stopped-atmosphere, solver or CFL errors. Parts should be reused and stay
   within the 1,200-Part cap. Stop and replay for a fresh clear state.

This remains a small voxel diagnostic; cloud particles and volumetric rendering
are separate future work.

## Coordinates and state

Both preview presets cover **2,400 × 1,200 × 2,400 physical meters**. The default
Laptop preset is **16 × 12 × 16**, or 3,072 cells, with **Dx = Dz = 150 m** and
**Dy = 100 m**. Its 12-stud display starts at `Vector3.new(-96, 424, -96)`, forming a
192 × 144 × 192-stud box. Full retains **24 × 12 × 24**, 6,912 cells with
**Dx = Dy = Dz = 100 m**, origin `Vector3.new(-144, 424, -144)` and a
288 × 144 × 288-stud box. The public core/controller default grid remains Full;
the server bootstrap selects Laptop explicitly. Physical height starts at the
model bottom, independently of workspace Y. Both display domains span Y=424–568
studs, with cell centers at Y=430–562: 354–498 studs above terrain at Y=70.
The 400-stud display-height increase leaves physical spacing, buoyancy,
condensation timing, transport and the performance preset unchanged.

| Quantity | Location / axis | Units |
| --- | --- | --- |
| `u`, face `U` | X | m/s |
| `v`, face `V` | Z | m/s |
| `w`, face `W` | Y, vertical | m/s |
| `theta`, temperature | Cell centers | K |
| `qv`, `qc`, `qr` | Cell centers | kg water / kg dry air |
| State `pressure` | Cell centers | Absolute hydrostatic Pa |
| Projection `phi` | Cell centers | Kinematic pressure, m²/s² |

Default preview conversion is:

```text
worldX =  -96 + physicalX*(12/150)
worldY =  424 + physicalY*(12/100)
worldZ =  -96 + physicalZ*(12/150)
```

These are display conversions, not a prescription of Roblox object velocity.
`Grid.Dx/Dy/Dz` own physical spacing; `Atmosphere.CellHeightMeters = 100` is a
legacy default and does not override an existing grid's `Dy`.

X/Z boundaries are periodic. Top/bottom Y faces have exactly zero normal wind
and scalar flux; tangential momentum uses zero-gradient Y ghosts. These are
periodic horizontal boundaries and sealed walls, not open inflow/outflow or terrain.

The MAC layout stores authoritative float32 face winds. U/V each contain `N`
unique periodic faces; W contains `N + NX*NZ`, including both walls. For
zero-based cell index `i`, negative faces are `U[i]`, `V[i]`, `W[i]`; positive
faces are `U[Xp[i]]`, `V[Zp[i]]`, `W[i + NX*NZ]`. Adjacent cells share one stored
face, including periodic seams.

The original eight packed float32 cell fields remain. Cell `u/v/w` average the
surrounding projected faces; changing them alone does not force the next step's
wind. Consumers may retain State/Faces objects but must reacquire individual
scalar and U/V/W buffers after stepping because reusable buffers swap ownership.

## Step ownership and failure behavior

`Atmosphere.new(grid, config?)` owns one simulation. Configuration includes
wind/shear, `BubbleRelativeHumidity`, `MomentumOptions`, `ProjectionOptions` and
`TransportOptions`. `TransportOptions.Scheme` selects `FCT` or `Upwind`; the
Studio bootstrap uses the FCT default. The controller
initializes once; later initialization calls return the existing simulation.
Geometry, candidate storage, fluxes and solver work vectors are allocated once.

Each step validates committed inputs, copies them into reusable candidate storage,
predicts momentum, projects candidate faces, transports theta/qv/qc/qr, applies
coupled float32 phase conversion, reconstructs cell wind, and validates the
complete candidate before committing buffers and advancing time.

A failed `Simulation:Step()` leaves committed field/face bytes, their buffer
references, model time and last-successful diagnostics unchanged. The pressure
warm start and diagnostics are restored; private scratch may contain failed
work. The bootstrap stops Heartbeat on failure and requires a restart.
A standalone `Projection:Project()` preserves input faces on failure but marks
its own convergence diagnostic false.

Diagnostics include separate species sums and water drift, face-wind ranges,
pre/post-projection divergence, residuals/tolerances/iterations, momentum
stability and scalar Courant numbers, last step duration and qc centroid.
The controller adds speed and dropped time. X/Z centroids use circular means;
`CloudCentroidDefined` is false without cloud or a unique circular direction.
A qc-weighted centroid is not a material parcel trajectory.

## Momentum and pressure

For face wind `a = (u,w,v)` in spatial `(X,Y,Z)` order:

```text
da/dt = -(a · grad)a + nu*laplacian(a) + B*eY - (a-a_env)/tau
nu = 10 m²/s
tau = 30 s
theta_v = theta*(1 + 0.61*qv - qc - qr)
B = g*(theta_v/theta_v_env - 1)
```

Momentum uses material-form first-order upwind advection, cross-component
interpolation and explicit seven-point viscosity. All components read old faces.
Cell buoyancies average onto interior W faces. Analytical drag follows the
explicit update:

```text
U_star = U_env + (U_explicit-U_env)*exp(-dt/tau)
V_star = V_env + (V_explicit-V_env)*exp(-dt/tau)
W_star = W_explicit*exp(-dt/tau) + B_face*tau*(1-exp(-dt/tau))
U_env(h) = BackgroundU + ShearU*h
V_env(h) = BackgroundV + ShearV*h
h = (y-0.5)*Dy
```

For matching cell divergence `D` and face gradient `G`:

```text
D G phi = D(a_star)/dt
a_new = a_star - dt*G(phi)
D(a) = (U_right-U_left)/Dx
     + (W_top-W_bottom)/Dy
     + (V_front-V_back)/Dz
```

Matrix-free Jacobi-preconditioned conjugate gradients solve the positive
semidefinite operator `-D G`, with periodic X/Z and Neumann Y pressure boundaries.
Float64 pressure/work vectors, a safe warm start and zero-mean pressure gauge
remain. RHS compatibility is checked before removing only roundoff mean
divergence. Structured operator and fused passes retain actual-residual checks.

Defaults are 200 iterations and:

```text
target = max(1e-9 s^-1, 1e-7*RMS(divergence_before))
```

Both RMS and maximum actual equation residual, expressed as divergence by
multiplying by dt, must satisfy the target. Corrected float32 faces are staged
and checked before commit. Effective post-tolerance combines the requested
target, derived IEEE float32 face-rounding allowance, reported float64 arithmetic
bound and RHS compatibility mean. Subnormal spacing is included; the old fixed
5e-8 s^-1 floor is removed. Solver residual and committed-face divergence are
separate measurements.

Projection `phi` is kinematic pressure perturbation divided by constant reference
density, not absolute Pa pressure. Projection never overwrites hydrostatic
thermodynamic pressure. This is a constant-density Boussinesq approximation,
not a compressible CM1 port.

## Bounded conservative scalar transport

Default **FCT** uses MC-MUSCL reconstruction, bounded paired flux correction and
SSPRK2. An explicit **Upwind** scheme remains as the first-order reference.
For scalar `s`, low-order flux is `F_low = a_normal*s_upwind`; MC slopes use
left/right differences:

```text
slope = minmod(2*d_left, (d_left+d_right)/2, 2*d_right)
F_high = a_normal*s_reconstructed_upwind
F = F_low + alpha_face*(F_high-F_low)
0 <= alpha_face <= 1
s_new = s_old - dt*D(F)
```

Minmod returns zero for opposing signs and the smallest signed magnitude
otherwise. The limiter bounds each cell's permitted correction from the
low-order result, then uses one shared-face coefficient satisfying both cells.
It changes paired fluxes rather than independently clipping cells and losing
water. Its local bounds include the low-order result as well as old neighboring
values, so a standalone divergent flow is allowed to compress scalars rather
than having that compression silently removed. Initial-bound preservation
requires sufficiently divergence-free winds. Writing a bounded forward-Euler
stage as `E`, SSPRK2 uses:

```text
s_stage = E(s_old)
s_new = 0.5*s_old + 0.5*E(s_stage)
```

Projected winds stay fixed during scalar transport. Reusable float64 flux/stage
arithmetic feeds float32 committed fields. Exactly zero fields can skip transport;
small positive values are not discarded by a cutoff. Smooth advection gains
accuracy; limiters reduce order around sharp extrema. The complete coupled
momentum/projection/transport/phase sequence remains **first order in time**.

Uniform volumes and constant reference density make unweighted scalar sums
proportional to model inventories. Shared-face fluxes enter neighboring cells
with opposite signs, conserving theta/qv/qc/qr sums up to storage roundoff.
That cancellation also conserves the stored concentration integral in a
standalone divergent-flow test, but a spatially constant scalar can change by
`-dt*s*D(a)`. Such a flow would require density continuity to interpret the
stored quantity as a dry-air mixing ratio. The Boussinesq projection supplies
the divergence constraint for this model's fixed-reference-density inventory.
Phase conversion changes separate qv/qc sums but approximately conserves
`qv+qc`; `qv+qc+qr` is the water diagnostic. A raw kg/kg sum is not kilograms
or a variable-density atmospheric mass budget.

## Coupled float32 warm-cloud conversion

The thermodynamic modules retain the hydrostatic sounding, theta conversion
and Bolton liquid-water saturation from the
[Phase 1 reference](dynamic-cloud.md#equations-and-units).
`WarmCloud.Adjust` retains the double precision saturation solve. At fixed pressure,
an attainable saturated state satisfies:

```text
T = theta*(p/p0)^(Rd/cp)
qv_new = qsat(T_new,p)
T_new = T_old + (Lv/cp)*delta
qv_new = qv_old-delta
qc_new = qc_old+delta
```

Condensation cannot consume more available vapor; evaporation cannot consume
more existing liquid. When liquid runs out, the result may remain unsaturated.

Production uses `WarmCloud.AdjustFloat32` and a caller-owned rounding buffer.
It rounds target vapor first, then uses the same represented transfer for liquid
and heating:

```text
qv_stored = round32(target_vapor)
delta_stored = qv_old-qv_stored
qc_stored = round32(qc_old+delta_stored)
theta_stored = round32(theta_old + (Lv/cp/Exner(p))*delta_stored)
```

If rounded vapor would exceed available qv+qc after evaporation, the next lower
representable vapor value is selected, avoiding negative liquid. If target vapor
rounds back to existing qv, represented transfer is zero: no liquid or latent
heat is added. Remaining phase-water error comes from qc rounding, ordinarily
at most half its final ULP; theta has its own rounding error. No broad saturation
tolerance suppresses physically resolvable changes.

Complete evaporation can retain sub-vapor-ULP qc when total water cannot fit in
one float32 vapor value. This preserves represented water instead of inventing
vapor or forcing qc to zero. Local approximate `cp*T + Lv*qv` conservation is
not a global moist-energy budget. `qr` is transported and contributes liquid
loading, but starts zero and has no conversion/fallout process.

## Numerical limits

Each scalar stage requires:

```text
C_out = dt*[ (max(U_right,0)+max(-U_left,0))/Dx
           + (max(W_top,0)+max(-W_bottom,0))/Dy
           + (max(V_front,0)+max(-V_back,0))/Dz ] <= 0.8
```

Momentum separately requires:

```text
dt*[abs(aX)/Dx + abs(aY)/Dy + abs(aZ)/Dz
    + 2*nu*(Dx^-2+Dy^-2+Dz^-2)] <= 0.8
```

Invalid timesteps, nonfinite fields, negative water, unsupported thermodynamic
states and failed stability/projection conditions are errors. Excess wind is not
silently clipped. Bounds/conservation retain roundoff and residual-divergence
limits, measured in tests.

There is no compressibility, stratified-density continuity, acoustics, terrain,
surface forcing, precipitation, ice, resolved turbulence or storm lifecycle.
Fixed pressure and buoyancy profiles are low-order approximations. Momentum is
not conservative-form transport. Drag/viscosity dissipate kinetic energy without
returning it as heat; prescribed pressure and split latent heating do not conserve
global compressible moist energy. The bubble has no continual heating or water
supply.

## Validation and measurements

The CLI is used for build, formatting and mathematical validation:

```bash
rokit install
npm ci
npx stylua src
npx stylua --check src scripts tests
mkdir -p build
set -o pipefail
lune run scripts/test-atmosphere.luau | tee build/phase2-validation.log
rojo build default.project.json -o build/WEATHERED.rbxlx
git diff --check
git status --short --branch
```

The production-module loader runs core/buffer checks, manufactured projection,
scalar accuracy/conservation/bounds, stationary coupled phase checks,
transactional failures and controller speed/fixed-step tests. Full scenarios
cover scientific defaults, prior weak wind, strong wind/shear and both Studio
presets. Renderer and execution-budget tests use the actual server modules.
Reports are written to ignored `build/phase2-validation.json` and logged stdout.

The shorter `lune run scripts/test-atmosphere.luau --quick` suite includes all six
advection directions, scalar species budgets/bounds, three failed-step
rollback/retry stages, live speed/display configuration and laptop execution
controls. Current laptop results and reproducible benchmark instructions are
recorded in [Laptop performance](laptop-performance.md). The current full suite
passes **8,166,682 checks** across five 240-second scenarios; quick validation
passes **56,409 checks**. `build/phase2-validation.json` contains the four Full-grid
scenarios and `build/laptop-validation.json` contains the Laptop scenario.

### Full-grid rework measurements at 1d550d3

The measurements below were recorded before the laptop optimization, on the
24×12×24 grid. They remain reference data for the same numerical model; they are
not the current default Laptop cloud timing or a matched laptop speed comparison.

For a periodic sine transported at U=4 m/s over 50 s in a 1,000 m domain,
with Courant number 0.2, scalar RMS errors are:

| X cells | FCT error (kg/kg) | Upwind error (kg/kg) |
| --- | --- | --- |
| 16 | 0.000124375 | 0.000634975 |
| 32 | 0.0000383587 | 0.000332491 |
| 64 | 0.0000112598 | 0.000170264 |

FCT refinement ratios are 0.3084 and 0.2935 for this smooth case. This measures
scalar accuracy, not the order of the complete split atmosphere. A stationary
float32 saturation test over 10,000 phase adjustments preserves represented
qv+qc exactly and leaves qc zero in the tested equilibrium.

The rework full suite passed **7,346,306 checks**. Each of its four production scenarios
executes 960 fixed steps, covering **240 simulated seconds**. The following cloud
peaks and first visible samples use diagnostics every ten simulated seconds;
visible cells satisfy `qc >= 0.00005 kg/kg`.

| Configuration | Sampled peak qc (kg/kg) | First visible sample | Visible cells at 240 s | Final water drift |
| --- | --- | --- | --- | --- |
| Scientific default, zero wind, core RH 0.98 | 0.000360650 | 90 s | 44 | +0.00001129% |
| U=0.5/V=0.25 m/s, core RH 0.98 | 0.000360112 | 90 s | 43 | −0.00003744% |
| U=8/V=4 m/s, shear 0.002/−0.001 `(m/s)/m`, core RH 0.98 | 0.0000499268 | No visible sample | 0 | −0.00001053% |
| Studio preview, U=2/V=1 m/s, core RH 0.999 | 0.000412259 | 40 s | 33 | −0.00006274% |

All scenarios retain finite fields, nonnegative water and unchanged hydrostatic
pressure. Their sampled maximum committed-face divergence is respectively
**1.49e-9, 1.51e-9, 1.30e-8 and 3.72e-9 s^-1**, within each reported float32
post-tolerance. Maximum PCG iterations are 54 in every scenario; the largest
momentum/scalar Courant number over all steps is **0.03490**, below the 0.8 limit.
The stress case develops cloud water just below the display threshold in the
sampled diagnostics; its absence of visible voxels is not a solver failure.

The preview additionally checks qc after every 0.25-second step. Its first
positive cloud water is at **10.25 simulated seconds**, and its first cell reaches
the display threshold at **39.25 seconds**. At that revision's requested `SimulationSpeed=2`,
these correspond to about 5.13 and 19.63 wall seconds if the server keeps up.
At 240 seconds, it has 33 visible cells and a peak qc of 0.000412259 kg/kg.
From the 40-second sample to 240 seconds, its qc-weighted centroid moves
**(405.32, 150.98, 207.45) physical meters** in (X,Y,Z), or
**(48.64, 18.12, 24.89) display studs**. Its final display centroid is approximately
**(56.61, 79.34, 28.41) studs** with that revision's 12-stud spacing and historical
display origin `Vector3.new(-144, 24, -144)`. This recorded absolute display
position predates the current 400-stud height increase; physical measurements
and centroid displacements are unchanged.
Condensation and evaporation change the centroid weights, so this displacement
does not measure a single parcel's travel.

All these recorded final water drifts are below 0.0001% in magnitude, compared with the
historical vertical-only Phase 1 result of **−0.19963%** over 240 seconds.
This does not establish a reduction in every conservative Phase 2 scenario:
the default's absolute drift increases from 0.00000934% at f774c51 to
0.00001129%, and the stress case increases from 0.00000954% to 0.00001053%;
the weak-wind case decreases from 0.00005183% to 0.00003744%.

Compilation and native Lune execution do not replace Studio runtime testing or
Roblox-aware static type analysis. Numerical cloud centroids are field
measurements, not verified Studio screenshots.

## Performance

Dynamics retain packed buffers and reusable storage, without per-cell tables,
Vector3 construction or Instance lookups. Laptop owns **58 unique buffers totaling
841,932 bytes**; Full owns 58 totaling **1,894,092 bytes**. These are reachable
simulation buffers, excluding Lua tables, debug Parts, cached renderer properties
and replication. Neither preset changes the solver tolerances, fixed timestep,
transport scheme or transactional validation. Current cost measurements and
renderer/native-code changes are documented in [Laptop performance](laptop-performance.md).

### Historical full-grid timing at 1d550d3

Transactional storage and FCT added buffers/passes; pressure optimization reduced
other work. The historical first-order Phase 2 simulation owned 39 buffers
totaling 1,255,872 bytes.

An alternating-order comparison on **120 identical 24×12×24 production pressure
inputs**, with unchanged strict tolerances, measured **57.605 → 40.230 ms/call**
(about **30.2% less time**). Both versions averaged 21.458 PCG iterations, maximum
54, and produced exactly identical accepted float32 face bytes in all calls.
This isolates pressure cost; it is not a whole-simulation speedup or Studio
benchmark.

The complete native Lune run at 1d550d3 on this contended host measured:

| Scenario | Mean step (ms) | Maximum step (ms) | 960-step scenario runtime (s) |
| --- | --- | --- | --- |
| Scientific default | 132.054 | 5,141.436 | 127.34 |
| Weak wind | 154.169 | 1,271.763 | 148.69 |
| Wind 8/4 stress | 112.472 | 1,393.718 | 108.40 |
| Studio preview | 148.412 | 1,345.042 | 143.23 |

Step duration covers candidate staging, momentum, pressure, scalar transport,
phase conversion, reconstruction and validation. Scenario runtime additionally
includes diagnostic/test work. The report does not time each stage separately;
the matched-input pressure benchmark above isolates that stage. Large maximum
durations reflect this host's variable load and are included rather than removed.

Native timings describe that host and load. Profile in Studio before growing
the grid. The current renderer retains a 1,200-Part cap, creates at most **32**
Parts per update and avoids property writes for unchanged cells; Laptop renders
at 1 Hz and Full at 2 Hz. Physical state is not stored in Parts.

## Historical first-order Phase 2 baseline

The following describes **0.2.0-alpha physics at f774c51**, before this revision.
These are comparison data, not current cloud timings or performance promises.
Reports were preserved as ignored `build/phase2-before-rework.json` and `.log`
in the development workspace; a fresh Git clone does not include them.

| Configuration, 240 simulated seconds | Sampled peak qc (kg/kg) | First visible sample | Final water drift |
| --- | --- | --- | --- |
| Scientific default, zero wind, core RH 0.98 | 0.000226999 | 90 s | −0.00000934% |
| U=0.5/V=0.25 m/s, core RH 0.98 | 0.000190842 | 90 s | −0.00005183% |
| U=8/V=4 m/s, shear 0.002/−0.001, core RH 0.98 | 0 | No cloud through 240 s | +0.00000954% |

The old shared-host runs averaged 50.65/74.22/65.34 ms per step and
48.94/71.70/63.09 s per 960-step scenario, with 39 owned buffers totaling
1,255,872 bytes. Old scalar sine errors at 16/32 cells were
0.000634975/0.000332491 kg/kg (ratio 0.5236). The strong-wind clear result exposed
first-order diffusion, not a stability failure. Comparisons retain the same
sounding to separate transport changes from a wetter preview.

The [Phase 1 reference](dynamic-cloud.md) records the vertical-only prototype.
Verify field accuracy, budgets and runtime before surface forcing, precipitation
or gameplay adapters. Final volumetric rendering remains separate.
