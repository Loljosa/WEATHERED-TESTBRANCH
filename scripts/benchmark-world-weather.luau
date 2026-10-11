--!strict

-- Frozen Phase 2.5 local architecture versus the production Phase 2.6 world
-- architecture. These are different physical domains and resolutions. The rows
-- compare preset costs, not an isolated numerical-method speedup or Studio FPS.
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
			"Provide one frozen baseline path"
		)
		baselinePath = process.args[argIndex + 1]
		argIndex += 1
	elseif argument == "--laptop" or argument == "--full" then
		assert(selectedPreset == nil, "Select at most one preset")
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
	"Usage: lune run scripts/benchmark-world-weather.luau --baseline <frozen-phase25-repository> [--laptop|--full] [--quick]"
)
local frozenPath = baselinePath :: string
assert(
	fs.isFile(frozenPath .. "/src/shared/Atmosphere/Simulation.lua"),
	"Baseline must contain the frozen Phase 2.5 source"
)
local root, loadModule = createLoader("src/shared/Atmosphere")
local frozenRoot, loadFrozen = createLoader(frozenPath .. "/src/shared/Atmosphere")
local Coordinates = loadModule(root.World.WorldCoordinates)
local WeatherField = loadModule(root.World.WeatherField)
local WorldSources = loadModule(root.World.WorldCloudSources)
local Snapshot = loadModule(root.World.WeatherSnapshot)
local currentServer, loadCurrentServer = createLoader("src/server/Simulation", {
	game = {
		GetService = function(_self: any, name: string): any
			assert(name == "ReplicatedStorage")
			return { Shared = { Atmosphere = root } }
		end,
	},
})
local Coupling = loadCurrentServer(currentServer.AtmosphericCoupling)
local Frozen = loadFrozen(frozenRoot)
local FrozenGrid = loadFrozen(frozenRoot.Core.Grid3D)
local frozenServer, loadFrozenServer = createLoader(frozenPath .. "/src/server/Simulation", {
	game = {
		GetService = function(_self: any, name: string): any
			assert(name == "ReplicatedStorage")
			return { Shared = { Atmosphere = frozenRoot } }
		end,
	},
})
local FrozenPresets = loadFrozenServer(frozenServer.PerformanceSettings)
local FrozenSources = loadFrozenServer(frozenServer.CloudSourceManager)
assert(
	Frozen.FixedDt == WeatherField.FixedDt,
	"Compared architectures must use the same fixed timestep"
)
local FIXED_DT = WeatherField.FixedDt
local WARMUP_STEPS = 8
local TIMED_STEPS = if quick then 40 else 232
local seed = 84219

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

