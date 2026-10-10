--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Atmosphere = require(ReplicatedStorage.Shared.Atmosphere)
local SimulationController = require(script.Parent.Simulation.SimulationController)
local PerformanceSettings = require(script.Parent.Simulation.PerformanceSettings)
local CloudControls = require(script.Parent.Simulation.CloudControls)
local VoxelDebugRenderer = require(script.Parent.Debug.VoxelDebugRenderer)
local WorldSeed = require(ReplicatedStorage.Shared.Atmosphere.Generation.WorldSeed)

local DIAGNOSTIC_INTERVAL = 10

print("[WEATHERED] Starting atmosphere engine", Atmosphere.GetVersion())

-- Rojo metadata exposes these Number attributes in Properties before Play.
-- Attributes set the startup sounding; commands also expose safe live controls.
local function numericAttribute(name: string, default: number): number
	local value = script:GetAttribute(name)
	if value == nil then
		return default
	end
	assert(typeof(value) == "number", name .. " must be a numeric script attribute")
	local numberValue = value :: number
	assert(
		numberValue == numberValue and math.abs(numberValue) < math.huge,
		name .. " must be finite"
	)
	return numberValue
end

local function readSimulationSpeed(): number
	return SimulationController.ValidateSpeed(numericAttribute("SimulationSpeed", 1))
end

local function booleanAttribute(name: string, default: boolean): boolean
	local value = script:GetAttribute(name)
	if value == nil then
		return default
	end
	assert(typeof(value) == "boolean", name .. " must be a boolean script attribute")
	return value :: boolean
end

local presetAttribute = script:GetAttribute("PerformancePreset")
local preset = if presetAttribute == nil then "Laptop" else presetAttribute
assert(typeof(preset) == "string", "PerformancePreset must be a string script attribute")
local performance = PerformanceSettings.Resolve(preset :: string)
local DEBUG_RENDER_INTERVAL = performance.DebugRenderInterval

-- Canonical world generation may publish Workspace.WorldSeed before bootstrap.
-- This repository has no terrain generator. The development Script attribute
-- is a deterministic fallback; no clock or unseeded RNG is involved.
local hasWorkspaceAdapter, canonicalSeed = pcall(function(): any
	return game:GetService("Workspace"):GetAttribute("WorldSeed")
end)
local developmentSeed = if not hasWorkspaceAdapter or canonicalSeed == nil
	then numericAttribute("WorldSeed", 84219)
	else nil
local worldSeed, seedSource =
	WorldSeed.Resolve(if hasWorkspaceAdapter then canonicalSeed else nil, developmentSeed)
local requestedSources = numericAttribute("CloudSourceCount", 0)
assert(
	requestedSources % 1 == 0,
	"CloudSourceCount must be an integer; 0 selects the preset default"
)
local initialSourceCount = if requestedSources == 0
	then performance.InitialSourceCount
	else requestedSources
local sourceIntensity = numericAttribute("SourceIntensity", 1)
assert(sourceIntensity >= 0 and sourceIntensity <= 1, "SourceIntensity must be 0..1")
assert(
	initialSourceCount >= 1 and initialSourceCount <= performance.MaxInitialSources,
	"CloudSourceCount is outside the selected performance preset's source limit"
)
local physicalRegion = {
	OriginX = numericAttribute(
		"WorldRegionOriginXMeters",
		-performance.SizeX * performance.Dx * 0.5
	),
	OriginY = numericAttribute("WorldRegionOriginYMeters", 0),
	OriginZ = numericAttribute(
		"WorldRegionOriginZMeters",
		-performance.SizeZ * performance.Dz * 0.5
	),
	SizeX = performance.SizeX * performance.Dx,
	SizeY = performance.SizeY * performance.Dy,
	SizeZ = performance.SizeZ * performance.Dz,
	Dx = performance.Dx,
	Dy = performance.Dy,
	Dz = performance.Dz,
}
local generation: SimulationController.GenerationOptions = {
	Seed = worldSeed,
	SeedSource = seedSource,
	InitialSourceCount = initialSourceCount,
	MaxInitialSources = performance.MaxInitialSources,
	SourceIntensity = sourceIntensity,
	AutoClouds = booleanAttribute("AutoClouds", true),
	BuildSamplesPerStep = performance.SourceBuildSamplesPerStep,
	Region = physicalRegion,
}

