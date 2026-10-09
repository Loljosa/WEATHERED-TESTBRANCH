# Moving clouds and formation controls

The default Laptop preview remains Round, size 1, 6 K, RH 0.999 and 1x playback.
Controls alter the atmospheric sounding, authoritative MAC wind or fixed-step
playback. Cloud water continues to come from saturation adjustment with latent
heating; no shape or formation preset paints qc.

## Studio procedure

1. Build with `rojo build default.project.json -o build/WEATHERED.rbxlx` and open
   the result. Use **Run** for the isolated engine place, which has no floor or
   spawn. In an existing game, use Play and select Studio's **server** view.
2. Select `ServerScriptService.Weather.WeatherServer`. Open **Properties →
   Attributes** and keep **Output** open.
3. Enter a command in the **WeatherCommand** String attribute and press Enter.
   The input clears so you can repeat it. `LastWeatherMessage` shows the response.
4. Try `spawn Wide Fast`, then `wind 8 2`, then `form 60`. Look near `(0,470,0)`
   or select a Part inside `Workspace.WEATHERED_DEBUG_VOXELS` and press **F**.
5. Try `wind -8 -2` to reverse motion without resetting the cloud. Use `pause`
   to hold a developed cloud for inspection and `resume` to continue.

The display bottom stays at Y424, with 12-stud cells and centers Y430–562.
Height is a display offset, separate from physical thermodynamic height. Studio
has not been run here. The bootstrap test uses real server code with substituted
Roblox signals/Instances and renderer; it does not measure Studio frame rates.

## Commands

| WeatherCommand text | Effect |
| --- | --- |
| `wind 8 2` | Live X/Z background wind, 8/2 m/s; preserve cloud, shear and vertical flow |
| `wind 0 0` | Remove background wind; perturbation circulation still evolves |
| `speed 2` | Request 2x playback for all weather processes; range 0.25–4 |
| `spawn Round Normal` | New clear rounded source at 6 K and RH 0.999 |
| `spawn Wide Fast` | New broad source at 8 K and RH 0.9999 |
| `spawn Tower Fast` | New tall source at 8 K and RH 0.9999 |
| `spawn Wide Fast 1.25` | Set shape, formation preset and radius multiplier together |
| `size 1.25` | Restart the current shape/preset with scaled radii; range 0.5–1.5 |
| `condensation Fast` / `condensation Normal` | Restart the current shape/size with the selected warm/moist initial condition |
| `form 60` / `form` | Queue 60 physical seconds of real evolution at at least 2x playback |
| `pause` / `resume` | Pause/resume without accumulating paused time as backlog |
| `reset` | Restart the current source and wind settings at time zero |
| `status` / `help` | Print production diagnostics / command list |

Names are case insensitive. Wind is limited to ±30 m/s and checked against the
grid's momentum stability bound before committing. Form accepts multiples of
0.25 seconds in 0.25–240, replaces the remaining request and resumes a paused
model. Dropped backlog does not count toward completed formation. Afterwards
playback returns to the user-selected speed and the cloud continues evolving;
use `pause` to hold it. Shape describes the starting source, not a rigid final
cloud shape or a guarantee that every configuration will retain cloud forever.

**Spawn, size, condensation and reset replace the atmosphere.** Cloud water,
time, pressure-solver history and the water-drift baseline restart. This is a new
initial-condition experiment, not conservative moisture injection into an
existing cloud. Construction succeeds before replacing the running state.
Invalid commands retain the previous simulation. Wind/speed/form/pause/resume
retain the existing atmosphere.

Before Run, `CloudShape` and `CloudScale` also select the startup shape/size.
Commands synchronize changed settings in the running Script. Studio discards
runtime attribute edits when the test stops; edit the original Script while
stopped to change startup defaults.

## Command Bar API

In Studio's server context, the Script's server-only BindableFunction accepts the
same commands. It returns the response or the production status table:

```lua
game.ServerScriptService.Weather.WeatherServer.WeatherControls:Invoke("wind", 8, 2)
game.ServerScriptService.Weather.WeatherServer.WeatherControls:Invoke("spawn", "Wide", "Fast", 1.25)
game.ServerScriptService.Weather.WeatherServer.WeatherControls:Invoke("form", 60)
```

No client RemoteEvent or chat hook is exposed. Commands are tokenized, never
evaluated as code. If physics fails, Heartbeat and attribute commands disconnect;
address the reported failure and restart the Studio test.

## Numerical meaning and cost

Saturation adjustment already converts available vapor/cloud water to equilibrium
each step. Fast changes initial buoyancy/moisture to reach saturation earlier.
Speed/form change physical-time playback, retaining dt=0.25 s and the momentum →
projection → conservative transport → microphysics sequence.

