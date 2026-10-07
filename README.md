# WEATHERED-TESTBRANCH
Test branch of Roblox survival experience named WEATHERED.

The atmosphere now evolves from an initially clear warm/moist perturbation. The
server runs fixed-timestep thermodynamics, vertical transport and buoyancy; pooled
debug voxels visualize simulated cloud water.

```sh
rokit install
npm ci
npx stylua src
lune run scripts/test-atmosphere.luau
mkdir -p build
rojo build default.project.json -o build/WEATHERED.rbxlx
git diff --check
```

Use `rojo serve default.project.json` and the **Roblox Studio Rojo plugin** for live
sync. The VS Code Rojo extension is not required.

See [the dynamic-cloud milestone](docs/dynamic-cloud.md) for equations, numerical
limits, validation results and the exact Studio test procedure.
