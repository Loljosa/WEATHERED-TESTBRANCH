--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Atmosphere = require(ReplicatedStorage.Shared.Atmosphere)
local SimulationController = require(script.Parent.Simulation.SimulationController)
local VoxelDebugRenderer = require(script.Parent.Debug.VoxelDebugRenderer)

local DEBUG_RENDER_INTERVAL = 0.5
local DIAGNOSTIC_INTERVAL = 10

print("[WEATHERED] Starting atmosphere engine", Atmosphere.GetVersion())

local state = SimulationController.Initialize()
local visibleVoxels = VoxelDebugRenderer.Render(state)
local renderAccumulator = 0
local diagnosticAccumulator = 0
local heartbeat: RBXScriptConnection? = nil

local function printDiagnostics()
	local diagnostics = SimulationController.GetDiagnostics()

	print(
		string.format(
			"[WEATHERED] t=%.1fs, qc_max=%.6f kg/kg, |w|_max=%.2f m/s, cloud cells=%d, visible=%d, dropped=%.2fs",
			diagnostics.Time,
			diagnostics.MaxCloudWater,
			diagnostics.MaxVerticalVelocity,
			diagnostics.CloudCells,
			visibleVoxels,
			SimulationController.GetDroppedTime()
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
