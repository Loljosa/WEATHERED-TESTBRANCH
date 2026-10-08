# Phase 2: three-dimensional atmospheric dynamics

Phase 2 replaces independent vertical columns with shared-face conservative
transport and a pressure-projected three-dimensional velocity field. The warm
cloud still begins from a clear sounding and warm/moist perturbation; cloud water
comes from condensation. Debug Parts remain representations of the atmospheric
field. No gameplay, world generation, rain system or final rendering is changed.

The pressure projection is an intentionally small constant-density Boussinesq
model, not a compressible CM1 port. It constrains the resolved flow so a buoyant
core can produce horizontal convergence and compensating vertical motion.

## Ownership and stepping

`Atmosphere/Simulation.lua` owns the cell state, face velocities, cached geometry,
momentum predictor, pressure solver and scalar-transport scratch storage. The
server controller continues to accumulate Heartbeat time and execute fixed
**0.25-second** steps. Eight steps per callback bound catch-up work; excess whole
steps are dropped with a diagnostic warning, preserving the fractional remainder.

Each step follows this order:

1. Validate the state and authoritative face velocities.
2. Predict all three face-velocity components from the previous faces, momentum
   advection, viscosity, buoyancy and drag toward the environmental wind profile.
3. Solve a pressure correction and subtract its face gradient to enforce the
   discrete divergence constraint.
4. Transport `theta`, `qv`, `qc` and `qr` with shared-face upwind fluxes from the
   projected velocities.
5. Apply the existing warm-cloud saturation adjustment with latent heating or
   cooling.
6. Reconstruct cell-centered `u`, `v`, `w`, validate the result and publish
   diagnostics.

`Core/Geometry.lua` caches integer neighbor indices. `Core/FaceVelocity.lua`
holds authoritative staggered velocities. `Dynamics/Momentum.lua`,
`Dynamics/Projection.lua` and `Dynamics/Transport.lua` implement the three
dynamics stages separately. Existing thermodynamic modules remain individually
testable; the renderer is unchanged and runs at **2 Hz**.

The public entry point is `Atmosphere.new(grid, config?)`, version
**0.2.0-alpha**. Configuration accepts `BackgroundU`, `BackgroundV`, `ShearU`,
`ShearV`, plus optional `MomentumOptions` and `ProjectionOptions`. The latter
configure the documented viscosity/drag and solver controls; defaults are used
by the Studio bootstrap. Repeated controller initialization returns the existing
simulation, so configuration belongs in the first initialization call.

`GetDiagnostics()` reports separate qv/qc/qr sums and total-water drift, face
velocity ranges, pre/post-projection divergence, iteration count and residual,
predictor/transport Courant numbers, and the measured most recent step duration.
Cloud centroids are physical meters from the domain corner. X/Z centroids use
circular means across periodic seams; `CloudCentroidDefined` is false when no
cloud exists or a horizontal centroid has no unique circular direction.
The controller adds cumulative `DroppedSimulationTime`. Step duration and
dropped wall-time backlog do not advance model time.

## Grid, units and boundaries

The default grid is **24 × 12 × 24**, with **6,912 cells**. Each physical cell
is **100 m × 100 m × 100 m** (`Grid.Dx`, `Grid.Dy`, `Grid.Dz`), giving a
2,400 m × 1,200 m × 2,400 m model domain. Display spacing remains **64 Roblox
studs**, beginning at `Vector3.new(-768, 128, -768)`. Physical meters are separate
from Roblox studs; m/s values are not assigned directly to Roblox object velocity.

Roblox's Y axis is vertical:

| Model quantity | Roblox axis | Units |
| --- | --- | --- |
| `u`, face `U` | X | m/s |
| `v`, face `V` | Z | m/s |
| `w`, face `W` | Y | m/s |
| `theta`, temperature | Cell centers | K |
| `qv`, `qc`, `qr` | Cell centers | kg water / kg dry air |
| State `pressure` | Cell centers | Absolute background Pa |
| Projection pressure correction | Cell centers | Kinematic pressure, m²/s² |