local function fingerprint(directory: string): string
	local paths = {}
	local function collect(relative: string)
		for _, name in fs.readDir(directory .. "/" .. relative) do
			local path = relative .. "/" .. name
			if fs.isDir(directory .. "/" .. path) then
				collect(path)
			elseif string.sub(path, -4) == ".lua" or string.sub(path, -5) == ".json" then
				table.insert(paths, path)
			end
		end
	end
	collect("src/shared/Atmosphere")
	collect("src/server")
	collect("src/client")
	table.sort(paths)
	local contents = {}
	for _, path in paths do
		table.insert(contents, path .. "\0" .. fs.readFile(directory .. "/" .. path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local function checksum(field: any): string
	local contents = {}
	for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
		table.insert(contents, name .. "\0" .. buffer.tostring(field.State.Fields[name]) .. "\0")
	end
	for _, name in { "U", "V", "W" } do
		table.insert(contents, name .. "\0" .. buffer.tostring(field.Faces[name]) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local function statistics(values: { number }): any
	assert(#values > 0, "No benchmark samples")
	local ordered = table.clone(values)
	table.sort(ordered)
	local total = 0
	for _, value in ordered do
		total += value
	end
	return {
		Samples = #ordered,
		MeanMilliseconds = total / #ordered,
		MedianMilliseconds = ordered[math.ceil(#ordered * 0.5)],
		P95Milliseconds = ordered[math.ceil(#ordered * 0.95)],
		MaximumMilliseconds = ordered[#ordered],
	}
end

local frozenFingerprint = fingerprint(frozenPath)
local productionFingerprint = fingerprint(".")
local benchmarkFingerprint = serde.hash(
	"sha256",
	"scripts/benchmark-world-weather.luau\0"
		.. fs.readFile("scripts/benchmark-world-weather.luau")
		.. "\0tests/RobloxModuleLoader.luau\0"
		.. fs.readFile("tests/RobloxModuleLoader.luau")
		.. "\0"
)
local revision = string.gsub(process.exec("git", { "rev-parse", "HEAD" }).stdout, "%s+$", "")
local dirty = process.exec("git", { "status", "--porcelain" }).stdout ~= ""
local runs = {}
local presets = if selectedPreset then { selectedPreset } else { "Laptop", "Full" }
for _, preset in presets do
	for _, mode in { "FrozenPhase25Local", "Phase26World" } do
		local started = os.clock()
		local field, manager, dimensions, physical, sourceSettings
		if mode == "FrozenPhase25Local" then
			local settings = FrozenPresets.Resolve(preset)
			local grid = FrozenGrid.new(
				settings.SizeX,
				settings.SizeY,
				settings.SizeZ,
				12,
				Vector3.new(-settings.SizeX * 6, 424, -settings.SizeZ * 6),
				{ Dx = settings.Dx, Dy = settings.Dy, Dz = settings.Dz }
			)
			field = Frozen.new(grid, { DisableBubble = true, BackgroundU = 8, BackgroundV = 2 })
			dimensions = { X = settings.SizeX, Y = settings.SizeY, Z = settings.SizeZ }
			physical = {
				X = settings.Dx * settings.SizeX,
				Y = settings.Dy * settings.SizeY,
				Z = settings.Dz * settings.SizeZ,
			}
			sourceSettings = {
				Seed = seed,
				InitialSourceCount = settings.InitialSourceCount,
				MaxInitialSources = settings.MaxInitialSources,
				BuildSamplesPerStep = settings.SourceBuildSamplesPerStep,
				AutoClouds = true,
			}
		else
			local full = preset == "Full"
			local coordinates = Coordinates.new()
			local coverage = WorldSources.GetCoverage("Scattered", full)
			field = WeatherField.new(coordinates, {
				SizeX = if full then 48 else 32,
				SizeY = 6,
				SizeZ = if full then 48 else 32,
				BackgroundU = 8,
				BackgroundV = 2,
				ShearU = 0,
				ShearV = 0,
				BackgroundRelativeHumidity = coverage.EnvironmentalRH,
			})
			dimensions = { X = field.SizeX, Y = field.SizeY, Z = field.SizeZ }
			physical = {
				X = coordinates.WidthMeters,
				Y = coordinates.HeightMeters,
				Z = coordinates.DepthMeters,
			}
			sourceSettings = {
				Seed = seed,
				Coverage = "Scattered",
				FullPreset = full,
				InitialSourceCount = coverage.InitialSourceCount,
				BuildSamplesPerStep = if full then 192 else 128,
				AutoClouds = true,
			}
		end
		local coreInit = (os.clock() - started) * 1000
		started = os.clock()
		manager = if mode == "FrozenPhase25Local"
			then FrozenSources.new(field, sourceSettings)
			else WorldSources.new(field, sourceSettings)
		manager:InitializeSources()
		local sourceInit = (os.clock() - started) * 1000
		assert(
			field:GetDiagnostics().QcSum == 0,
			"Benchmark initialization must not paint liquid cloud water"
		)
		local count, bytes = ownedBuffers({ field, manager })
		table.insert(runs, {
			Preset = preset,
			Mode = mode,
			Field = field,
			Manager = manager,
			Dimensions = dimensions,
			PhysicalExtentMeters = physical,
			CoreInitializationMilliseconds = coreInit,
			SourceInitializationMilliseconds = sourceInit,
			BufferCount = count,
			BufferBytes = bytes,
			CoreTimings = {},
			SourceTimings = {},
			CombinedTimings = {},
			MaximumCourant = 0,
			MaximumSubsteps = 1,
			MaximumDivergence = 0,
			MaximumProjectionResidual = 0,
			MaximumSourceSamples = 0,
			FirstVisibleCloudSeconds = nil,
			Snapshots = {},
		})
	end
end

for tick = 1, WARMUP_STEPS + TIMED_STEPS do
	for position = 1, #runs do
		local index = ((position + tick - 2) % #runs) + 1
		if tick % 2 == 0 then
			index = #runs + 1 - index
		end
		local run = runs[index]
		local field, manager = run.Field, run.Manager
		local started = os.clock()
		if tick == 120 then
			manager:QueueSource()
		end
		local forcing = manager:PrepareStep(tick, FIXED_DT)
		local sourceMilliseconds = (os.clock() - started) * 1000
		started = os.clock()
		field:Step(FIXED_DT, forcing)
		local coreMilliseconds = (os.clock() - started) * 1000
		started = os.clock()
		manager:CommitStep(tick)
		sourceMilliseconds += (os.clock() - started) * 1000
		if tick > WARMUP_STEPS then
			table.insert(run.CoreTimings, coreMilliseconds)
			table.insert(run.SourceTimings, sourceMilliseconds)
			table.insert(run.CombinedTimings, coreMilliseconds + sourceMilliseconds)
		end
		run.MaximumSourceSamples = math.max(run.MaximumSourceSamples, manager.SamplesLastStep)
		if run.Mode == "Phase26World" then
			run.MaximumCourant = math.max(run.MaximumCourant, field.MaxCourant)
			run.MaximumSubsteps = math.max(run.MaximumSubsteps, field.Substeps)
			run.MaximumDivergence = math.max(run.MaximumDivergence, field.DivergenceMax)
		else
			run.MaximumCourant =
				math.max(run.MaximumCourant, field.MomentumCourant, field.TransportCourant)
			run.MaximumProjectionResidual =
				math.max(run.MaximumProjectionResidual, field.Projection.Last.Residual)
			run.MaximumDivergence = math.max(run.MaximumDivergence, field.Projection.Last.AfterMax)
		end
		if tick % 4 == 0 or tick == WARMUP_STEPS + TIMED_STEPS then
			local diagnostics = field:GetDiagnostics()
			local cutoff = if run.Mode == "Phase26World" then 0.00001 else 0.00005
			if run.FirstVisibleCloudSeconds == nil and diagnostics.MaxCloudWater >= cutoff then
				run.FirstVisibleCloudSeconds = field.Time
			end
			if tick % 120 == 0 or tick == WARMUP_STEPS + TIMED_STEPS then
				table.insert(run.Snapshots, diagnostics)
			end
		end
	end
end

local summaries = {}
for _, run in runs do
	local field, manager = run.Field, run.Manager
	local count, bytes = ownedBuffers({ field, manager })
	assert(
		count == run.BufferCount and bytes == run.BufferBytes,
		"Owned simulation buffers grew during benchmark"
	)
	local summary = {
		Preset = run.Preset,
		Mode = run.Mode,
		FixedDtSeconds = FIXED_DT,
		SimulatedSeconds = field.Time,
		WorldSeed = seed,
		WindUMetersPerSecond = 8,
		WindVMetersPerSecond = 2,
		Dimensions = run.Dimensions,
		PhysicalExtentMeters = run.PhysicalExtentMeters,
		CoreInitializationMilliseconds = run.CoreInitializationMilliseconds,
		SourceInitializationMilliseconds = run.SourceInitializationMilliseconds,
		Core = statistics(run.CoreTimings),
		SourcesOutsideCore = statistics(run.SourceTimings),
		Combined = statistics(run.CombinedTimings),
		BufferCount = count,
		BufferBytes = bytes,
		MaximumCourant = run.MaximumCourant,
		MaximumSubsteps = run.MaximumSubsteps,
		MaximumDivergencePerSecond = run.MaximumDivergence,
		MaximumProjectionResidual = run.MaximumProjectionResidual,
		MaximumSourceSamplesPerStep = run.MaximumSourceSamples,
		FirstVisibleCloudSeconds = run.FirstVisibleCloudSeconds,
		DiagnosticLiquidThreshold = if run.Mode == "Phase26World" then 0.00001 else 0.00005,
		FinalStateSHA256 = checksum(field),
		Diagnostics = field:GetDiagnostics(),
		Sources = manager:GetDiagnostics(),
		Snapshots = run.Snapshots,
	}
	if run.Mode == "Phase26World" then
		local cap = if run.Preset == "Full" then 512 else 256
		local workspace = Snapshot.NewWorkspace(cap)
		local meta = {
			SizeX = field.SizeX,
			SizeY = field.SizeY,
			SizeZ = field.SizeZ,
			Seed = seed,
			Time = field.Time,
			WidthStuds = 4028,
			DepthStuds = 4028,
			StudsPerMeter = field.Coordinates.StudsPerMeter,
			MinXStuds = field.Coordinates.MinX,
			MinZStuds = field.Coordinates.MinZ,
			BottomYStuds = field.Coordinates.BottomStuds,
			LayerHeightStuds = field.Dy * field.Coordinates.StudsPerMeter,
		}
		local times = {}
		local payload = nil
		for _ = 1, 20 do
			local started = os.clock()
			payload = Snapshot.Encode(field.Fields, meta, workspace, 0.00001, field.ValueBytes)
			table.insert(times, (os.clock() - started) * 1000)
		end
		local decoded = Snapshot.Decode(payload :: buffer)
		summary.SnapshotEncoding = statistics(times)
		summary.SnapshotBytes = buffer.len(payload :: buffer)
		summary.SnapshotMaximumBytes = 104 + 18 * cap
		summary.SnapshotRecords = decoded.Count
		summary.SnapshotAboveThreshold = decoded.AboveThreshold
		summary.NetworkMaximumBytesPerSecondBeforeProtocolOverhead = (104 + 18 * cap)
			* (if run.Preset == "Full" then 2 else 1)
		summary.TransportScalarUpdatesPerSubstep = field.Count * 4
		summary.MicrophysicsCallsPerSubstep = field.Count
		summary.LocalDetailEnabledDuringWorldTiming = false
		-- Profile the optional shadow separately after the world-only timing. The
		-- source manager and global field still advance normally. Only the adapter
		-- duration is recorded here; it cannot change the just-committed world.
		local shadow = Coupling.new(field, { Preset = run.Preset })
		local beforeActivation = checksum(field)
		local started = os.clock()
		shadow:SetEnabled(true, 6)
		local activationMilliseconds = (os.clock() - started) * 1000
		assert(
			checksum(field) == beforeActivation,
			"Activating local detail changed authoritative world buffers"
		)
		local shadowTimes = {}
		local maximumShadowSamples = 0
		local shadowWorldStart = field.Time
		for _ = 1, (if quick then 16 else 64) do
			local nextTick = field.Tick + 1
			local forcing = manager:PrepareStep(nextTick, FIXED_DT)
			field:Step(FIXED_DT, forcing)
			manager:CommitStep(nextTick)
			local beforeAdapter = checksum(field)
			local beforeTime, beforeTick = field.Time, field.Tick
			started = os.clock()
			local advanced = shadow:Advance(field.Tick)
			local milliseconds = (os.clock() - started) * 1000
			assert(
				checksum(field) == beforeAdapter
					and field.Time == beforeTime
					and field.Tick == beforeTick,
				"Local coupling changed authoritative world state or timeline"
			)
			maximumShadowSamples = math.max(maximumShadowSamples, shadow.SamplesLastStep)
			if advanced then
				table.insert(shadowTimes, milliseconds)
			end
			assert(
				shadow.Enabled and shadow.LastFailure == nil,
				"Optional local MAC benchmark failed"
			)
		end
		summary.LocalDetail = {
			Mode = "Optional one-way diagnostic MAC; no global feedback",
			ActivationMilliseconds = activationMilliseconds,
			WorldStartSeconds = shadowWorldStart,
			WorldEndSeconds = field.Time,
			Adapter = statistics(shadowTimes),
			MaximumSamplesPerLocalStep = maximumShadowSamples,
			Diagnostics = shadow:GetDiagnostics(),
			AuthoritativeWorldUnchangedByEachAdapterCall = true,
		}
	end
	table.insert(summaries, summary)
	print(
		string.format(
			"%s %s: combined %.3f ms mean / %.3f p95; core %.3f; sources %.3f; buffers %d bytes",
			run.Preset,
			run.Mode,
			summary.Combined.MeanMilliseconds,
			summary.Combined.P95Milliseconds,
			summary.Core.MeanMilliseconds,
			summary.SourcesOutsideCore.MeanMilliseconds,
			bytes
		)
	)
end
assert(
	fingerprint(".") == productionFingerprint,
	"Production source changed during benchmark; rerun on a stable tree"
)
assert(fingerprint(frozenPath) == frozenFingerprint, "Frozen baseline changed during benchmark")
local report = {
	Schema = 1,
	Mode = if quick then "quick" else "full",
	Description = "Preset architecture costs: frozen Phase 2.5 local MAC versus Phase 2.6 coarse world; different domains and source distributions",
	Timing = "Lune host elapsed os.clock milliseconds with production-module codegen; not Studio FPS or a Roblox native-directive speedup measurement",
	CoreIncludesSourceApplication = true,
	SourcesOutsideCoreIncludes = "PrepareStep plus CommitStep; source description, bounded noise construction and merged targets",
	SourceRevision = revision,
	WorkingTreeChanged = dirty,
	FrozenBaseline = frozenPath,
	FrozenBaselineCommit = "f18c4b4014e36932470f2cabbbf6980d1c71d0ce",
	FrozenProductionSourceSHA256 = frozenFingerprint,
	ProductionSourceSHA256 = productionFingerprint,
	ProductionFingerprintScope = {
		"src/shared/Atmosphere/**/*.lua|json",
		"src/server/**/*.lua|json",
		"src/client/**/*.lua|json",
	},
	BenchmarkSourceSHA256 = benchmarkFingerprint,
	WarmupSteps = WARMUP_STEPS,
	TimedSteps = TIMED_STEPS,
	RobloxStudioTested = false,
	Scenarios = summaries,
}
if not fs.isDir("build") then
	fs.writeDir("build")
end
local output = if quick
	then "build/phase26-world-benchmark-quick.json"
	else "build/phase26-world-benchmark.json"
fs.writeFile(output, serde.encode("json", report, true))
print("Report: " .. output)
