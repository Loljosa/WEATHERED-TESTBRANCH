# Dynamic warm-cloud milestone

This document records **Phase 1** and its measured vertical-column prototype.
Phase 2 replaces that transport and momentum update with three-dimensional
finite-volume transport and a staggered pressure projection. See
[Phase 2 dynamics](phase2-dynamics.md) for the current solver, limitations and
Studio procedure. The Phase 1 timings and water drift below are historical
reference results, not expected Phase 2 output.

The manually painted cloud-water ellipsoid has been replaced by an initially
clear atmospheric sounding and a warm/moist perturbation. All cloud water now
comes from vapor condensation. The field remains authoritative; debug Parts have
no collision, touch or query behavior and have no role in weather physics.

## Implementation

- `Atmosphere/init.lua` exposes `new(grid)`, fixed timestep and version.
- `Atmosphere/Simulation.lua` owns state, reusable transport scratch buffers,
  sounding, `Step(dt)` and diagnostics.
- `Core/Grid3D.lua` retains the original layout and world mapping; public indices
  must now be integers. `Core/AtmosphereState.lua` retains eight float32 field
  buffers and rejects nonfinite or overflowing public writes.
- `Thermodynamics/Sounding.lua` initializes background potential temperature,
  pressure, humidity and a warm/moist core with a smooth edge. It initializes
  `qc`, `qr`, `u`, `v` and `w` to zero.
- `Thermodynamics/Thermodynamics.lua` and `Saturation.lua` implement temperature
  conversion and liquid-water saturation.
- `Microphysics/WarmCloud.lua` performs reversible saturation adjustment with
  latent heating/cooling and water conservation.
- `Dynamics/Buoyancy.lua` computes moist buoyancy and integrates vertical velocity
  with linear drag.
- `Utilities/Validation.lua` checks field-buffer lengths, finite values, positive
  temperature/pressure and nonnegative water.
- `SimulationController.lua` owns the Heartbeat accumulator. The server bootstrap
  schedules physics, debug rendering and diagnostics; it disconnects the loop on
  a numerical or renderer error.
- `VoxelDebugRenderer.lua` reuses a bounded Part pool, updating it at 2 Hz.
- `scripts/test-atmosphere.luau` runs production source with Lune; the small loader
  in `tests/` supplies the Roblox module hierarchy and native Vector3/buffer types.

No inventory, tools, crafting, movement, vegetation, rain or world-generation
systems were changed. No placeholder modules or advanced rendering were added.

## Equations and units

`theta` and temperature are Kelvin; pressure is absolute Pascals, not a pressure
perturbation. Water fields are dry-air mixing ratios in kg/kg. `w` is physical
m/s; `u` and `v` remain zero. Model height is measured from the bottom of the
atmospheric domain, independently of workspace Y.

The grid remains **24 × 12 × 24**, with **64-stud** display spacing and origin
`Vector3.new(-768, 128, -768)`. Each vertical simulation cell represents **100 m**;
the physical domain is 1,200 m high. Only vertical physical spacing is used by
this milestone. No conversion from m/s to Roblox object velocity is applied.

With `kappa = Rd/cp` and `p0 = 100000 Pa`:

```text
Pi = (p/p0)^kappa
T = theta * Pi
theta_env(z) = 300 K + 0.003 K/m * z
Pi_env(z) = 1 - g/(cp * 0.003) * ln(theta_env(z)/300)
p_env = p0 * Pi_env^(cp/Rd)
```

The pressure approximation integrates dry hydrostatic balance for the linear
theta profile. Moist-density corrections and pressure perturbations are omitted.
The theta gradient is dry-stable and conditionally unstable for sufficiently
moist ascending air. Environmental relative humidity is
`0.85 * exp(-z/3000 m)`. The perturbation is centered at layer 3 (250 physical m),
with horizontal radii 4.5 cells and vertical radius 2 cells. Its core has +2 K
potential temperature and 98% relative humidity, tapering smoothly into the
environment. Vapor is calculated using each cell's perturbed temperature; every
cell starts subsaturated, with no cloud water or initial vertical velocity.