local shapeAttribute = script:GetAttribute("CloudShape")
local cloudShape = if shapeAttribute == nil then "Round" else shapeAttribute
assert(typeof(cloudShape) == "string", "CloudShape must be Round, Wide or Tower")
local initialConfig: Atmosphere.Config = {
	BackgroundU = numericAttribute("BackgroundU", 2),
	BackgroundV = numericAttribute("BackgroundV", 1),
	ShearU = numericAttribute("ShearU", 0),
	ShearV = numericAttribute("ShearV", 0),
	BubbleRelativeHumidity = numericAttribute("BubbleRelativeHumidity", 0.999),
	BubbleTemperaturePerturbation = numericAttribute("BubbleTemperaturePerturbation", 6),
	BubbleShape = cloudShape :: string,
	BubbleScale = numericAttribute("CloudScale", 1),
}
local state = SimulationController.Initialize(initialConfig, {
	CellSizeStuds = numericAttribute("CellSizeStuds", 12),
	CloudBottomStuds = numericAttribute("CloudBottomStuds", 424),
	SizeX = performance.SizeX,
	SizeY = performance.SizeY,
	SizeZ = performance.SizeZ,
	Dx = performance.Dx,
	Dy = performance.Dy,
	Dz = performance.Dz,
}, {
	MaxCatchUpSteps = performance.MaxCatchUpSteps,
	FrameBudgetMilliseconds = performance.FrameBudgetMilliseconds,
}, generation)
local simulationSpeed = readSimulationSpeed()
local controls = CloudControls.new(initialConfig, function(value: number)
	simulationSpeed = value
	script:SetAttribute("SimulationSpeed", value)
end, function(config: Atmosphere.Config)
	script:SetAttribute("BackgroundU", config.BackgroundU)
	script:SetAttribute("BackgroundV", config.BackgroundV)
	script:SetAttribute("BubbleRelativeHumidity", config.BubbleRelativeHumidity)
	script:SetAttribute("BubbleTemperaturePerturbation", config.BubbleTemperaturePerturbation)
	script:SetAttribute("CloudShape", config.BubbleShape or "Round")
	script:SetAttribute("CloudScale", config.BubbleScale or 1)
end, generation)
print(
	string.format(
		"[WEATHERED] Seeded generation: world seed %d (%s), %d initial sources; physical origin=(%.0f,%.0f,%.0f)m, scheduled sources=%s",
		worldSeed,
		seedSource,
		initialSourceCount,
		physicalRegion.OriginX,
		physicalRegion.OriginY,
		physicalRegion.OriginZ,
		tostring(generation.AutoClouds)
	)
)
print(
	string.format(
		"[WEATHERED] PerformancePreset=%s; catch-up <=%d steps/Heartbeat, soft budget=%.0fms; debug %.1fHz",
		preset :: string,
		performance.MaxCatchUpSteps,
		performance.FrameBudgetMilliseconds,
		1 / DEBUG_RENDER_INTERVAL
	)
)
local visibleVoxels = VoxelDebugRenderer.Render(state)
local renderAccumulator = 0
local diagnosticAccumulator = 0
local heartbeat: RBXScriptConnection? = nil
local commandChanged: RBXScriptConnection? = nil
local existingEndpoint = script:FindFirstChild("WeatherControls")
assert(
	existingEndpoint == nil or existingEndpoint:IsA("BindableFunction"),
	"WeatherControls name is occupied"
)
local commandEndpoint = (existingEndpoint or Instance.new("BindableFunction")) :: BindableFunction
commandEndpoint.Name = "WeatherControls"
commandEndpoint.Parent = script -- server-only developer endpoint, never a client remote.
local running = true

local speedChanged = script:GetAttributeChangedSignal("SimulationSpeed"):Connect(function()
	local success, result = pcall(readSimulationSpeed)
	if success then
		simulationSpeed = result :: number
		print(
			string.format(
				"[WEATHERED] SimulationSpeed=%.2fx; physical dt remains %.2fs",
				simulationSpeed,
				SimulationController.FixedDt
			)
		)
	else
		warn("[WEATHERED] Invalid SimulationSpeed; retaining previous value: " .. tostring(result))
	end
end)

