<p align="center">
  <img src="assets/weathered-logo.png" alt="WEATHERED logo" width="1100">
</p>

<h1 align="center">WEATHERED</h1>

<p align="center"><strong>Survival beneath a changing sky.</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Roblox-393B3D" alt="Platform: Roblox">
  <img src="https://img.shields.io/badge/Language-Luau-00A6A6" alt="Language: Luau">
  <img src="https://img.shields.io/badge/Status-Early%20Development-D6A652" alt="Status: Early development">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-628B57" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="#quick-start">Get started</a> ·
  <a href="#studio-cloud-controls">Cloud controls</a> ·
  <a href="#validation">Validation</a> ·
  <a href="#documentation">Documentation</a>
</p>

## About WEATHERED

**WEATHERED** is a Roblox survival project built around an evolving atmosphere.
Its long-term goal is weather that shapes visibility, movement, vegetation and
survival through a shared, server-authoritative simulation.

This repository develops the weather engine independently of the larger game.
It contains a **CM1-inspired warm-cloud model written natively in Luau** and an
isolated Studio test place. Clouds start as clear, warm/moist air: buoyancy,
transport and saturation produce cloud water, which the debug renderer displays.

**The atmospheric field is authoritative.** Cloud visuals represent its state;
future gameplay services will sample the field for wind, rain and visibility.

| Current development snapshot | Status |
| --- | --- |
| Engine | `0.2.4-alpha` · Phase 2: 3D atmospheric dynamics |
| Cloud formation | Condensation and evaporation with latent heating/cooling |
| Cloud movement | 3D field transport and live horizontal wind controls |
| Preview controls | Source shape/size, formation presets, playback, pause and reset |
| Visualization | Pooled debug voxels; 12 × 12 × 12 studs |
| Verification | Lune tests and Rojo builds; Studio remains a separate manual test |

## Quick start

