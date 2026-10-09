--!strict

-- Run from the repository root: lune run scripts/test-atmosphere.luau
-- This executes production source; no physics equations are copied into the tests.
local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local createLoader = require("../tests/RobloxModuleLoader")
local root, loadModule = createLoader("src/shared/Atmosphere")
local Grid3D = loadModule(root.Core.Grid3D)
local Constants = loadModule(root.Core.Constants)
local AtmosphereState = loadModule(root.Core.AtmosphereState)
local Saturation = loadModule(root.Thermodynamics.Saturation)
local Thermodynamics = loadModule(root.Thermodynamics.Thermodynamics)
local WarmCloud = loadModule(root.Microphysics.WarmCloud)
local Buoyancy = loadModule(root.Dynamics.Buoyancy)
local Atmosphere = loadModule(root)
local Vector3 = roblox.Vector3

local compiled = 0
local function compileDirectory(path: string)
	for _, name in fs.readDir(path) do
		local filePath = path .. "/" .. name
		if fs.isDir(filePath) then
			compileDirectory(filePath)
		elseif string.sub(name, -4) == ".lua" then
			luau.compile(fs.readFile(filePath))
			compiled += 1
		end
	end
end
compileDirectory("src")
print(string.format("PASS: all %d production Luau files compile", compiled))

local checks = 0
local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function near(actual: number, expected: number, tolerance: number, message: string)
	check(
		math.abs(actual - expected) <= tolerance,
		message .. string.format(" (%.12g vs %.12g)", actual, expected)
	)
end

local function rejects(callback: () -> (), message: string)
	local ok = pcall(callback)
	check(not ok, message)
end

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local grid = Grid3D.new(7, 5, 3, 64, Vector3.new(-224, 128, -96))
for index = 1, grid.Count do
	local x, y, z = grid:Coordinates(index)
	check(grid:Index(x, y, z) == index, "Grid index/coordinate round trip")
	local world = grid:GridToWorld(x, y, z)
	local worldX, worldY, worldZ = grid:WorldToGrid(world)
	check(worldX == x and worldY == y and worldZ == z, "Grid/world round trip")
end
local boundaryX, boundaryY, boundaryZ = grid:WorldToGrid(grid.Origin)
check(boundaryX == 1 and boundaryY == 1 and boundaryZ == 1, "Origin maps to first cell")
local outsideX = grid:WorldToGrid(grid.Origin - Vector3.new(0.125, 0, 0))
check(outsideX == 0, "WorldToGrid preserves positions outside the domain")
rejects(function()
	grid:Index(0, 1, 1)
end, "Out-of-range grid coordinate must fail")
rejects(function()
	grid:Index(1.5, 1, 1)
end, "Fractional grid coordinate must fail")
rejects(function()
	grid:Coordinates(grid.Count + 1)
end, "Out-of-range grid index must fail")
rejects(function()
	grid:Coordinates(1.5)
end, "Fractional grid index must fail")
rejects(function()
	Grid3D.new(3, 2, 1, math.huge, Vector3.zero)
end, "Nonfinite cell size must fail")

local state = AtmosphereState.new(grid)
for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
	check(buffer.len(state.Fields[name]) == grid.Count * 4, "Float32 buffer has exact cell count")
	state:Set(name, 1, 1.25)
	state:Set(name, grid.Count, 2.5)
	near(state:Get(name, 1), 1.25, 0, "First float32 field element")
	near(state:Get(name, grid.Count), 2.5, 0, "Last float32 field element")
end
rejects(function()
	state:Get("qc", 0)
end, "Buffer read outside domain must fail")
rejects(function()
	state:Set("qc", grid.Count + 1, 1)
end, "Buffer write outside domain must fail")
rejects(function()
	state:Set("qc", 1.5, 1)
end, "Fractional field index must fail")
rejects(function()
	state:Set("theta", 1, 0 / 0)
end, "NaN field write must fail")
rejects(function()
	state:Set("w", 1, math.huge)
end, "Infinite field write must fail")
rejects(function()
	state:Set("w", 1, 1e40)
end, "Float32-overflow field write must fail")