local function printDiagnostics()
	local diagnostics = SimulationController.GetDiagnostics()

	print(
		string.format(
			"[WEATHERED] t=%.1fs speed=%.2fx qc_max=%.6fkg/kg cloud=%d visible=%d; u[%.2f,%.2f] v[%.2f,%.2f] w[%.2f,%.2f]m/s; momentum stability=%.4f scalar outgoing CFL=%.4f last-step=%.2fms dropped=%.2fs",
			diagnostics.Time,
			diagnostics.SimulationSpeed,
			diagnostics.MaxCloudWater,
			diagnostics.CloudCells,
			visibleVoxels,
			diagnostics.MinU,
			diagnostics.MaxU,
			diagnostics.MinV,
			diagnostics.MaxV,
			diagnostics.MinW,
			diagnostics.MaxW,
			diagnostics.MomentumCourant,
			diagnostics.TransportCourant,
			diagnostics.StepMilliseconds,
			diagnostics.DroppedSimulationTime
		)
	)
	print(
		string.format(
			"[WEATHERED] div_rms %.3g -> %.3g/s (max %.3g -> %.3g); PCG=%d residual RMS/max=%.3g/%.3g/s target=%.3g/s float32 tolerance=%.3g/s converged=%s; unweighted qv/qc/qr sums=%.9g/%.9g/%.9g drift=%+.6f%%; qc centroid=(%.1f,%.1f,%.1f)m defined=%s",
			diagnostics.DivergenceBeforeRms,
			diagnostics.DivergenceAfterRms,
			diagnostics.DivergenceBeforeMax,
			diagnostics.DivergenceAfterMax,
			diagnostics.ProjectionIterations,
			diagnostics.ProjectionResidual,
			diagnostics.ProjectionResidualMax,
			diagnostics.ProjectionTolerance,
			diagnostics.ProjectionPostTolerance,
			tostring(diagnostics.ProjectionConverged),
			diagnostics.QvSum,
			diagnostics.QcSum,
			diagnostics.QrSum,
			diagnostics.WaterDriftFraction * 100,
			diagnostics.CloudCentroidX,
			diagnostics.CloudCentroidY,
			diagnostics.CloudCentroidZ,
			tostring(diagnostics.CloudCentroidDefined)
		)
	)
	print(
		string.format(
			"[WEATHERED] frame work=%.2fms steps=%d limit=%d budget=%.1fms reached=%s paused=%s formation remaining=%.2fs requested speed=%.2fx",
			diagnostics.LastAdvanceMilliseconds,
			diagnostics.LastAdvanceSteps,
			diagnostics.MaxCatchUpSteps,
			diagnostics.FrameBudgetMilliseconds,
			tostring(diagnostics.FrameBudgetReached),
			tostring(diagnostics.Paused),
			diagnostics.FormationRemainingSeconds,
			diagnostics.RequestedSpeed
		)
	)
	print(
		string.format(
			"[WEATHERED] qc centroid interval delta=(%.2f,%.2f,%.2f)m = (%.2f,%.2f,%.2f)studs over %.2f simulated seconds, defined=%s; global centroid includes growth/merging, not a tracked parcel",
			diagnostics.CloudCentroidDeltaXMeters,
			diagnostics.CloudCentroidDeltaYMeters,
			diagnostics.CloudCentroidDeltaZMeters,
			diagnostics.CloudCentroidDeltaXStuds,
			diagnostics.CloudCentroidDeltaYStuds,
			diagnostics.CloudCentroidDeltaZStuds,
			diagnostics.CloudCentroidDeltaSeconds,
			tostring(diagnostics.CloudMovementDefined)
		)
	)
	if (diagnostics :: any).SeededGeneration then
		local sources = diagnostics :: any
		print(
			string.format(
				"[WEATHERED] seed=%d tick=%d initial=%d auto=%s sources pending/building/active=%d/%d/%d; opportunities=%d scheduled=%d manual=%d samples=%d (total %d); budget exhausted=%s; external qwater sum=%+.9g theta-cell input=%+.9gK enthalpy-cell input=%+.9gJ/kg; raw water change=%+.6f%%",
				sources.WorldSeed,
				sources.SourceTick,
				sources.InitialSourceCount,
				tostring(sources.AutoClouds),
				sources.PendingSources,
				sources.BuildingSources,
				sources.ActiveSources,
				sources.ScheduledOpportunities,
				sources.ScheduledSources,
				sources.ManualSources,
				sources.SourceSamplesLastStep,
				sources.SourceSamplesTotal,
				tostring(sources.SourceBudgetExhausted),
				diagnostics.ExternalWaterSum,
				diagnostics.ExternalThetaSum,
				diagnostics.ExternalEnthalpySum,
				diagnostics.RawWaterChangeFraction * 100
			)
		)
	end
end