Install Git, Node.js/npm, [Rokit](https://github.com/rojo-rbx/rokit) and Roblox
Studio. Rokit provides the repository's pinned **Rojo 7.7.1** and **Lune 0.10.5**;
npm supplies StyLua for formatting. The Studio Rojo plugin is optional for live
sync; opening a built place does not require it.

For a new checkout:

```bash
git clone https://github.com/Loljosa/WEATHERED-TESTBRANCH.git
cd WEATHERED-TESTBRANCH
```

From your existing repository folder:

```bash
rokit install
npm ci
mkdir -p build
rojo build default.project.json -o build/WEATHERED.rbxlx
```

Open `build/WEATHERED.rbxlx` in Studio and choose **Run** to retain the editor
camera. The isolated engine place has no terrain, floor or spawn. In your existing
game place, use **Play** and switch Studio to the **server** view for controls.
Generated builds are ignored by Git.

### See your first cloud

1. Keep **Output** open. The default Laptop preview begins clear and prints
   simulation time and diagnostics every ten wall seconds.
2. Look near **(0, 470, 0)**. Cloud water first crosses the visible threshold at
   **23.75 simulated seconds** with the default settings. At 1x, that is roughly
   24 wall seconds if the server keeps up, plus up to one second of render delay.
3. Expand `Workspace.WEATHERED_DEBUG_VOXELS`. When a Part appears, select it and
   press **F** to focus the camera.
4. Open the cloud controls below to change movement, try another starting source
   or advance the atmosphere toward a developed cloud.

## Studio cloud controls

Select `ServerScriptService.Weather.WeatherServer` and open **Properties →
Attributes**. While the test is running, enter one command at a time in the
**WeatherCommand** String attribute and press Enter. It clears itself so you can
repeat commands; **LastWeatherMessage** and Output show the response.

| Command | What it does |
| --- | --- |
| `spawn Wide Fast` | Start a broad warm/moist source using the faster formation preset |
| `spawn Tower Fast` | Start a taller source using the faster formation preset |
| `spawn Round Normal` | Start the default rounded source |
| `size 1.25` | Scale the starting source's radii; supported range 0.5–1.5 |
| `wind 8 2` | Change live background X/Z wind to 8/2 physical m/s |
| `wind -8 -2` | Reverse horizontal wind while retaining the existing cloud |
| `form 60` | Queue 60 seconds of real model evolution with temporarily increased playback |
| `condensation Fast` | Restart the current shape/size with faster warm/moist formation conditions |
| `speed 1` | Set normal playback; supported range 0.25–4 |
| `pause` / `resume` | Hold the atmosphere for inspection or continue evolving |
| `reset` | Restart the current source and wind settings |
| `status` / `help` | Print diagnostics or the command list |

**Spawn, size, condensation and reset replace the atmosphere.** They restart from
clear air and reset simulation time. Wind changes preserve the existing cloud.
Shape and size describe the initial warm/moist source, which deforms as the
atmosphere evolves; voxel dimensions remain 12 studs.

Fast uses an 8 K potential-temperature excess and RH 0.9999. Saturation adjustment
still determines phase conversion. Form temporarily requests at least 2x playback,
keeps the fixed 0.25-second timestep and frame work limits, then restores your
selected speed. Faster playback and larger sources can cost more CPU.

For a quick preview, try **`spawn Wide Fast` → `wind 8 2` → `form 60`**.
The measured Tower/Fast source becomes visible at **17 simulated seconds** under
8/2 m/s wind. Cloud motion appears as changing occupancy of the fixed voxel grid.

See [the cloud controls guide](docs/cloud-controls.md) for command ranges, the
server Command Bar API, measured formation times and restart behavior.

## Preview presets and units

The default **Laptop** preset is the starting point for slower hardware. Keep
`SimulationSpeed` at **1**, or try **0.5** to reduce requested physics work. Change
`PerformancePreset` on the original Script while stopped, then restart.

| Setting | Laptop · default | Full · optional |
| --- | ---: | ---: |
| Grid, X × Y × Z | 16 × 12 × 16 | 24 × 12 × 24 |
| Cells | 3,072 | 6,912 |
| Physical spacing, X/Y/Z | 150/100/150 m | 100/100/100 m |
| Physical domain, X/Y/Z | 2,400/1,200/2,400 m | 2,400/1,200/2,400 m |
| Debug update rate | 1 Hz | 2 Hz |
| Maximum physics steps per Heartbeat | 1 | 2 |
| Requested playback speed | 1x | 1x |

Both presets use a soft **8 ms catch-up budget**. A single physics step is
indivisible and can exceed that budget; excess backlog is reported as dropped
simulation time. Native-host benchmarks do not establish your laptop's Studio FPS.

**Roblox studs and physical meters are separate scales.** The 12-stud display
cells span **Y424–568**, controlled by `CloudBottomStuds=424`. In an existing place
with terrain near Y70, this places the display 354–498 studs above that terrain.
Changing display height does not change pressure, temperature or physical spacing.
Wind axes are **u=X, v=Z, w=Y**, measured in physical m/s.

Before starting, `CloudShape`, `CloudScale`, `BackgroundU/V`, `ShearU/V`,
`BubbleRelativeHumidity` and `BubbleTemperaturePerturbation` configure the source.
The Studio default is Round, scale 1, wind 2/1 m/s, a 6 K bubble and RH 0.999.
The core factory retains its scientific zero-wind, 2 K and RH 0.98 defaults.
See [Laptop performance](docs/laptop-performance.md) for settings and profiling.

## How the atmosphere works

| System | Current implementation |
| --- | --- |
| Packed state | Eight float32 buffer fields: `u`, `v`, `w`, `theta`, `qv`, `qc`, `qr`, `pressure` |
| Thermodynamics | Potential temperature, hydrostatic absolute pressure and liquid-water saturation |
| Microphysics | Coupled condensation/evaporation, latent heat and float32 water accounting |
| Momentum | Staggered MAC winds, buoyancy, drag and viscosity |
| Pressure correction | Boussinesq projection with convergence and divergence diagnostics |
| Transport | Bounded conservative finite-volume flux correction with reusable scratch buffers |
| Boundaries | Periodic X/Z; sealed top and bottom |
| Rendering | Reusable cloud-water Part pool at diagnostic frequency |

The model uses a **constant-density approximation**. Water diagnostics are
unweighted mixing-ratio sums, rather than density-weighted physical mass.
Projection correction is separate from the absolute thermodynamic pressure field.
The coupled timestep remains first order even though scalar transport uses a
higher-accuracy bounded scheme. Precipitation fallout, terrain feedback and
sustained surface forcing are future work.

## Validation

Format and run the short production-module checks during routine development:

```bash
npx stylua src scripts tests
npx stylua --check src scripts tests
lune run scripts/test-atmosphere.luau --quick
git diff --check
```

| Command | Scope |
| --- | --- |
| `lune run scripts/test-atmosphere.luau --quick` | Mathematics, transport/projection, failure handling, controls, renderer and bootstrap wiring |
| `lune run scripts/test-atmosphere.luau --preview-only` | Short checks plus two 240-second preview trajectories and a matched formation comparison |
| `lune run scripts/test-atmosphere.luau` | Complete six-scenario long-run matrix and short checks |
| `lune run scripts/benchmark-atmosphere.luau` | Native-host Laptop/Full comparison; run separately from expensive tests |

At `0.2.4-alpha`, focused validation passed **886,410 checks**, including the default
Laptop trajectory and a Wide/Fast cloud with live wind reversal. The short suite
passed **72,458 checks**. These tests use real production modules and check
indexing, geometry, finiteness, moisture bounds, water/enthalpy accounting,
conservative fluxes, pressure convergence, fixed timesteps and command behavior.

Studio graphics and gameplay performance require a separate manual test.
See the [complete Studio procedure](docs/phase2-dynamics.md#exact-studio-test).

### Live sync with Rojo

```bash
rojo serve default.project.json
```

Connect the [Studio Rojo plugin](https://rojo.space/docs/v7/getting-started/installation/)
to the CLI server. When using a Codespace, Studio must be able to reach its
forwarded Rojo port. This workflow uses the CLI; the VS Code Rojo extension is
unnecessary.

## Documentation

| Guide | Read it for |
| --- | --- |
| [Cloud controls](docs/cloud-controls.md) | Shape/size, live wind, formation commands and measured moving-cloud results |
| [Laptop performance](docs/laptop-performance.md) | Presets, frame work limits, benchmark caveats and Studio settings |
| [Phase 2 dynamics](docs/phase2-dynamics.md) | Equations, boundaries, units, numerical assumptions and diagnostics |
| [Phase 1 reference](docs/dynamic-cloud.md) | The earlier vertical-only warm-cloud prototype |

<details>
<summary><strong>Repository layout</strong></summary>

```text
assets/                   WEATHERED branding
src/
├── shared/Atmosphere/
│   ├── Core/             Grid, physical geometry, staggered faces and packed state
│   ├── Thermodynamics/   Sounding, temperature conversion and saturation
│   ├── Microphysics/     Warm-cloud phase conversion
│   ├── Dynamics/         Momentum, projection and conservative 3D transport
│   ├── Utilities/        State validation
│   ├── Simulation.lua    Simulation ownership and stepping
│   └── init.lua          Public atmosphere entry point
├── server/
│   ├── Simulation/       Fixed-step controller, presets and cloud controls
│   ├── Debug/            Pooled voxel visualization
│   └── WeatherServer.server.lua
└── client/
    └── WeatherClient.client.lua

docs/                     Physics notes and Studio instructions
scripts/                  CLI validation and benchmarks
tests/                    Production-module tests and Roblox lookup adapters
```

</details>

## Roadmap

1. Profile the model in Studio and refine transport/solver cost while preserving
   numerical bounds and diagnostics.
2. Add controlled surface forcing and sustained cloud development with explicit
   water and energy budgets.
3. Expose atmospheric sampling and adapters for wind, precipitation and visibility
   in the larger survival game's existing systems.
4. Build precipitation, terrain interaction and storm lifecycle on that foundation.
5. Develop field-driven cloud clustering, client rendering and LOD after the
   simulation is ready to support them.

## Development principles

Use `--!strict` for core/simulation modules, document units, retain packed fields
and reuse scratch storage. Keep physics independent from rendering and validate
numerical behavior before adding model complexity. Make focused changes that
preserve working systems and existing gameplay.

## License

WEATHERED is licensed under the [MIT License](LICENSE).