Liquid-water saturation uses the Bolton approximation, with `Tc = T - 273.15`:

```text
es(T) = 611.2 Pa * exp(17.67 * Tc / (Tc + 243.5))
qsat = 0.622 * es / (p - es)
```

The numerical saturation API accepts 180–350 K and requires `p > es`. This is a
liquid-only approximation, including supercooled liquid; it is not an ice model
or a claim of equal empirical accuracy across that entire interval.

At fixed pressure, phase conversion solves for condensation amount `delta`:

```text
qv_new = qv_old - delta
qc_new = qc_old + delta
T_new = T_old + (Lv/cp) * delta
qv_new = qsat(T_new, p)
```

The bounded Newton/bisection solve limits evaporation to existing cloud water
and condensation to existing vapor. If all liquid evaporates before saturation,
the cell remains subsaturated. `Lv = 2.5e6 J/kg` is constant. Phase adjustment
conserves `qv + qc` and approximate moist enthalpy `cp*T + Lv*qv`, apart from
roundoff and float32 storage. No water source, rain conversion or fallout exists.

Buoyancy includes dilute vapor enhancement and liquid loading:

```text
theta_v = theta * (1 + 0.61*qv - qc)
B = g * (theta_v/theta_v_env - 1)
dw/dt = B - w/tau, with tau = 30 s
w_new = w_old*exp(-dt/tau) + B*tau*(1-exp(-dt/tau))
```

The last expression treats buoyancy as constant during the substep. Linear drag
represents unresolved momentum dissipation; it is not a resolved turbulence model.

## Numerical behavior and limits

Physics uses **0.25 s** timesteps (4 Hz). Heartbeat time accumulates until a fixed
step is available. At most eight steps execute per callback; excess whole-step
backlog is dropped, retaining the fractional remainder. A rate-limited warning
and cumulative dropped-time diagnostic make stalled simulation time explicit.

Each step validates the input, transports theta/qv/qc/w vertically, adjusts
condensation/evaporation, calculates buoyancy, updates w, and validates the output.
Transport uses the old buffers for all cells and swaps four reusable buffers
only after transport is complete:

```text
C = abs(w)*dt/dz
f_new = (1-C)*f_old + C*f_upwind
```

`C <= 0.5` is enforced with an error; velocity is not clipped. Convex interpolation
preserves scalar bounds and positivity. Top/bottom **cell-center** vertical
velocity is held at zero; those cells retain their initial scalar profiles and
donor sampling never leaves the domain. This is a crude sealed-column boundary,
not a face-staggered wall treatment. Scalar mixing at height changes temperature
through potential temperature and the local Exner function.

There is no lateral transport or pressure/divergence constraint. Advective-form
vertical transport in a divergent velocity field **does not conserve global
water or air mass**, although the local phase adjustment conserves water. The
test reports this drift explicitly. Upwind diffusion also dilutes the perturbation
and influences cloud timing. The broad initial moist core prevents the coarse
grid from mixing it away before saturation.

There is no surface forcing, continual moisture supply, terrain, precipitation,
ice, mixing closure or gameplay sampling adapter yet. This is a transient cloud;
it is expected to fade. After an error the simulation stops and requires a
restart; it does not roll back a partially computed failed step. Consumers may
retain the State object, but must reacquire individual field buffers after a Step
because transport swaps them.

## Performance

Eight state buffers and four scratch buffers use **331,776 bytes (324 KiB)** at
6,912 cells, plus 96 bytes of sounding profiles. No table or Instance represents
an individual physical cell. Stepping has no large transient allocations, no
Vector3 construction and no Instance lookups; validation currently scans all
eight fields before and after each step for prototype diagnostics.

