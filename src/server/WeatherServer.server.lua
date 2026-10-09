--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Atmosphere = require(ReplicatedStorage.Shared.Atmosphere)
local SimulationController = require(script.Parent.Simulation.SimulationController)
local PerformanceSettings = require(script.Parent.Simulation.PerformanceSettings)
local VoxelDebugRenderer = require(script.Parent.Debug.VoxelDebugRenderer)

local DIAGNOSTIC_INTERVAL = 10

print("[WEATHERED] Starting atmosphere engine", Atmosphere.GetVersion())

-- Rojo metadata exposes these Number attributes in Properties before Play.
-- Display/wind/moisture settings are startup-only; SimulationSpeed updates live.
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

local presetAttribute = script:GetAttribute("PerformancePreset")
local preset = if presetAttribute == nil then "Laptop" else presetAttribute
assert(typeof(preset) == "string", "PerformancePreset must be a string script attribute")
local performance = PerformanceSettings.Resolve(preset :: string)
local DEBUG_RENDER_INTERVAL = performance.DebugRenderInterval

local state = SimulationController.Initialize({
	BackgroundU = numericAttribute("BackgroundU", 2),
	BackgroundV = numericAttribute("BackgroundV", 1),
	ShearU = numericAttribute("ShearU", 0),
	ShearV = numericAttribute("ShearV", 0),
	BubbleRelativeHumidity = numericAttribute("BubbleRelativeHumidity", 0.999),
}, {
	CellSizeStuds = numericAttribute("CellSizeStuds", 12),
	CloudBottomStuds = numericAttribute("CloudBottomStuds", 24),
	SizeX = performance.SizeX,
	SizeY = performance.SizeY,
	SizeZ = performance.SizeZ,
	Dx = performance.Dx,
	Dy = performance.Dy,
	Dz = performance.Dz,
}, {
	MaxCatchUpSteps = performance.MaxCatchUpSteps,
	FrameBudgetMilliseconds = performance.FrameBudgetMilliseconds,
})
local simulationSpeed = readSimulationSpeed()
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
			"[WEATHERED] frame work=%.2fms steps=%d limit=%d budget=%.1fms reached=%s",
			diagnostics.LastAdvanceMilliseconds,
			diagnostics.LastAdvanceSteps,
			diagnostics.MaxCatchUpSteps,
			diagnostics.FrameBudgetMilliseconds,
			tostring(diagnostics.FrameBudgetReached)
		)
	)
end

heartbeat = RunService.Heartbeat:Connect(function(frameDt: number)
	local success, failure = pcall(function()
		SimulationController.Advance(frameDt, simulationSpeed)
		renderAccumulator += frameDt
		diagnosticAccumulator += frameDt

		if renderAccumulator >= DEBUG_RENDER_INTERVAL then
			renderAccumulator %= DEBUG_RENDER_INTERVAL
			visibleVoxels = VoxelDebugRenderer.Render(state)
		end

		if diagnosticAccumulator >= DIAGNOSTIC_INTERVAL then
			diagnosticAccumulator %= DIAGNOSTIC_INTERVAL
			printDiagnostics()
		end
	end)

	if not success then
		local connection = heartbeat
		if connection then
			connection:Disconnect()
		end
		speedChanged:Disconnect()
		warn("[WEATHERED] Atmosphere stopped after simulation/debug failure: " .. tostring(failure))
	end
end)
