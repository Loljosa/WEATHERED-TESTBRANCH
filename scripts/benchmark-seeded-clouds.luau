--!strict

-- Paired native-host benchmark, never a Studio FPS measurement:
-- lune run scripts/benchmark-seeded-clouds.luau --baseline <frozen-repository>
-- Optional --laptop/--full selects one preset; --quick shortens the timing run.
-- Use a frozen, clean Phase 2 source directory, not a moving checkout.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Vector3 = require("@lune/roblox").Vector3
local createLoader = require("../tests/RobloxModuleLoader")

local baselinePath = nil
local selectedPreset = nil
local quick = false
local argIndex = 1
while argIndex <= #process.args do
	local argument = process.args[argIndex]
	if argument == "--baseline" then
		assert(
			baselinePath == nil and process.args[argIndex + 1] ~= nil,
			"Provide --baseline exactly once with a frozen repository path"
		)
		baselinePath = process.args[argIndex + 1]
		argIndex += 1
	elseif argument == "--laptop" or argument == "--full" then
		assert(selectedPreset == nil, "Select at most one performance preset")
		selectedPreset = if argument == "--laptop" then "Laptop" else "Full"
	elseif argument == "--quick" then
		assert(not quick, "Provide --quick at most once")
		quick = true
	else
		error("Unknown benchmark argument: " .. argument)
	end
	argIndex += 1
end
assert(
	baselinePath ~= nil,
	"Usage: lune run scripts/benchmark-seeded-clouds.luau --baseline <frozen-repository> [--laptop|--full] [--quick]"
)
local frozenPath = baselinePath :: string
assert(
	fs.isFile(frozenPath .. "/src/shared/Atmosphere/Simulation.lua"),
	"Baseline path must contain the frozen production atmosphere"
)
local currentRoot, loadCurrent = createLoader("src/shared/Atmosphere")
local frozenRoot, loadFrozen = createLoader(frozenPath .. "/src/shared/Atmosphere")
local Current = loadCurrent(currentRoot)
local Frozen = loadFrozen(frozenRoot)
local CurrentGrid = loadCurrent(currentRoot.Core.Grid3D)
local FrozenGrid = loadFrozen(frozenRoot.Core.Grid3D)
local serverRoot, loadServer = createLoader("src/server/Simulation", {
	game = {
		GetService = function(_self: any, name: string): any
			assert(name == "ReplicatedStorage")
			return { Shared = { Atmosphere = currentRoot } }
		end,
	},
	print = function() end,
	warn = function() end,
})
local PerformanceSettings = loadServer(serverRoot.PerformanceSettings)
local Manager = loadServer(serverRoot.CloudSourceManager)
assert(Current.FixedDt == Frozen.FixedDt, "Paired comparison requires the same fixed timestep")
local fixedDt = Current.FixedDt
local warmupSteps = 8
local timedSteps = if quick then 80 else 232 -- total 60 physical seconds normally.
local totalSteps = warmupSteps + timedSteps
local configuration = {
	BackgroundU = 8,
	BackgroundV = 2,
	ShearU = 0,
	ShearV = 0,
	BubbleRelativeHumidity = 0.999,
	BubbleTemperaturePerturbation = 6,
	BubbleShape = "Round",
	BubbleScale = 1,
}

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

local function checksum(simulation: any): string
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

