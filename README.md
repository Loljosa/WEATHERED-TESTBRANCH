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
| Warm-cloud microphysics | Condensation and evaporation with latent heating/cooling and local water conservation |
| Vertical evolution | Buoyancy, linear momentum drag and double-buffered upwind transport |
| Time stepping | Fixed 0.25-second steps with bounded catch-up |
| Debug visualization | Reusable cloud-water voxel Parts, updated at 2 Hz |
| Validation | Core mathematics, buffer indexing, numerical failures and a 240-second simulation run |

The default grid contains **6,912 cells** (24 × 12 × 24). Display spacing is
**64 Roblox studs**; physical vertical spacing is **100 meters**. These scales are
separate. The Part-based cloud is a development visualization.

### Prototype limits

There is no horizontal circulation, pressure correction, precipitation fallout
or terrain interaction yet. Vertical transport is diffusive and does not conserve
global water in divergent flow, although phase conversion conserves local water.
The initial cloud is transient and eventually fades without continued forcing.

See [the dynamic-cloud milestone](docs/dynamic-cloud.md) for equations, assumptions,
measured results and the complete Studio test procedure.

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
safety, saturation, phase-change water and enthalpy conservation, buoyancy,
finite fields and fixed-step catch-up behavior.

Studio testing remains a separate step. In Play mode, watch the server's ten-second
diagnostics and the `Workspace.WEATHERED_DEBUG_VOXELS` folder. The default transient
cloud should begin appearing after roughly **50–80 simulated seconds**.

## Repository layout

```text
src/
├── shared/Atmosphere/
│   ├── Core/             Grid, constants and packed atmospheric state
│   ├── Thermodynamics/   Sounding, temperature conversion and saturation
│   ├── Microphysics/     Warm-cloud phase conversion
│   ├── Dynamics/         Buoyancy and vertical momentum
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

1. Establish mass-conservative transport, a velocity/divergence constraint and
   horizontal motion.
2. Develop precipitation, surface forcing, terrain interaction and storm lifecycle
   on that numerical foundation.
3. Expose atmospheric sampling and adapters for wind, precipitation, visibility
   and the larger survival game's existing systems.
4. Replace debug voxels with field-driven cloud clustering, rendering and client LOD.

Keep physics independent from rendering, retain packed field storage and reusable
buffers, and validate numerical behavior before expanding the model.

## License

The repository is licensed under the [MIT License](LICENSE).