Horizontal X and Z boundaries are periodic. Flow and transported water crossing
one edge re-enter at the opposite edge. Top and bottom Y faces are impermeable:
their normal `W` velocity and scalar flux are exactly zero. These are a periodic
box and sealed walls, not open weather inflow/outflow or a terrain surface.

The MAC layout stores float32 velocities at cell faces. `U` and `V` each contain
`N` unique periodic faces; an adjacent cell references the same stored face
instead of a duplicate seam value. `W` contains `N + NX*NZ` faces, including the
top and bottom walls. With zero-based cell index `i`, `U[i]`, `V[i]` and `W[i]`
are its negative-X, negative-Z and negative-Y faces. Its positive faces are
`U[Xp[i]]`, `V[Zp[i]]` and `W[i + NX*NZ]`.

The eight original float32 cell-field buffers are retained. Their `u`, `v` and
`w` values are averages of surrounding projected faces and serve as diagnostics
and sampling values. Physics reads the authoritative faces, so editing those
cell-centered velocity fields does not prescribe the next step's flow. Consumers
may retain the State object but must reacquire scalar field buffers after a step
because transport swaps reusable buffers.

## Momentum predictor

For face velocity vector `a = (u, w, v)` in spatial `(X, Y, Z)` order, the
predictor approximates:

```text
da/dt = -(a · grad)a + nu*laplacian(a) + B*eY - (a - a_env)/tau
nu = 10 m²/s
tau = 30 s
a_env(y) = (U_env(y), 0, V_env(y))
```

Momentum advection uses first-order upwind derivatives on the staggered grid;
cross-components are interpolated to the target face. The seven-point explicit
Laplacian supplies modest numerical mixing. The predictor reads old face
buffers and writes separate reusable buffers so update order does not bias the
flow. Top and bottom walls remain sealed; tangential U/V use zero-gradient Y
ghost values. Drag is an analytical exponential relaxation after the explicit
advection/diffusion update. W includes constant-for-the-substep buoyancy in that
relaxation:

```text
U_star = U_env + (U_explicit - U_env)*exp(-dt/tau)
V_star = V_env + (V_explicit - V_env)*exp(-dt/tau)
W_star = W_explicit*exp(-dt/tau) + B_face*tau*(1-exp(-dt/tau))
```

The retained dilute moist-buoyancy approximation is:

```text
theta_v = theta*(1 + 0.61*qv - qc - qr)
B = g*(theta_v/theta_v_env - 1)
```

Adjacent cell buoyancies are averaged onto interior W faces. The environmental
reference theta and vapor profiles remain fixed; no terrain, continual surface
heating or moisture supply is present. Both liquid fields contribute loading,
although `qr` stays zero unless another caller initializes it.

Optional background wind is initialized at cell-center physical height
`h = (y - 0.5)*Dy`:

```text
U_env(h) = BackgroundU + ShearU*h
V_env(h) = BackgroundV + ShearV*h
```

Background velocities use m/s, and shear uses `(m/s)/m`. All four defaults are
zero. Uniform wind translates the perturbation; vertical shear can tilt and
stretch it. Drag relaxes toward this specified profile rather than continually
decaying the prescribed mean wind to zero.

## Pressure projection

Let `D` be cell divergence and `G` the matching face gradient. For predicted
velocity `a_star`, solve:

```text
D G phi = D(a_star)/dt
a_new = a_star - dt*G(phi)
D(a_new) approximately 0
```

For example, the cell divergence is:

```text
D(a) = (U_right-U_left)/Dx
     + (W_top-W_bottom)/Dy
     + (V_front-V_back)/Dz
```