local function printCommandResult(result: any)
	if type(result) ~= "table" then
		print("[WEATHERED] " .. tostring(result))
		return
	end
	if result.NextWorldSeed ~= nil then
		print(
			string.format(
				"[WEATHERED] active seeded=%s seed=%s source=%s; next seed=%d (%s), sources=%d/%d, intensity=%.2f, auto=%s; scheduler tick=%d pending/building/active=%d/%d/%d; last source=%s",
				tostring(result.SeededGeneration),
				tostring(result.WorldSeed),
				tostring(result.SeedSource),
				result.NextWorldSeed,
				result.NextSeedSource,
				result.NextInitialSourceCount,
				result.MaximumInitialSourceCount,
				result.NextSourceIntensity,
				tostring(result.NextAutoClouds),
				result.SourceTick or 0,
				result.PendingSources or 0,
				result.BuildingSources or 0,
				result.ActiveSources or 0,
				tostring(result.LastSourceId)
			)
		)
		if result.SeededGeneration then
			print(
				string.format(
					"[WEATHERED] physical source region origin=(%.0f,%.0f,%.0f)m extent=(%.0f,%.0f,%.0f)m; formation opportunity every %d ticks, probability %.2f, duration %.2fs; source geometry budget=%d samples/step; water/theta budgets remaining=%.9g/%.9g",
					result.SourceRegionOriginXMeters,
					result.SourceRegionOriginYMeters,
					result.SourceRegionOriginZMeters,
					result.SourceRegionSizeXMeters,
					result.SourceRegionSizeYMeters,
					result.SourceRegionSizeZMeters,
					result.SourceFormationIntervalTicks,
					result.SourceFormationProbability,
					result.SourceFormationDurationSeconds,
					result.SourceBuildSamplesPerStep,
					result.SourceWaterBudgetRemaining,
					result.SourceThetaBudgetRemaining
				)
			)
			-- Source descriptions are diagnostic metadata, not rendered qc. Limit
			-- this list to explicit seedstatus requests rather than normal logging.
			local initialSources = result.InitialCloudSources or {}
			for index = 1, math.min(#initialSources, 6) do
				local source = initialSources[index]
				print(
					string.format(
						"[WEATHERED] source %s %s center=(%.0f,%.0f,%.0f)m radii=(%.0f,%.0f,%.0f)m altitude=%.0f..%.0fm theta excess=%.2fK RH=%.5f intensity=%.3f generation tick=%d",
						source.Id,
						source.Kind,
						source.X,
						source.Y,
						source.Z,
						source.RadiusX,
						source.RadiusY,
						source.RadiusZ,
						source.BaseAltitude,
						source.TopAltitude,
						source.TemperaturePerturbation,
						source.TargetRelativeHumidity,
						source.Intensity,
						source.GenerationTick
					)
				)
			end
		end
	else
		printDiagnostics()
	end
end

commandEndpoint.OnInvoke = function(command: string, ...: any): any
	assert(running, "Atmosphere stopped; restart the Studio test")
	local result = controls:Execute(command, ...)
	printCommandResult(result)
	return result
end
commandChanged = script:GetAttributeChangedSignal("WeatherCommand"):Connect(function()
	local command = script:GetAttribute("WeatherCommand")
	if command == nil or command == "" then
		return
	end
	-- Clear the input so repeating the same command triggers another change.
	script:SetAttribute("WeatherCommand", "")
	local success, result = pcall(function()
		assert(running, "Atmosphere stopped; restart the Studio test")
		return controls:ExecuteText(command :: string)
	end)
	if success then
		printCommandResult(result)
		script:SetAttribute(
			"LastWeatherMessage",
			if type(result) == "table" then "Diagnostics printed in Output" else tostring(result)
		)
	else
		warn("[WEATHERED] Weather command rejected: " .. tostring(result))
		script:SetAttribute("LastWeatherMessage", tostring(result))
	end
end)
print(
	"[WEATHERED] Controls: set this Script's WeatherCommand attribute to help, seedstatus, spawnseeded, wind 8 2, regenerate, or form 60."
)

heartbeat = RunService.Heartbeat:Connect(function(frameDt: number)
	local success, failure = pcall(function()
		SimulationController.Advance(frameDt, simulationSpeed)
		renderAccumulator += frameDt
		diagnosticAccumulator += frameDt

		if renderAccumulator >= DEBUG_RENDER_INTERVAL then
			renderAccumulator %= DEBUG_RENDER_INTERVAL
			visibleVoxels = VoxelDebugRenderer.Render(SimulationController.GetState())
		end

		if diagnosticAccumulator >= DIAGNOSTIC_INTERVAL then
			diagnosticAccumulator %= DIAGNOSTIC_INTERVAL
			printDiagnostics()
		end
	end)

	if not success then
		running = false
		local connection = heartbeat
		if connection then
			connection:Disconnect()
		end
		speedChanged:Disconnect()
		if commandChanged then
			commandChanged:Disconnect()
		end
		warn("[WEATHERED] Atmosphere stopped after simulation/debug failure: " .. tostring(failure))
	end
end)