local previousSaturation = 0
for temperature = 250, 310, 5 do
	local mixingRatio = Saturation.MixingRatio(temperature, 100000)
	check(
		finite(mixingRatio) and mixingRatio > previousSaturation,
		"Saturation rises with temperature"
	)
	previousSaturation = mixingRatio
end
check(
	Saturation.MixingRatio(293.15, 80000) > Saturation.MixingRatio(293.15, 100000),
	"Saturation mixing ratio rises as pressure falls"
)
near(
	Saturation.VaporPressure(273.15),
	611.2,
	1.0,
	"Water saturation vapor pressure at freezing in Pa"
)
check(
	Saturation.MixingRatio(293.15, 100000) > 0.014
		and Saturation.MixingRatio(293.15, 100000) < 0.016,
	"20 C saturation mixing ratio is about 15 g/kg"
)
for _, pressure in { 100000, 80000, 60000 } do
	local temperature = Thermodynamics.Temperature(300, pressure)
	near(
		Thermodynamics.PotentialTemperature(temperature, pressure),
		300,
		1e-10,
		"Potential temperature inversion"
	)
end

local theta = 293.15
local initialVapor = Saturation.MixingRatio(theta, 100000) + 0.004
local condensedTheta, condensedVapor, condensedCloud =
	WarmCloud.Adjust(theta, initialVapor, 0, 100000)
check(
	condensedCloud > 0 and condensedVapor < initialVapor,
	"Supersaturation creates cloud from vapor"
)
check(condensedTheta > theta, "Condensation releases latent heat")
near(condensedVapor + condensedCloud, initialVapor, 1e-11, "Condensation conserves total water")
near(
	condensedVapor,
	Saturation.MixingRatio(Thermodynamics.Temperature(condensedTheta, 100000), 100000),
	1e-8,
	"Condensation reaches saturation including latent heating"
)
local evaporatedTheta, evaporatedVapor, evaporatedCloud =
	WarmCloud.Adjust(theta, 0.002, 0.002, 100000)
check(
	evaporatedCloud >= 0 and evaporatedCloud < 0.002,
	"Dry air evaporates cloud without negative cloud water"
)
check(evaporatedTheta < theta, "Evaporation consumes latent heat")
near(evaporatedVapor + evaporatedCloud, 0.004, 1e-11, "Evaporation conserves total water")
local partialVapor = 0.99 * Saturation.MixingRatio(theta, 100000)
local partialTheta, remainingVapor, remainingCloud =
	WarmCloud.Adjust(theta, partialVapor, 0.005, 100000)
check(
	remainingCloud > 0 and remainingCloud < 0.005,
	"Partial evaporation retains positive cloud water"
)
near(
	remainingVapor + remainingCloud,
	partialVapor + 0.005,
	1e-11,
	"Partial evaporation conserves total water"
)
near(
	remainingVapor,
	Saturation.MixingRatio(Thermodynamics.Temperature(partialTheta, 100000), 100000),
	1e-8,
	"Partial evaporation reaches saturation"
)