For scale s, horizontal ellipsoid radii in cells are
`max(1,fraction*Nx*s)` and `max(1,fraction*Nz*s)`. Round/Tower use fraction 0.1875;
Wide uses 0.3. Round/Wide center Y is min(3,(Ny+1)/2), radius 2*s. Tower uses center
min(4,(Ny+1)/2), radius 3*s. Multiply radii by dx/dy/dz for meters. The existing
flat inner core/smooth edge is retained. First/last layers receive no perturbation,
so large sources can be truncated near the sealed walls. Factory defaults remain
Round, scale 1, 2 K and RH 0.98; the eight field buffers are unchanged.

Live wind shifts MAC U/V and their layerwise drag targets, preserving linear
shear. It reuses pending face buffers, validates float32 values and a maximum-
component momentum CFL bound before committing, and leaves theta/qv/qc/qr/
pressure/W untouched. Normal projection follows next step; immediate projection
diagnostics describe the last physics step. Hydrostatic pressure stays absolute
Pa with a separate projection correction buffer.

At Laptop spacing, 8 m/s maps to 0.64 display studs/s (38.4 studs/minute), before
deformation/perturbation flow. The 1 Hz debug display shows changing occupancy of
fixed 12-stud cells. Periodic X/Z boundaries wrap the cloud within the domain.
The qc centroid is not a parcel track.

Controls add no grid-sized buffers or per-step tables. Wind reuses staging storage.
Occasional resets allocate a new packed simulation; the renderer retains its Part
pool. Laptop keeps one step/Heartbeat and the soft 8 ms catch-up budget; an
indivisible step can exceed it. Form, warmer/larger sources and more visible Parts
can cost more CPU. Part creation remains capped at 32/update and 1200 pooled Parts.
Use speed 0.5–1 for ordinary play on a struggling laptop and form/Fast for previews.

## Tests and reports

`lune run scripts/test-atmosphere.luau --quick` runs short mathematical/control
checks. `--preview-only` also runs the Round/Normal Laptop baseline for 240 s and
a command-driven Wide/Fast 240 s wind/reversal case; it skips the four unchanged
long factory scenarios. Tests cover shape/size, zero initial qc, live wind/shear,
unchanged water/pressure/theta during wind changes, CFL rejection, invalid input,
atomic reset, pause/backlog, bounded formation, restored playback, real bootstrap
wiring, replacement-state rendering and failure shutdown.

Measured reports: `build/laptop-validation.json` and
`build/cloud-controls-validation.json`. Water accounting uses the fixed-density
unweighted mixing-ratio sum, not density-weighted physical mass.

### Measured results at 0.2.4-alpha

Focused validation passed **886,410 checks**, including both 240-second cases;
quick validation passed **72,458 checks**. StyLua, Rojo build and diff checks pass.
Rokit/npm setup was run. Four unchanged long scientific cases were not rerun.

| Formation case, size 1 and X/Z wind 8/2 m/s | First positive qc | First visible qc |
| --- | ---: | ---: |
| Wide/Normal | 8.50 s | 30.25 s |
| Wide/Fast | 2.25 s | 24.25 s |
| Tower/Fast | 1.50 s | 17.00 s |

These onset comparisons use 60-second production-module experiments. Wide/Fast
forms visibly about 19.83% earlier than Wide/Normal under matching geometry/wind.
At 2x playback, its first visibility corresponds to about 12 seconds and Tower's
to 8.5 seconds if the server keeps pace, with up to one extra render interval.
The unchanged default Round/Normal at wind 2/1 remains visible at 23.75 simulated
seconds. Onset depends on source geometry and wind; Fast is an initial-condition
preset rather than an independent multiplier on phase-conversion equations.

In the separate 240-second Wide/Fast command case, wind reverses from 8/2 to
−8/−2 m/s at 120 seconds. Its qc-weighted centroid advances 719.37 physical meters
in X over 30–120 seconds (57.55 display studs), then returns 947.90 meters over
120–240 seconds (75.83 studs). Phase conversion changes centroid weights, so this
is a cloud-motion diagnostic rather than a parcel trajectory.

| 240-second wind/reversal result | Measurement |
| --- | ---: |
| Final visible cells |87 |
| Final maximum qc |0.001293752 kg/kg |
| Unweighted water-sum drift |+0.000006949% |
| Maximum momentum/scalar Courant |0.0267123 |
| Maximum PCG iterations |51 |
| Final true pressure residual RMS/max |2.23e−10 /8.92e−10 s⁻¹ |
| Requested residual limit |1e−9 s⁻¹ |
| Final committed-face divergence RMS/max |2.06e−9 /7.15e−9 s⁻¹ |
| Float32 divergence acceptance bound |1.32e−8 s⁻¹ |

The current default-startup paired native benchmark measured 28.88 ms/step for
Laptop versus 70.34 ms for Full over 22 simulated seconds. It describes simulation
cost before visibility, excluding Roblox rendering and the rest of the game.
The stronger Wide/Fast cloud has more projection work/visible Parts; this default
benchmark does not establish its Studio cost. Buffer ownership remains 58 buffers
and 841,932 bytes for Laptop. See laptop-performance.md for settings and timing
caveats.