The debug pool contains at most **1,200 Parts**, creates at most **128 Parts per
render update**, and hides/reassigns existing Parts. It shows `qc >= 0.00005 kg/kg`
and encodes density by transparency, normalized to 0.0005 kg/kg. Parts remain
debug-only; property replication and the Part pool should be profiled separately
from simulation CPU before enlarging the grid. The first cells in grid order are
selected if the pool cap is reached.

## Automated validation

Install pinned tools using `rokit install` (Rojo 7.7.1 and Lune 0.10.5), then run:

```sh
npm ci
npx stylua src
npx stylua --check src scripts tests
lune run scripts/test-atmosphere.luau
mkdir -p build
rojo build default.project.json -o build/WEATHERED.rbxlx
git diff --check
git status --short --branch
```

The tests compile all production sources and execute the actual core/controller
modules. They cover grid/world round trips, buffer boundaries and invalid writes,
saturation monotonicity, theta conversion, condensation, full/partial evaporation,
water and moist-enthalpy conservation across 189 thermodynamic cases, buoyancy,
invalid-state/CFL failures and fixed-step/catch-up accounting. A 960-step run
checks all eight fields through **240 simulated seconds**.

Measured default run: initially zero qc; `qc >= 0.0001 kg/kg` by the 70 s sample;
peak qc approximately **0.000137 kg/kg** and peak |w| **2.566 m/s**. At 240 s,
the summed qv+qc drift is approximately **−0.200%**, due to the documented transport
limitation. Native Lune execution is a math/core integration check, not a Roblox
CPU benchmark. Rojo validates the project mapping/build; these checks do not
replace Studio runtime testing or a full Roblox-aware static type analysis.

## Exact Studio test

1. Build with the command above. Open `build/WEATHERED.rbxlx` in Studio for an
   isolated test, or run `rojo serve default.project.json` in the Codespace and
   connect the **Studio Rojo plugin** to the CLI server for the existing place.
   Live-sync access from a remote Studio installation must already reach the
   Codespace's Rojo port. The VS Code extension is unnecessary.
2. Confirm `ReplicatedStorage.Shared.Atmosphere` contains the new Simulation,
   Thermodynamics, Microphysics, Dynamics and Utilities modules, and
   `ServerScriptService.Weather` contains the server bootstrap/controller/debug
   renderer. Disable any separately installed copy of the old voxel bootstrap
   for this isolated test to avoid running two engines.
3. Open **View → Output**. Start **Play** or **Test → Start Server** with one
   player. The server should log version `0.1.0-alpha`, a 24×12×24 initialization,
   and diagnostics every ten wall seconds. Studio has not been run in this
   development environment.
4. Initially `Workspace.WEATHERED_DEBUG_VOXELS` should exist but contain no cloud
   Parts. Diagnostics should show zero qc; w should develop from zero without
   prescribed wind. Move the test camera toward the domain center around
   workspace `(0, 320, 0)`; the original voxel grid begins at Y=128 studs.
5. Let the **simulation-time** diagnostic reach 50–80 s. Thin cloud cells should
   appear near the lower central moist core, and exceed 0.0001 kg/kg by roughly
   70 s. Select a voxel in Explorer and press **F** to focus it if necessary.
   Catch-up warnings mean wall time may run ahead of simulation time.
6. Continue through 120–240 simulated seconds. Cloud density and occupied cells
   should change; the peak should be near 0.000137 kg/kg and vertical speed near
   2.6 m/s. The transient cloud thins later and eventually disappears. Independent
   columns produce a coarse, vertically evolving patch rather than resolved
   three-dimensional circulation.
7. Check Output for no `Atmosphere stopped`, invalid-field, solver or CFL errors.
   Confirm the Part count grows only when needed, stays within 1,200, and Parts
   become transparent as cells clear. The current default should use far fewer
   Parts. Stop and replay to verify a fresh, clear initial atmosphere.

The recommended next milestone is mass-conservative transport with a defined
velocity/divergence constraint and horizontal motion, while retaining the tested
thermodynamics. Establish that numerical foundation before volumetric rendering
or weather/gameplay integration.