The solver applies the positive-semidefinite operator `-D G` using cached
neighbors, with periodic horizontal boundaries and homogeneous Neumann wall
conditions. A Jacobi-preconditioned conjugate-gradient solve uses reusable
float64 buffers for kinematic pressure and work vectors, and warm-starts from
the previous correction. Pressure is held in a zero-mean gauge. The RHS
compatibility check rejects a nonzero mean divergence beyond arithmetic roundoff;
only that roundoff is removed. Preconditioned residuals also remain in the
zero-mean subspace, which preserves the singular Neumann/periodic operator's
convergence behavior.

The default iteration limit is **200**. Both RMS and maximum equation residual,
expressed as divergence by multiplying by `dt`, must satisfy:

```text
target = max(1e-9 s^-1, 1e-7 * RMS(divergence_before))
```

The actual equation residual is recomputed before declaring convergence.
Corrected float32 faces are staged separately and measured before commit. Their
RMS and maximum divergence must fall below the target plus a reported
quantization allowance. That allowance is the greater of **5e-8 s^-1** and the
per-cell rounding bound:

```text
0.5 * epsilon_f32 * [ (abs(U_left)+abs(U_right))/Dx
                    + (abs(W_bottom)+abs(W_top))/Dy
                    + (abs(V_back)+abs(V_front))/Dz ]
epsilon_f32 = 1.1920928955078125e-7
```

The solver's tight float64 convergence criterion and the float32 commit
postcondition are separate diagnostics.

Projection `phi` is a kinematic correction in m²/s², corresponding to pressure
perturbation divided by a constant reference density. It is not the absolute
pressure used in thermodynamics. State `pressure` retains the hydrostatic Pa
profile used by temperature and saturation calculations and is not overwritten
by the projection. Float32 face commits leave a small nonzero divergence floor;
the diagnostics report the actual committed velocities.

## Conservative scalar transport and water accounting

For scalar `s`, each stored face gets one upwind flux:

```text
F_face = a_normal * s_upwind
s_new = s_old - dt * D(F)
```

Fluxes use reusable float64 buffers. Both cells neighboring a face consume the
same flux with opposite signs, including periodic seams. Each scalar is written
to reusable scratch storage only after all old values have supplied their fluxes;
no update reads its own partially updated field. The sealed walls contribute
zero flux.

Under uniform cell volumes and constant reference density, summed mixing ratios
are proportional to the model's volume-integrated water inventory. Transport
conserves the sums of `theta`, `qv`, `qc` and `qr` up to float32 commit roundoff.
Subsequent phase conversion changes the separate qv and qc sums but conserves
`qv + qc`; therefore domain `qv + qc + qr` is the water diagnostic. A raw sum of
kg/kg values is not kilograms, and this model does not claim to conserve
variable-density atmospheric mass.

