--!strict

-- Run from the repository root: lune run scripts/benchmark-atmosphere.luau
-- Optional --laptop or --full selects one preset. By default both run in
-- alternating order, reducing CPU-frequency/order bias in the comparison.
-- Lune already enables native code generation in RobloxModuleLoader. These are
-- native-host simulation timings, not Roblox Studio frame-rate measurements,
-- and they do not measure the effect of Roblox's --!native directive.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Vector3 = require("@lune/roblox").Vector3
local createLoader = require("../tests/RobloxModuleLoader")
local root, loadModule = createLoader("src/shared/Atmosphere")
local Atmosphere = loadModule(root)
local Grid3D = loadModule(root.Core.Grid3D)
local settingsRoot, loadSettings = createLoader("src/server/Simulation")
local PerformanceSettings = loadSettings(settingsRoot.PerformanceSettings)
local startupAttributes =
	serde.decode("json", fs.readFile("src/server/WeatherServer.meta.json")).attributes
local configuration = {
	BackgroundU = startupAttributes.BackgroundU,
	BackgroundV = startupAttributes.BackgroundV,
	ShearU = startupAttributes.ShearU,
	ShearV = startupAttributes.ShearV,
	BubbleRelativeHumidity = startupAttributes.BubbleRelativeHumidity,
	BubbleTemperaturePerturbation = startupAttributes.BubbleTemperaturePerturbation,
	BubbleShape = startupAttributes.CloudShape,
	BubbleScale = startupAttributes.CloudScale,
}

local WARMUP_STEPS = 8
local TIMED_STEPS = 80
local FIXED_DT = Atmosphere.FixedDt
local presets = { "Laptop", "Full" }
if #process.args > 0 then
	assert(
		#process.args == 1,
		"Usage: lune run scripts/benchmark-atmosphere.luau [--laptop|--full]"
	)
	assert(process.args[1] == "--laptop" or process.args[1] == "--full", "Unknown benchmark option")
	presets = { if process.args[1] == "--laptop" then "Laptop" else "Full" }
end

local function ownedBuffers(value: any, seen: { [any]: boolean }?): (number, number)
	local visited = seen or {}
	if visited[value] then
		return 0, 0
	end
	if typeof(value) == "buffer" then
		visited[value] = true
		return 1, buffer.len(value)
	elseif type(value) == "table" then
		visited[value] = true
		local count, bytes = 0, 0
		for _, child in value do
			local childCount, childBytes = ownedBuffers(child, visited)
			count += childCount
			bytes += childBytes
		end
		return count, bytes
	end
	return 0, 0
end

local function stateChecksum(simulation: any): string
	local contents = {}
	for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
		table.insert(
			contents,
			name .. "\0" .. buffer.tostring(simulation.State.Fields[name]) .. "\0"
		)
	end
	for _, name in { "U", "V", "W" } do
		table.insert(contents, name .. "\0" .. buffer.tostring(simulation.Faces[name]) .. "\0")
	end
	table.insert(contents, "Correction\0" .. buffer.tostring(simulation.Projection.Correction))
	return serde.hash("sha256", table.concat(contents))
end

