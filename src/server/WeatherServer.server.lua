--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Atmosphere = require(ReplicatedStorage.Shared.Atmosphere)
local SimulationController = require(script.Parent.Simulation.SimulationController)
local VoxelDebugRenderer = require(script.Parent.Debug.VoxelDebugRenderer)

local DEBUG_RENDER_INTERVAL = 0.5
local DIAGNOSTIC_INTERVAL = 10

print("[WEATHERED] Starting atmosphere engine", Atmosphere.GetVersion())

-- Read configuration once at startup; no Instance lookups inside physics loops.
local function numericAttribute(name: string): number
	local value = script:GetAttribute(name)
	if value == nil then
		return 0
	end
	assert(typeof(value) == "number", name .. " must be a numeric script attribute")
	return value :: number
end

local state = SimulationController.Initialize({
	BackgroundU = numericAttribute("BackgroundU"),
	BackgroundV = numericAttribute("BackgroundV"),
	ShearU = numericAttribute("ShearU"),
	ShearV = numericAttribute("ShearV"),
})
local visibleVoxels = VoxelDebugRenderer.Render(state)
local renderAccumulator = 0
local diagnosticAccumulator = 0
local heartbeat: RBXScriptConnection? = nil

local function printDiagnostics()
	local diagnostics = SimulationController.GetDiagnostics()

	print(
		string.format(
			"[WEATHERED] t=%.1fs qc_max=%.6f cloud=%d visible=%d; u[%.2f,%.2f] v[%.2f,%.2f] w[%.2f,%.2f]m/s; CFL=%.4f step=%.2fms dropped=%.2fs",
			diagnostics.Time,
			diagnostics.MaxCloudWater,
			diagnostics.CloudCells,
			visibleVoxels,
			diagnostics.MinU,
			diagnostics.MaxU,
			diagnostics.MinV,
			diagnostics.MaxV,
			diagnostics.MinW,
			diagnostics.MaxW,
			diagnostics.MaxCourant,
			diagnostics.StepMilliseconds,
			diagnostics.DroppedSimulationTime
		)
	)
	print(
		string.format(
			"[WEATHERED] div_rms %.3g -> %.3g/s (max %.3g -> %.3g); PCG=%d residual=%.3g/s; unweighted qv/qc/qr sums=%.9g/%.9g/%.9g drift=%+.6f%%; qc centroid=(%.1f,%.1f,%.1f)m defined=%s",
			diagnostics.DivergenceBeforeRms,
			diagnostics.DivergenceAfterRms,
			diagnostics.DivergenceBeforeMax,
			diagnostics.DivergenceAfterMax,
			diagnostics.ProjectionIterations,
			diagnostics.ProjectionResidual,
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
end

heartbeat = RunService.Heartbeat:Connect(function(frameDt: number)
	local success, failure = pcall(function()
		SimulationController.Advance(frameDt)
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
		warn("[WEATHERED] Atmosphere stopped after simulation/debug failure: " .. tostring(failure))
	end
end)