local function fingerprint(directory: string): string
	local paths = {}
	local function collect(relative: string)
		for _, name in fs.readDir(directory .. "/" .. relative) do
			local path = relative .. "/" .. name
			if fs.isDir(directory .. "/" .. path) then
				collect(path)
			elseif string.sub(path, -4) == ".lua" then
				table.insert(paths, path)
			end
		end
	end
	collect("src/shared/Atmosphere")
	collect("src/server/Simulation")
	table.sort(paths)
	local contents = {}
	for _, path in paths do
		table.insert(contents, path .. "\0" .. fs.readFile(directory .. "/" .. path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local frozenProductionFingerprint = fingerprint(frozenPath)
local currentProductionFingerprint = fingerprint(".")
local benchmarkFingerprint = serde.hash(
	"sha256",
	"scripts/benchmark-seeded-clouds.luau\0"
		.. fs.readFile("scripts/benchmark-seeded-clouds.luau")
		.. "\0tests/RobloxModuleLoader.luau\0"
		.. fs.readFile("tests/RobloxModuleLoader.luau")
		.. "\0"
)
local sourceRevision = string.gsub(process.exec("git", { "rev-parse", "HEAD" }).stdout, "%s+$", "")
local workingTreeChanged = process.exec("git", { "status", "--porcelain" }).stdout ~= ""

local presets = if selectedPreset then { selectedPreset } else { "Laptop", "Full" }
local runs = {}
for _, preset in presets do
	local settings = PerformanceSettings.Resolve(preset)
	for _, mode in { "FrozenPhase2", "CurrentLegacy", "CurrentSeeded" } do
		local constructor = if mode == "FrozenPhase2" then Frozen else Current
		local gridConstructor = if mode == "FrozenPhase2" then FrozenGrid else CurrentGrid
		local grid = gridConstructor.new(
			settings.SizeX,
			settings.SizeY,
			settings.SizeZ,
			12,
			Vector3.new(-settings.SizeX * 6, 424, -settings.SizeZ * 6),
			{ Dx = settings.Dx, Dy = settings.Dy, Dz = settings.Dz }
		)
		local options = table.clone(configuration)
		if mode == "CurrentSeeded" then
			options.DisableBubble = true
		end
		local start = os.clock()
		local simulation = constructor.new(grid, options)
		local coreInitMilliseconds = (os.clock() - start) * 1000
		local manager = nil
		local sourceInitMilliseconds = 0
		if mode == "CurrentSeeded" then
			start = os.clock()
			manager = Manager.new(simulation, {
				Seed = 84219,
				InitialSourceCount = settings.InitialSourceCount,
				MaxInitialSources = settings.MaxInitialSources,
				BuildSamplesPerStep = settings.SourceBuildSamplesPerStep,
				AutoClouds = true,
			})
			manager:InitializeSources()
			sourceInitMilliseconds = (os.clock() - start) * 1000
		end
		assert(
			simulation:GetDiagnostics().QcSum == 0,
			"Benchmark initial conditions must not paint cloud water"
		)
		local count, bytes = ownedBuffers({ simulation, manager })
		table.insert(runs, {
			Preset = preset,
			Mode = mode,
			Settings = settings,
			Simulation = simulation,
			Manager = manager,
			CoreInitializationMilliseconds = coreInitMilliseconds,
			SourceInitializationMilliseconds = sourceInitMilliseconds,
			InitialPressure = buffer.tostring(simulation.State.Fields.pressure),
			BufferCount = count,
			BufferBytes = bytes,
			Timings = {},
			CoreTotalMilliseconds = 0,
			CoreMaximumMilliseconds = 0,
			SourceTotalMilliseconds = 0,
			SourceMaximumMilliseconds = 0,
			MaximumIterations = 0,
			TotalIterations = 0,
			MaximumCourant = 0,
			MaximumResidual = 0,
			MaximumDivergenceAfter = 0,
			FirstCloudWaterSeconds = nil,
			FirstVisibleCloudSeconds = nil,
		})
	end
end

-- Rotate and reverse the evaluation order so a particular scenario does not
-- consistently receive the coolest CPU or the earliest host scheduler slot.
for tick = 1, totalSteps do
	for position = 1, #runs do
		local index = ((position - 1 + tick - 1) % #runs) + 1
		if tick % 2 == 0 then
			index = #runs + 1 - index
		end
		local run = runs[index]
		local simulation, manager = run.Simulation, run.Manager
		local sourceStart = os.clock()
		if manager and tick == 120 then
			manager:QueueSource()
		end
		local forcing = if manager then manager:PrepareStep(tick, fixedDt) else nil
		local sourceBeforeMilliseconds = (os.clock() - sourceStart) * 1000
		local stepStart = os.clock()
		simulation:Step(fixedDt, forcing)
		local stepMilliseconds = (os.clock() - stepStart) * 1000
		sourceStart = os.clock()
		if manager then
			manager:CommitStep(tick)
		end
		local sourceMilliseconds = sourceBeforeMilliseconds + (os.clock() - sourceStart) * 1000
		if tick > warmupSteps then
			table.insert(run.Timings, stepMilliseconds + sourceMilliseconds)
			run.CoreTotalMilliseconds += stepMilliseconds
			run.CoreMaximumMilliseconds = math.max(run.CoreMaximumMilliseconds, stepMilliseconds)
			run.SourceTotalMilliseconds += sourceMilliseconds
			run.SourceMaximumMilliseconds =
				math.max(run.SourceMaximumMilliseconds, sourceMilliseconds)
			run.TotalIterations += simulation.Projection.Last.Iterations
			run.MaximumIterations =
				math.max(run.MaximumIterations, simulation.Projection.Last.Iterations)
			run.MaximumCourant = math.max(
				run.MaximumCourant,
				simulation.MomentumCourant,
				simulation.TransportCourant
			)
			run.MaximumResidual = math.max(run.MaximumResidual, simulation.Projection.Last.Residual)
			run.MaximumDivergenceAfter =
				math.max(run.MaximumDivergenceAfter, simulation.Projection.Last.AfterMax)
		end
		-- Sparse diagnostics do not contaminate the timed physics/source interval.
		if tick % 4 == 0 then
			local d = simulation:GetDiagnostics()
			if run.FirstCloudWaterSeconds == nil and d.QcSum > 0 then
				run.FirstCloudWaterSeconds = d.Time
			end
			if run.FirstVisibleCloudSeconds == nil and d.CloudCells > 0 then
				run.FirstVisibleCloudSeconds = d.Time
			end
		end
	end
end

local scenarios = {}
for _, run in runs do
	local count, bytes = ownedBuffers({ run.Simulation, run.Manager })
	assert(
		count == run.BufferCount and bytes == run.BufferBytes,
		"Packed-buffer ownership grew during the benchmark"
	)
	assert(
		buffer.tostring(run.Simulation.State.Fields.pressure) == run.InitialPressure,
		"Projection/source forcing changed hydrostatic pressure"
	)
	table.sort(run.Timings)
	local meanCore = run.CoreTotalMilliseconds / timedSteps
	local meanSources = run.SourceTotalMilliseconds / timedSteps
	local scenario = {
		Preset = run.Preset,
		Mode = run.Mode,
		Grid = {
			SizeX = run.Settings.SizeX,
			SizeY = run.Settings.SizeY,
			SizeZ = run.Settings.SizeZ,
			Cells = run.Simulation.Geometry.Count,
		},
		CoreInitializationMilliseconds = run.CoreInitializationMilliseconds,
		SourceInitializationMilliseconds = run.SourceInitializationMilliseconds,
		CoreStepTimingIncludesExternalForcing = run.Manager ~= nil,
		MeanCoreStepMilliseconds = meanCore,
		MaximumCoreStepMilliseconds = run.CoreMaximumMilliseconds,
		MeanSourceSchedulerMilliseconds = meanSources,
		MaximumSourceSchedulerMilliseconds = run.SourceMaximumMilliseconds,
		MeanCombinedStepMilliseconds = meanCore + meanSources,
		MedianCombinedStepMilliseconds = run.Timings[math.ceil(#run.Timings * 0.5)],
		P95CombinedStepMilliseconds = run.Timings[math.ceil(#run.Timings * 0.95)],
		MeanProjectionIterations = run.TotalIterations / timedSteps,
		MaximumProjectionIterations = run.MaximumIterations,
		MaximumCourant = run.MaximumCourant,
		MaximumProjectionResidualRms = run.MaximumResidual,
		MaximumDivergenceAfter = run.MaximumDivergenceAfter,
		OwnedBufferCount = count,
		OwnedBufferBytes = bytes,
		StateSHA256 = checksum(run.Simulation),
		FirstCloudWaterSecondsSampled = run.FirstCloudWaterSeconds,
		FirstVisibleCloudSecondsSampled = run.FirstVisibleCloudSeconds,
		Final = run.Simulation:GetDiagnostics(),
		SourceDiagnostics = if run.Manager then run.Manager:GetDiagnostics() else nil,
		EstimatedSimulationMillisecondsPerWallSecondAt1x = (meanCore + meanSources) / fixedDt,
	}
	table.insert(scenarios, scenario)
	print(
		string.format(
			"%s %s: core mean %.3f ms + source mean %.3f ms, combined median/p95 %.3f/%.3f ms, startup sources %.3f ms, buffers %d/%d bytes",
			run.Preset,
			run.Mode,
			meanCore,
			meanSources,
			scenario.MedianCombinedStepMilliseconds,
			scenario.P95CombinedStepMilliseconds,
			run.SourceInitializationMilliseconds,
			count,
			bytes
		)
	)
end
local comparisons = {}
for _, preset in presets do
	local frozen, legacy, seeded = nil, nil, nil
	for _, scenario in scenarios do
		if scenario.Preset == preset then
			if scenario.Mode == "FrozenPhase2" then
				frozen = scenario
			elseif scenario.Mode == "CurrentLegacy" then
				legacy = scenario
			else
				seeded = scenario
			end
		end
	end
	assert(frozen and legacy and seeded, "Every preset requires all three paired modes")
	assert(
		frozen.StateSHA256 == legacy.StateSHA256,
		"Core changes altered the legacy numerical trajectory under matched inputs"
	)
	table.insert(comparisons, {
		Preset = preset,
		LegacyTrajectoryByteIdentical = true,
		LegacyMeanRegressionPercent = (
			legacy.MeanCombinedStepMilliseconds / frozen.MeanCombinedStepMilliseconds - 1
		) * 100,
		SeededMeanDifferencePercent = (
			seeded.MeanCombinedStepMilliseconds / frozen.MeanCombinedStepMilliseconds - 1
		) * 100,
		SeededComparisonIncludesDifferentPhysicalSourceDistribution = true,
		AdditionalSeededBufferBytes = seeded.OwnedBufferBytes - legacy.OwnedBufferBytes,
	})
end
fs.writeDir("build")
assert(
	fingerprint(frozenPath) == frozenProductionFingerprint
		and fingerprint(".") == currentProductionFingerprint,
	"Production files changed during the paired benchmark; discard timings and rerun"
)
local outputPath = if quick
	then "build/phase25-benchmark-quick.json"
	else "build/phase25-benchmark.json"
fs.writeFile(
	outputPath,
	serde.encode("json", {
		Environment = "Lune native-host code generation; not Roblox Studio FPS",
		CostAccounting = {
			CoreStep = "Entire Simulation:Step, including source application when forcing is active",
			SourceScheduler = "Source descriptions, bounded noise compilation, target merge and successful source commit",
			CombinedStep = "CoreStep plus SourceScheduler; excludes diagnostic sampling, rendering and other game systems",
		},
		RobloxNativeDirectiveGainMeasured = false,
		SourceRevision = sourceRevision,
		WorkingTreeChanged = workingTreeChanged,
		FrozenBaselinePath = frozenPath,
		FrozenProductionSourceSHA256 = frozenProductionFingerprint,
		CurrentProductionSourceSHA256 = currentProductionFingerprint,
		BenchmarkSourceSHA256 = benchmarkFingerprint,
		FingerprintScope = {
			Production = "Lua modules under src/shared/Atmosphere and src/server/Simulation",
			Benchmark = "scripts/benchmark-seeded-clouds.luau and tests/RobloxModuleLoader.luau",
		},
		WarmupSteps = warmupSteps,
		TimedSteps = timedSteps,
		FixedDt = fixedDt,
		SimulatedSeconds = totalSteps * fixedDt,
		CloudDiagnosticSampleSeconds = 1,
		Configuration = configuration,
		SeededConfiguration = {
			Seed = 84219,
			InitialSourceCountsByPreset = { Laptop = 2, Full = 3 },
			BuildSamplesPerStepByPreset = { Laptop = 128, Full = 192 },
			AutoClouds = true,
			ManualSourceAtSeconds = 29.75,
		},
		Comparisons = comparisons,
		Scenarios = scenarios,
	}, true)
)
print("Saved " .. outputPath .. ". Host timings exclude rendering and other Roblox/game systems.")