-- Check physical invariants over changing pressures, humidity and cloud loading.
-- cp*T + Lv*qv is the constant-pressure moist enthalpy used by this approximation.
for temperature = 250, 310, 10 do
	for _, pressure in { 70000, 85000, 100000 } do
		local parcelTheta = Thermodynamics.PotentialTemperature(temperature, pressure)
		local saturation = Saturation.MixingRatio(temperature, pressure)
		for _, relativeHumidity in { 0.6, 1, 1.4 } do
			for _, cloudWater in { 0, 0.0005, 0.003 } do
				local vapor = saturation * relativeHumidity
				local adjustedTheta, adjustedVapor, adjustedCloud =
					WarmCloud.Adjust(parcelTheta, vapor, cloudWater, pressure)
				local adjustedTemperature = Thermodynamics.Temperature(adjustedTheta, pressure)
				check(
					finite(adjustedTheta) and finite(adjustedVapor) and finite(adjustedCloud),
					"Phase adjustment stays finite across physical states"
				)
				check(
					adjustedVapor >= 0 and adjustedCloud >= 0,
					"Phase adjustment preserves nonnegative water"
				)
				near(
					adjustedVapor + adjustedCloud,
					vapor + cloudWater,
					1e-11,
					"Phase adjustment conserves total water across physical states"
				)
				local originalEnthalpy = Constants.SpecificHeatDryAir * temperature
					+ Constants.LatentHeatVaporization * vapor
				local adjustedEnthalpy = Constants.SpecificHeatDryAir * adjustedTemperature
					+ Constants.LatentHeatVaporization * adjustedVapor
				near(
					adjustedEnthalpy,
					originalEnthalpy,
					1e-6,
					"Phase adjustment conserves approximate moist enthalpy"
				)
				if adjustedCloud > 0 then
					near(
						adjustedVapor,
						Saturation.MixingRatio(adjustedTemperature, pressure),
						1e-8,
						"Air with cloud water reaches saturation"
					)
				else
					check(
						adjustedVapor
							<= Saturation.MixingRatio(adjustedTemperature, pressure) + 1e-8,
						"Clear adjusted air is unsaturated"
					)
				end
			end
		end
	end
end
local clearTheta, clearVapor, clearCloud = WarmCloud.Adjust(theta, 0.002, 0, 100000)
near(clearTheta, theta, 1e-10, "Unsaturated clear air has no phase-change heating")
near(clearVapor, 0.002, 1e-11, "Unsaturated clear air retains vapor")
near(clearCloud, 0, 0, "Unsaturated clear air retains zero cloud")
near(
	Buoyancy.Calculate(300, 0.01, 0, 300, 0.01),
	0,
	1e-12,
	"Environmental air is neutrally buoyant"
)
check(Buoyancy.Calculate(301, 0.01, 0, 300, 0.01) > 0, "Warm parcel is buoyant")
check(Buoyancy.Calculate(300, 0.01, 0.001, 300, 0.01) < 0, "Cloud loading reduces buoyancy")
print(
	string.format(
		"PASS: grid, float32 state, saturation, latent heat, phase conversion and buoyancy (%d checks)",
		checks
	)
)

