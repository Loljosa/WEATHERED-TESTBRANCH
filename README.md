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

## About

**WEATHERED** is a Roblox survival project built around an evolving atmosphere.
The long-term goal is weather that affects visibility, movement, vegetation and
survival through a shared simulation, with clouds and rain representing its state.

This repository, **WEATHERED-TESTBRANCH**, focuses on developing that weather
engine. The current milestone is a small, server-authoritative warm-cloud
prototype written in Luau, inspired by atmospheric modeling concepts used in CM1.

The atmospheric field is authoritative. Visual effects represent the field;
gameplay systems will eventually sample it through dedicated services.

## Current prototype

The simulation starts clear, with a vertical environmental profile and a warm,
moist perturbation. Buoyancy produces vertical motion; ascending air can reach
saturation, condense cloud water and later evaporate it as conditions change.

| Component | Implemented behavior |
| --- | --- |
| Atmospheric state | Eight packed float32 fields: `u`, `v`, `w`, `theta`, `qv`, `qc`, `qr`, `pressure` |
| Thermodynamics | Potential temperature, hydrostatic background pressure and liquid-water saturation |
| Warm-cloud microphysics | Condensation and evaporation with coupled float32 phase transfer and latent heating/cooling |
| 3D dynamics | Staggered winds, buoyancy, drag, viscosity and Boussinesq pressure projection |
| Scalar transport | Bounded conservative flux correction; periodic X/Z and sealed Y boundaries |
| Time stepping | Fixed 0.25-second steps with bounded catch-up |
| Debug visualization | Reusable cloud-water voxel Parts, updated at 1 Hz in the default Laptop preset |
| Validation | Core mathematics, conservative fluxes, projection, numerical failures and 240-second scenarios |

The default Studio **Laptop** preset contains **3,072 cells** (16 × 12 × 16), with
physical X/Y/Z spacing of **150/100/150 meters**. The optional **Full** preset keeps
the original 6,912 cells (24 × 12 × 24) and 100-meter spacing. Both cover the same
2,400 × 1,200 × 2,400-meter atmosphere. The Studio preview uses
**12 × 12 × 12-stud** debug voxels spanning **Y=424–568 studs**, placing the display
354–498 studs above terrain at Y=70. Physical and display scales are separate; the
400-stud display-height increase does not change simulation physics. The preview explicitly
uses a nearly saturated moist core and 2/1 m/s background wind; the core factory
retains its zero-wind, 98% core-humidity defaults.

### Prototype limits

The flow uses a constant-density approximation rather than stratified atmospheric
mass continuity. Water accounting reports unweighted mixing-ratio sums. Scalar
transport uses a less diffusive bounded scheme, while the coupled atmosphere
timestep remains first order. There is no precipitation fallout, terrain
interaction or sustained surface forcing.

See [Laptop performance](docs/laptop-performance.md) for the presets, measured
cost and Studio controls. See [Phase 2 dynamics](docs/phase2-dynamics.md) for
equations, assumptions, measured results and the complete Studio test procedure.
The [Phase 1 reference](docs/dynamic-cloud.md) records the earlier vertical-only prototype.

## Development setup

You will need Git, Node.js/npm, [Rokit](https://github.com/rojo-rbx/rokit), Roblox
Studio and the [Studio Rojo plugin](https://rojo.space/docs/v7/getting-started/installation/).
The repository pins **Rojo 7.7.1** and **Lune 0.10.5** through Rokit.

```bash
git clone https://github.com/Loljosa/WEATHERED-TESTBRANCH.git
cd WEATHERED-TESTBRANCH
rokit install
npm ci
```

### Build a test place

```bash
mkdir -p build
rojo build default.project.json -o build/WEATHERED.rbxlx
```

Open `build/WEATHERED.rbxlx` in Studio for an isolated test. Generated place files
are ignored by Git.

### Live sync

```bash
rojo serve default.project.json
```

Connect the **Studio Rojo plugin** to the CLI server. When using a Codespace,
Studio must be able to reach the forwarded Rojo server port. The VS Code Rojo
extension is not required for this workflow.

### Format and validate

```bash
npx stylua src
npx stylua --check src scripts tests
lune run scripts/test-atmosphere.luau
git diff --check
```

Lune executes the production core and controller modules using a small Roblox
module loader. Automated checks cover grid/world conversions, float32 buffer
safety, saturation, phase-change water and enthalpy conservation, conservative
3D transport, pressure projection, finite fields and fixed-step catch-up behavior.

Studio testing remains a separate step. Use **Run** for the isolated engine-only
build to keep the editor camera; it has no floor or spawn. Use **Play** when syncing
into an existing game place with a floor and spawn. Watch the server's ten-second
diagnostics and the `Workspace.WEATHERED_DEBUG_VOXELS` folder near **(0, 460, 0)**.
Preview settings are attributes on `ServerScriptService.Weather.WeatherServer`
in **Properties → Attributes**. `PerformancePreset` defaults to **Laptop**; changing
it to **Full** requires stopping and restarting the test. `SimulationSpeed`
defaults to **1** and can change live from **0.25 to 4** in Studio's server view;
the physical timestep stays 0.25 seconds. Try **0.5** on slower hardware.
`CloudBottomStuds` defaults to **424**; change the original Script's attribute
while stopped and restart to adjust the display height.
No terminal or Command Bar speed command is needed. See the
[Studio procedure](docs/phase2-dynamics.md#studio-preview-and-controls) for cloud
timing, wind, humidity and display settings.

## Repository layout

```text
src/
├── shared/Atmosphere/
│   ├── Core/             Physical geometry, staggered faces and packed state
│   ├── Thermodynamics/   Sounding, temperature conversion and saturation
│   ├── Microphysics/     Warm-cloud phase conversion
│   ├── Dynamics/         Momentum, pressure projection and conservative 3D transport
│   ├── Utilities/        State validation
│   ├── Simulation.lua    Simulation ownership and stepping
│   └── init.lua          Public atmosphere entry point
├── server/
│   ├── Simulation/       Fixed-timestep controller
│   ├── Debug/            Pooled voxel visualization
│   └── WeatherServer.server.lua
└── client/
    └── WeatherClient.client.lua

docs/                     Physics notes and Studio testing instructions
scripts/                  Command-line validation
tests/                    Roblox module loader for Lune
```

## Direction

1. Measure transport accuracy and cost, improve bounded transport and add
   controlled surface forcing with verified water budgets.
2. Develop precipitation, terrain interaction and storm lifecycle on that
   numerical foundation.
3. Expose atmospheric sampling and adapters for wind, precipitation, visibility
   and the larger survival game's existing systems.
4. Replace debug voxels with field-driven cloud clustering, rendering and client LOD.

Keep physics independent from rendering, retain packed field storage and reusable
buffers, and validate numerical behavior before expanding the model.

## License

The repository is licensed under the [MIT License](LICENSE).
