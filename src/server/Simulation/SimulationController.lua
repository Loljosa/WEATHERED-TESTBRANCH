--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere
local Atmosphere = require(AtmosphereRoot)
local Grid3D = require(AtmosphereRoot.Core.Grid3D)
local AtmosphereState = require(AtmosphereRoot.Core.AtmosphereState)

local SimulationController = {}

-- Simulation seconds, independent of Roblox's Heartbeat frequency.
local FIXED_DT = Atmosphere.FixedDt
local MAX_CATCH_UP_STEPS = 8
local BACKLOG_WARNING_INTERVAL = 5

local grid = Grid3D.new(24, 12, 24, 64, Vector3.new(-768, 128, -768))
local simulation = Atmosphere.new(grid)
local initialized = false
local accumulator = 0
local wallTime = 0
local droppedTime = 0
local nextBacklogWarning = 0

SimulationController.FixedDt = FIXED_DT
SimulationController.MaxCatchUpSteps = MAX_CATCH_UP_STEPS

function SimulationController.Initialize(): AtmosphereState.AtmosphereState
	if not initialized then
		initialized = true
		print(
			string.format(
				"[WEATHERED] Warm-cloud atmosphere initialized: %dx%dx%d (%d cells), dt=%.2fs",
				grid.SizeX,
				grid.SizeY,
				grid.SizeZ,
				grid.Count,
				FIXED_DT
			)
		)
	end

	return simulation.State
end

-- Throws on invalid input or failed physics. The bootstrap stops Heartbeat on failure.
function SimulationController.Advance(frameDt: number): number
	assert(
		frameDt == frameDt and frameDt < math.huge and frameDt >= 0,
		"Invalid atmosphere frame dt"
	)
	SimulationController.Initialize()

	wallTime += frameDt
	accumulator += frameDt

	local steps = 0
	while accumulator >= FIXED_DT and steps < MAX_CATCH_UP_STEPS do
		simulation:Step(FIXED_DT)
		accumulator -= FIXED_DT
		steps += 1
	end

	if accumulator >= FIXED_DT then
		-- Preserve the fractional remainder; intentionally slow simulation after a stall.
		local dropped = math.floor(accumulator / FIXED_DT) * FIXED_DT
		accumulator -= dropped
		droppedTime += dropped

		if wallTime >= nextBacklogWarning then
			warn(
				string.format(
					"[WEATHERED] Catch-up limit reached; dropped %.2fs of simulation backlog (total %.2fs)",
					dropped,
					droppedTime
				)
			)
			nextBacklogWarning = wallTime + BACKLOG_WARNING_INTERVAL
		end
	end

	return steps
end

function SimulationController.GetState(): AtmosphereState.AtmosphereState
	return simulation.State
end

function SimulationController.GetGrid(): Grid3D.Grid3D
	return grid
end

function SimulationController.GetTime(): number
	return simulation.Time
end

function SimulationController.GetDiagnostics()
	return simulation:GetDiagnostics()
end

function SimulationController.GetDroppedTime(): number
	return droppedTime
end

return SimulationController