local function sourceFingerprint(directories: { string }): string
	local paths = {}
	local function collect(path: string)
		for _, name in fs.readDir(path) do
			local filePath = path .. "/" .. name
			if fs.isDir(filePath) then
				collect(filePath)
			else
				table.insert(paths, filePath)
			end
		end
	end
	for _, directory in directories do
		collect(directory)
	end
	table.sort(paths)
	local contents = {}
	for _, path in paths do
		table.insert(contents, path .. "\0" .. fs.readFile(path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end
local productionFingerprint = sourceFingerprint({ "src" })
local testFingerprint = sourceFingerprint({ "scripts", "tests" })

local testDynamics = require("../tests/three-dimensional-dynamics")
local operatorsOnly = table.find(process.args, "--operators-only") ~= nil
local quick = table.find(process.args, "--quick") ~= nil
-- Preview tuning needs the complete startup regression, without repeating four
-- long scientific scenarios. All short operator/API/controller checks still run.
local previewOnly = table.find(process.args, "--preview-only") ~= nil
assert(not (previewOnly and quick), "Use --preview-only or --quick, not both")
local scenarioSummaries =
	testDynamics(root, loadModule, check, near, rejects, operatorsOnly, quick or previewOnly)
if operatorsOnly then
	print(string.format("PASS: %d scalar and 3D operator checks", checks))
	return
end
-- A compact domain is enough to check numerical failure behavior.
local failureGrid = Grid3D.new(3, 4, 3, 64, Vector3.zero)
local failureSimulation = Atmosphere.new(failureGrid)
rejects(function()
	failureSimulation:Step(0)
end, "Zero simulation timestep must fail")
rejects(function()
	failureSimulation:Step(0 / 0)
end, "NaN simulation timestep must fail")
rejects(function()
	failureSimulation:Step(1)
end, "Oversized simulation timestep must fail")
buffer.writef32(failureSimulation.State.Fields.theta, 0, 0 / 0)
rejects(function()
	failureSimulation:Step(0.25)
end, "Invalid buffer values must stop simulation")
near(failureSimulation.Time, 0, 0, "A failed simulation does not advance its clock")
local cflSimulation = Atmosphere.new(failureGrid)
buffer.writef32(cflSimulation.Faces.U, (failureGrid:Index(2, 2, 2) - 1) * 4, 1000)
rejects(function()
	cflSimulation:Step(0.25)
end, "Excessive momentum Courant number must fail explicitly")
near(cflSimulation.Time, 0, 0, "A failed CFL check does not advance the clock")

local testLaptopPerformance = require("../tests/laptop-performance")
local startupAttributes =
	serde.decode("json", fs.readFile("src/server/WeatherServer.meta.json")).attributes
near(
	startupAttributes.BubbleTemperaturePerturbation,
	6,
	0,
	"Studio startup selects the faster 6 K bubble"
)
near(
	startupAttributes.BubbleRelativeHumidity,
	0.999,
	0,
	"Faster startup retains the near-saturated bubble"
)
near(startupAttributes.SimulationSpeed, 1, 0, "Faster startup retains the laptop-safe 1x step rate")
near(startupAttributes.CellSizeStuds, 12, 0, "Faster startup retains exact 12-stud debug cells")
near(
	startupAttributes.CloudBottomStuds,
	424,
	0,
	"Faster startup retains the raised display altitude"
)
check(
	startupAttributes.PerformancePreset == "Laptop",
	"Faster startup keeps the Laptop performance preset"
)
testLaptopPerformance(root, loadModule, check, near, rejects, quick)
local testDebugRenderer = require("../tests/debug-renderer")
testDebugRenderer(root, loadModule, check, near, rejects)
local testCloudControls = require("../tests/cloud-controls")
testCloudControls(root, loadModule, check, near, rejects, quick)
local testWeatherBootstrap = require("../tests/weather-bootstrap")
testWeatherBootstrap(root, check, near, rejects)

-- The service shim is only a lookup adapter; the real production controller
-- owns its accumulator, timestep and catch-up limit during this test.
local replicatedStorage = { Shared = { Atmosphere = root } }
local game = {
	GetService = function(_self: any, name: string): any
		assert(name == "ReplicatedStorage", "Unexpected test service request")
		return replicatedStorage
	end,
}
local warnings = 0
local controllerRoot, loadControllerModule = createLoader("src/server/Simulation", {
	game = game,
	print = function() end,
	warn = function()
		warnings += 1
	end,
})
local controller = loadControllerModule(controllerRoot.SimulationController)
local previewGrid = controller.GetGrid()
near(previewGrid.CellSize, 12, 0, "Controller defaults to 12-stud preview cells")
near(previewGrid.Origin.Y, 424, 0, "Controller defaults to a 424-stud display bottom")
near(previewGrid.Dx, 100, 0, "Preview display size preserves the 100-meter physical grid")
local controllerState = controller.Initialize({ BackgroundU = 0.5, BackgroundV = 0.25 })
check(controller.Initialize() == controllerState, "Controller Initialize is idempotent")
near(controllerState:Get("u", 1), 0.5, 0, "Lazy controller Initialize accepts background x wind")
near(controllerState:Get("v", 1), 0.25, 0, "Lazy controller Initialize accepts background z wind")
check(controller.Advance(0.1) == 0, "Partial frame does not step atmosphere")
check(controller.Advance(0.1) == 0, "Accumulated partial frames remain below fixed dt")
check(controller.Advance(0.05) == 1, "Fractional frame times combine into one fixed step")
near(controller.GetTime(), 0.25, 1e-12, "Controller executes fixed dt")
check(controller.Advance(3) == 8, "Controller caps catch-up at eight steps")
near(controller.GetTime(), 2.25, 1e-12, "Catch-up advances only executed physical time")
near(controller.GetDroppedTime(), 1, 1e-12, "Controller accounts for dropped catch-up backlog")
check(warnings == 1, "Controller reports catch-up backlog")
local controllerDiagnostics = controller.GetDiagnostics()
near(
	controllerDiagnostics.Time,
	controller.GetTime(),
	0,
	"Controller exposes flattened simulation diagnostics"
)
near(
	controllerDiagnostics.DroppedSimulationTime,
	1,
	0,
	"Controller diagnostics include dropped simulation time"
)
check(
	controller.Advance(0.125, 2) == 1,
	"Preview speed doubles accumulated physical time without changing dt"
)
near(controller.GetTime(), 2.5, 0, "Double-speed preview still advances by fixed 0.25-second steps")
near(controller.GetDiagnostics().SimulationSpeed, 2, 0, "Controller reports current preview speed")
check(controller.Advance(0.25, 0.5) == 0, "Half-speed preview accumulates a partial fixed step")
check(controller.Advance(0.25, 0.5) == 1, "Two half-speed frames form exactly one fixed step")
near(controller.GetTime(), 2.75, 0, "Preview speed changes preserve the existing accumulator")
check(controller.Advance(3, 4) == 8, "Maximum preview speed retains bounded catch-up")
near(controller.GetTime(), 4.75, 0, "Scaled catch-up commits only executed fixed steps")
near(
	controller.GetDroppedTime(),
	11,
	0,
	"Scaled backlog is accounted in physical simulation seconds"
)
for _, speed in { 0, 0.24999, 4.00001, math.huge, 0 / 0 } do
	rejects(function()
		controller.Advance(0.25, speed)
	end, "Preview speed rejects nonfinite or unsupported rates")
end
local customRoot, loadCustomController = createLoader("src/server/Simulation", {
	game = game,
	print = function() end,
	warn = function() end,
})
local customController = loadCustomController(customRoot.SimulationController)
customController.Initialize(nil, { CellSizeStuds = 16, CloudBottomStuds = 32 })
local displayGrid = customController.GetGrid()
near(displayGrid.CellSize, 16, 0, "Controller accepts display-only cell size configuration")
near(displayGrid.Origin.X, -192, 0, "Configured display domain remains centered horizontally")
near(
	displayGrid:GridToWorld(1, 1, 1).Y,
	40,
	0,
	"Configured grid/world conversion uses display studs"
)
local _, physicalHeight = displayGrid:GridToPhysical(1, 1, 1)
near(physicalHeight, 50, 0, "Display options do not change physical cell height")
rejects(function()
	controller.Advance(-1)
end, "Negative Heartbeat dt must fail")
rejects(function()
	controller.Advance(0 / 0)
end, "NaN Heartbeat dt must fail")
print(
	string.format(
		"PASS: explicit numerical failure checks and production fixed-timestep/catch-up controller (%d total checks)",
		checks
	)
)

if not quick then
	fs.writeDir("build")
	local reportPath = if previewOnly
		then "build/fast-preview-validation.json"
		else "build/phase2-validation.json"
	fs.writeFile(
		reportPath,
		serde.encode("json", {
			Mode = if previewOnly then "PreviewOnly" else "Full",
			SourceRevision = string.gsub(
				process.exec("git", { "rev-parse", "HEAD" }).stdout,
				"%s+$",
				""
			),
			WorkingTreeChanged = process.exec("git", { "status", "--porcelain" }).stdout ~= "",
			BeforeReworkReport = "build/phase2-before-rework.json",
			ProductionSourceSHA256 = productionFingerprint,
			TestSourceSHA256 = testFingerprint,
			TotalChecks = checks,
			Phase1MeasuredWaterDriftPercent = -0.19963,
			SimulationSecondsPerScenario = 240,
			FixedDt = 0.25,
			DiagnosticSamplingSeconds = 10,
			Scenarios = scenarioSummaries,
			PreviewReport = "build/laptop-validation.json",
		})
	)
	print("Saved measured scenario diagnostics: " .. reportPath)
end