The unchanged warm-cloud adjustment solves `qv_new = qsat(T_new, p)` with
`T_new = T_old + (Lv/cp)*delta`, `qv_new = qv_old-delta` and
`qc_new = qc_old+delta`. Bounded Newton/bisection prevents evaporation beyond
available cloud water and condensation beyond available vapor. The liquid-water
Bolton saturation formula, hydrostatic sounding and enthalpy assumptions are
documented in the [Phase 1 reference](dynamic-cloud.md#equations-and-units).
`qr` is transported but starts zero and has no conversion or fallout process.

## Numerical checks and limitations

The unsplit outgoing Courant number is checked for every cell:

```text
C_out = dt * [ (max(U_right,0)+max(-U_left,0))/Dx
             + (max(W_top,0)+max(-W_bottom,0))/Dy
             + (max(V_front,0)+max(-V_back,0))/Dz ]
C_out <= 0.8
```

The predictor separately requires
`dt*(abs(aX)/Dx + abs(aY)/Dy + abs(aZ)/Dz + 2*nu*(Dx^-2 + Dy^-2 + Dz^-2)) <= 0.8`
at each predicted face. Violations, nonfinite fields, invalid water and
pressure-solver failure are reported as errors; excessive velocities are not
silently clipped. Scalar
positivity follows the outgoing-flux bound, and the projection makes scalar
transport approximately preserve bounds. Remaining divergence and float32
roundoff prevent a claim of exact boundedness or exact conservation.

Repeated phase changes smaller than a field's float32 spacing can be rounded
away differently across qv, qc and theta, accumulating a small water bias.
The measured 240-second conservation results do not establish exact long-term
phase equilibrium or a zero-drift water budget for arbitrarily long runs.
Warm-cloud thermodynamics remains unchanged in this phase.

This is first-order transport on a coarse grid: numerical diffusion dilutes
moisture and strongly affects cloud onset, shape and lifetime. The pressure
projection changes the Phase 1 vertical plume, so the old 50–80-second cloud
timing and −0.200% water drift are historical comparisons, not Phase 2 targets.
At strong background wind, first-order scalar diffusion can erase the warm/moist
core before saturation. A finite, water-conserving simulation can therefore
remain visually clear; cloud occurrence is separate from numerical stability.

There is no compressibility, density stratification in continuity, acoustics,
Coriolis force, adaptive stepping, terrain, resolved turbulence, precipitation,
ice or storm lifecycle. Fixed drag and viscosity are simple momentum damping,
not a turbulence closure. The fixed background pressure and buoyancy reference
are a low-order thermodynamic approximation; solving pressure does not make the
entire model energetically conservative. Momentum uses material-form upwind
advection rather than a conservative momentum flux, and drag/viscosity dissipate
kinetic energy without returning it to theta as heat. Advecting theta and mixing
ratios against prescribed spatial pressure, followed by local constant-pressure
latent heating, does not conserve a global compressible moist-energy budget.
First-order operator splitting adds timestep error. The transient bubble has no sustained
forcing. Simulation errors stop the server loop and require a restart; a failed
step is not rolled back transactionally.

## Performance

Physics remains packed buffer computation, with no per-cell tables, Vector3
construction or Instance lookups in the dynamics loops. Neighbor maps, face
predictor buffers, shared-flux storage and pressure work vectors are allocated
once and reused. Full finite-state scans remain enabled for prototype diagnostics.

Projection takes several whole-grid iterations per timestep and is expected to
dominate the new CPU cost. Lune timings measure native core execution in this
development environment, not Roblox server performance. Profile simulation and
debug Part property replication separately in Studio before increasing the grid.
The unchanged debug pool is capped at 1,200 Parts and 128 creations per render
update. No physical cell is represented by a Part.

The default grid allocates **39 buffers totaling 1,255,872 bytes (about 1.20 MiB)**:
the original cell fields, six cached neighbor maps, authoritative and predictor
faces, buoyancy, seven float64 projection vectors and staged projection faces,
shared fluxes, scalar scratch and sounding profiles. This is
`180*N + 20*(NX*NZ) + 16*NY` bytes; Lua object overhead and debug Instances are
additional. A traversal of the simulation's uniquely owned buffers verified
this allocation in all three validation scenarios.

The measured 960-step scenarios used these solver and runtime budgets:

| Scenario | Maximum PCG iterations, all steps | Maximum Courant, all steps | Mean step time | Run time |
| --- | --- | --- | --- | --- |
| Default, zero background wind | 54 | 0.004684 | 50.65 ms | 48.94 s |
| Weak uniform wind, 0.5/0.25 m/s | 54 | 0.006476 | 74.22 ms | 71.70 s |
| 8/4 m/s with shear stress case | 54 | 0.03445 | 65.34 ms | 63.09 s |

These are observations from one native Lune run in the shared development
container. CPU contention and instrumentation affect timings; they are not
dedicated benchmarks or evidence of Roblox performance. At four physical steps
per second, the measured averages suggest the current 6,912-cell grid is a
reasonable profiling starting point, not a basis for enlarging the domain.

## Validation

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

The suite executes production source through the existing Lune module loader.
It covers physical/world coordinate separation, cached periodic neighbors,
constant-field and pulse conservation, reverse-wind seam wrapping, interior
vertical transfer, sealed walls and outgoing-CFL failure. A manufactured gradient
velocity plus uniform wind tests projection reduction, the pressure gauge,
retention of the divergence-free wind component and sensitivity to tolerance.
Failure tests verify nonconverged projection does not commit faces and excessive
scalar CFL does not commit scalar state. Further checks cover neutral-air and
thermal-perturbation momentum, invalid configuration, deterministic field/face
snapshots, fixed-step catch-up and unchanged hydrostatic pressure.

The recorded full run passed **5,485,041 checks**, compiled all **20 production Luau
files**, and completed three **960-step / 240-second** scenarios. The manufactured
gradient test reduced divergence RMS from **0.232 s^-1 to 4.71e-9 s^-1**, with
post-projection maximum divergence **1.39e-8 s^-1**.

After that run, the final operator-only extension passed **11,091 checks**,
including a smooth periodic sine-advection accuracy test. Refining X resolution
from **16 to 32 cells** over a 1,000 m domain at U=4 m/s, 50 s duration and
Courant number 0.2 reduced scalar RMS error from **0.000634975 to 0.000332491
kg/kg** (ratio **0.5236**), consistent with the expected first-order convergence.
That test also preserved the scalar's initial bounds. Production physics was
unchanged between the full scenario run and this final operator check.

The scenario measurements were:

| Configuration | Sampled peak qc (kg/kg) | First debug-threshold cloud sample | Final water drift | Sampled maximum post-projection divergence |
| --- | --- | --- | --- | --- |
| Default: no background wind or shear | 0.000226999 | 90 s | −0.00000934% | 1.42e-9 s^-1 |
| Weak wind: U=0.5, V=0.25 m/s, zero shear | 0.000190842 | 90 s | −0.00005183% | 1.79e-9 s^-1 |
| Stress: U=8, V=4 m/s; shear U=0.002, V=−0.001 (m/s)/m | 0 | No cloud through 240 s | +0.00000954% | 1.28e-8 s^-1 |

Cloud, face-velocity and divergence statistics in this table were sampled every
**10 simulated seconds**; Courant/iteration maxima and step-time averages used
every step. Sampled peak absolute authoritative face velocities U/V/W were
**0.654/0.654/1.228 m/s** for the default case, **1.110/0.882/1.198 m/s** for weak
wind, and **10.315/4.344/0.760 m/s** for the stress case. All fields stayed finite,
water stayed nonnegative, and absolute hydrostatic pressure was unchanged.

The weak-wind qc centroid moved **70.29 m in X**, **41.46 m in Z** and **73.99 m
upward** between its first visible sample at 90 s and 240 s. This is a cloud-water
weighted centroid, not the trajectory of a material parcel. The strong case
demonstrates finite conservative transport under substantial wind; its clear
state also exposes the coarse first-order scheme's numerical mixing limitation.
The test script writes raw measurements to ignored
`build/phase2-validation.json`. The recorded validation run's stdout is also
saved in `build/phase2-validation.log`; the ordinary command prints that output
to the terminal.

The Phase 1 baseline is a 960-step, 240-second run with peak qc approximately
0.000137 kg/kg, peak vertical speed 2.566 m/s and summed qv+qc drift −0.19963%.
Compare water drift and projected divergence directly rather than trying to
match that plume's cloud shape. Automated Luau tests and Rojo builds do not test
Roblox Studio runtime or substitute for a Roblox-aware static type analysis.

## Exact Studio procedure

Studio has not been run in this development environment.

1. Build `build/WEATHERED.rbxlx` using the command above and open it in Studio for
   an isolated test. Alternatively run `rojo serve default.project.json` and
   connect the **Studio Rojo plugin** to the CLI server. Remote Studio must be
   able to reach the Codespace's Rojo port; the VS Code extension is unnecessary.
2. Confirm the new Core face/geometry and Dynamics momentum/projection/transport
   modules are under `ReplicatedStorage.Shared.Atmosphere`. Disable any separately
   installed old voxel bootstrap to avoid running two atmospheric engines.
3. Start with all background wind and shear options omitted or zero. Open
   **View → Output**, then start **Play** or a test server with one player.
   The startup log should identify **0.2.0-alpha** and a 24×12×24 domain.
   Inspect ten-second diagnostics for simulation time, water drift, projected
   divergence, Courant number and solver iteration count. Check for no stopped
   atmosphere, nonfinite-field, solver or CFL errors.
4. Move the camera near workspace `(0, 320, 0)` and watch
   `Workspace.WEATHERED_DEBUG_VOXELS`. The state starts cloud-free. The buoyant
   core should develop three-dimensional flow, with thin cloud voxels appearing
   if ascent survives coarse-grid mixing. Watch logged simulation time rather
   than elapsed wall time when catch-up warnings occur.
5. Stop Play. In Explorer, select
   `ServerScriptService.Weather.WeatherServer`. In **Properties → Attributes**,
   create Number attributes `BackgroundU = 0.5` and `BackgroundV = 0.25`. Leave
   `ShearU` and `ShearV` omitted or zero for the first translation test. Restart Play:
   the warm/moist core and resulting cloud should move in positive X and Z.
   Horizontal edge crossings wrap to the opposite edge; the transient cloud may
   dissipate before it reaches a seam.
6. For an optional shear comparison, stop and set `BackgroundU = 1`,
   `BackgroundV = 0.5`, `ShearU = 0.0002` and `ShearV = -0.0001`. Shear uses
   `(m/s)/m`. Restart and inspect the centroid and velocity diagnostics as well
   as voxels. This case produces only weak, intermittent visible cloud on the
   coarse grid; do not expect a broad, strongly tilted cloud. These options are
   read at initialization; changing them during Play does not change the active
   model.
7. Continue the zero-wind and wind/shear runs through **240 simulated seconds**.
   Confirm water remains nearly constant and the face projection keeps divergence
   small. Check that Parts are reused, stay below the pool cap, and become
   transparent as cells clear. Stop and replay to verify a fresh, clear state.
8. Optionally stress scalar transport with `BackgroundU = 8`, `BackgroundV = 4`,
   `ShearU = 0.002` and `ShearV = -0.001`, then restart. This stronger configuration
   stayed stable and conserved water in the measured 240-second test, but remained
   cloud-free because first-order upwind mixing diluted the perturbation before
   condensation. Expect finite wind and projection diagnostics, not visible
   clouds, in that test.

In the independently measured `BackgroundU = 0.5`, `BackgroundV = 0.25`, zero-shear
run, qc first became positive at **64.5 s** and crossed the debug threshold
**0.00005 kg/kg at 89.75 s**. The renderer should therefore show thin clouds at
roughly 90 simulated seconds, then a slowly moving and rising patch. These are
native Luau measurements, not a Studio observation:

| Simulation time | Visible-threshold cells | Maximum qc (kg/kg) | qc centroid X/Y/Z (physical m) |
| --- | --- | --- | --- |
| 120 s | 5 | 0.000091602 | 1272.1 / 350.0 / 1237.0 |
| 180 s | 6 | 0.00011909 | 1304.4 / 361.36 / 1255.1 |
| 240 s | 10 | 0.00019084 | 1327.4 / 423.99 / 1266.7 |

For the current isotropic display scale, those centroids correspond approximately
to workspace `(46, 352, 24)`, `(67, 359, 35)` and `(82, 399, 43)`. Camera
position and voxel transparency can make this small cloud easy to miss. Select
a cloud Part in Explorer and press **F** to focus it. Observe a full **240
simulated seconds** before comparing cloud shape and drift.

The next numerical milestone should assess accuracy and cost of this constrained
flow, then refine transport and add controlled surface forcing. Precipitation
and gameplay adapters should follow verified water budgets; final volumetric
rendering remains separate from atmospheric state.