local function sourceFingerprint(): string
	local paths = {
		"src/server/Simulation/PerformanceSettings.lua",
		"src/server/WeatherServer.meta.json",
		"tests/RobloxModuleLoader.luau",
	}
	local function collect(directory: string)
		for _, name in fs.readDir(directory) do
			local path = directory .. "/" .. name
			if fs.isDir(path) then
				collect(path)
			elseif string.sub(path, -4) == ".lua" then
				table.insert(paths, path)
			end
		end
	end
	collect("src/shared/Atmosphere")
	table.sort(paths)
	local contents = {}
	for _, path in paths do
		table.insert(contents, path .. "\0" .. fs.readFile(path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local runs: { any } = {}
for _, preset in presets do
	local settings = PerformanceSettings.Resolve(preset)
	local grid = Grid3D.new(
		settings.SizeX,
		settings.SizeY,
		settings.SizeZ,
		startupAttributes.CellSizeStuds,
		Vector3.new(
			-settings.SizeX * startupAttributes.CellSizeStuds * 0.5,
			startupAttributes.CloudBottomStuds,
			-settings.SizeZ * startupAttributes.CellSizeStuds * 0.5
		),
		{ Dx = settings.Dx, Dy = settings.Dy, Dz = settings.Dz }
	)
	local simulation = Atmosphere.new(grid, configuration)
	assert(
		simulation:GetDiagnostics().MaxCloudWater == 0,
		"Benchmark must start without seeded cloud water"
	)
	local count, bytes = ownedBuffers(simulation)
	table.insert(runs, {
		Preset = preset,
		Settings = settings,
		Simulation = simulation,
		InitialPressure = buffer.tostring(simulation.State.Fields.pressure),
		BufferCount = count,
		BufferBytes = bytes,
		TotalMilliseconds = 0,
		MaximumMilliseconds = 0,
		TotalIterations = 0,
		MaximumIterations = 0,
		MaximumCourant = 0,
		MaximumResidual = 0,
		MaximumResidualMax = 0,
		MaximumDivergenceAfter = 0,
	})
end

for step = 1, WARMUP_STEPS + TIMED_STEPS do
	for position = 1, #runs do
		local index = if step % 2 == 0 then position else #runs + 1 - position
		local run = runs[index]
		local simulation = run.Simulation
		simulation:Step(FIXED_DT)
		if step > WARMUP_STEPS then
			local milliseconds = simulation.StepMilliseconds
			local projection = simulation.Projection.Last
			run.TotalMilliseconds += milliseconds
			run.MaximumMilliseconds = math.max(run.MaximumMilliseconds, milliseconds)
			run.TotalIterations += projection.Iterations
			run.MaximumIterations = math.max(run.MaximumIterations, projection.Iterations)
			run.MaximumCourant = math.max(
				run.MaximumCourant,
				simulation.MomentumCourant,
				simulation.TransportCourant
			)
			run.MaximumResidual = math.max(run.MaximumResidual, projection.Residual)
			run.MaximumResidualMax = math.max(run.MaximumResidualMax, projection.ResidualMax)
			run.MaximumDivergenceAfter = math.max(run.MaximumDivergenceAfter, projection.AfterMax)
		end
	end
end

local scenarios = {}
for _, run in runs do
	local simulation, settings = run.Simulation, run.Settings
	local count, bytes = ownedBuffers(simulation)
	assert(
		count == run.BufferCount and bytes == run.BufferBytes,
		"Simulation buffer storage grew during benchmark"
	)
	assert(
		buffer.tostring(simulation.State.Fields.pressure) == run.InitialPressure,
		"Projection changed thermodynamic pressure"
	)
	local mean = run.TotalMilliseconds / TIMED_STEPS
	local scenario = {
		Preset = run.Preset,
		Grid = {
			SizeX = settings.SizeX,
			SizeY = settings.SizeY,
			SizeZ = settings.SizeZ,
			Cells = simulation.Geometry.Count,
		},
		PhysicalSpacingMeters = { Dx = settings.Dx, Dy = settings.Dy, Dz = settings.Dz },
		MeanStepMilliseconds = mean,
		MaximumStepMilliseconds = run.MaximumMilliseconds,
		MeanProjectionIterations = run.TotalIterations / TIMED_STEPS,
		MaximumProjectionIterations = run.MaximumIterations,
		MaximumCourant = run.MaximumCourant,
		MaximumProjectionResidualRms = run.MaximumResidual,
		MaximumProjectionResidualMax = run.MaximumResidualMax,
		MaximumDivergenceAfter = run.MaximumDivergenceAfter,
		OwnedBufferCount = count,
		OwnedBufferBytes = bytes,
		StateSHA256 = stateChecksum(simulation),
		Final = simulation:GetDiagnostics(),
		-- Cost estimate assumes the requested rate is attained and excludes the
		-- renderer, diagnostics, Roblox scheduling, and every other game system.
		EstimatedSimulationMillisecondsPerWallSecondAt1x = mean / FIXED_DT,
		EstimatedSimulationMillisecondsPerWallSecondAt2x = mean / FIXED_DT * 2,
	}
	table.insert(scenarios, scenario)
	print(
		string.format(
			"%s %dx%dx%d: mean %.3f ms, max %.3f ms, PCG mean %.2f/max %d, buffers %d/%d bytes, state SHA256 %s",
			run.Preset,
			settings.SizeX,
			settings.SizeY,
			settings.SizeZ,
			mean,
			run.MaximumMilliseconds,
			scenario.MeanProjectionIterations,
			run.MaximumIterations,
			count,
			bytes,
			scenario.StateSHA256
		)
	)
end

fs.writeDir("build")
fs.writeFile(
	"build/performance-benchmark.json",
	serde.encode("json", {
		SourceSHA256 = sourceFingerprint(),
		Environment = "Lune native-host code generation; not Roblox Studio FPS",
		NativeDirectiveGainMeasured = false,
		Configuration = configuration,
		WarmupSteps = WARMUP_STEPS,
		TimedSteps = TIMED_STEPS,
		FixedDt = FIXED_DT,
		SimulatedSeconds = (WARMUP_STEPS + TIMED_STEPS) * FIXED_DT,
		Scenarios = scenarios,
	}, true)
)
print(
	"Saved build/performance-benchmark.json; run without other expensive jobs for useful timings."
)
