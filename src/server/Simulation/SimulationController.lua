--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere
local Atmosphere = require(AtmosphereRoot)
local Grid3D = require(AtmosphereRoot.Core.Grid3D)
local AtmosphereState = require(AtmosphereRoot.Core.AtmosphereState)

local SimulationController = {}

export type DisplayOptions = {
	CellSizeStuds: number?,
	CloudBottomStuds: number?, -- Roblox Y coordinate of the model's bottom wall.
}

-- Simulation seconds, independent of Roblox's Heartbeat frequency and preview speed.
local FIXED_DT = Atmosphere.FixedDt
local MAX_CATCH_UP_STEPS = 8
local BACKLOG_WARNING_INTERVAL = 5
local MINIMUM_SPEED = 0.25
local MAXIMUM_SPEED = 4

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function createGrid(display: DisplayOptions?): Grid3D.Grid3D
	local settings = display or {}
	local cellSize = settings.CellSizeStuds or 12
	local bottom = settings.CloudBottomStuds or 24
	assert(finite(cellSize) and cellSize > 0, "CellSizeStuds must be finite and positive")
	assert(finite(bottom), "CloudBottomStuds must be finite")
	return Grid3D.new(24, 12, 24, cellSize, Vector3.new(-12 * cellSize, bottom, -12 * cellSize), {
		Dx = 100,
		Dy = 100,
		Dz = 100, -- physical meters; CellSize/Origin above remain display studs.
	})
end

local grid = createGrid(nil)
local simulation: Atmosphere.Simulation? = nil
local accumulator = 0
local wallTime = 0
local droppedTime = 0
local nextBacklogWarning = 0
local simulationSpeed = 1

SimulationController.FixedDt = FIXED_DT
SimulationController.MaxCatchUpSteps = MAX_CATCH_UP_STEPS
SimulationController.MinimumSpeed = MINIMUM_SPEED
SimulationController.MaximumSpeed = MAXIMUM_SPEED

function SimulationController.ValidateSpeed(speed: number): number
	assert(
		finite(speed) and speed >= MINIMUM_SPEED and speed <= MAXIMUM_SPEED,
		"SimulationSpeed must be a finite number from 0.25 to 4"
	)
	return speed
end

local function getSimulation(
	config: Atmosphere.Config?,
	display: DisplayOptions?
): Atmosphere.Simulation
	local existing = simulation
	if existing then
		return existing
	end
	local selectedGrid = if display then createGrid(display) else grid
	local created = Atmosphere.new(selectedGrid, config)
	grid = selectedGrid
	simulation = created
	print(
		string.format(
			"[WEATHERED] 3D atmosphere initialized: %dx%dx%d (%d cells), fixed dt=%.2fs, spacing=%.0f/%.0f/%.0fm, debug cubes=%.1fstuds, bottom=%.1fstuds",
			grid.SizeX,
			grid.SizeY,
			grid.SizeZ,
			grid.Count,
			FIXED_DT,
			grid.Dx,
			grid.Dy,
			grid.Dz,
			grid.CellSize,
			grid.Origin.Y
		)
	)
	return created
end

function SimulationController.Initialize(
	config: Atmosphere.Config?,
	display: DisplayOptions?
): AtmosphereState.AtmosphereState
	return getSimulation(config, display).State
end

-- Speed changes the number of fixed physical steps, never their size.
-- Throws on invalid input or failed physics; the bootstrap stops Heartbeat on failure.
function SimulationController.Advance(frameDt: number, speed: number?): number
	assert(finite(frameDt) and frameDt >= 0, "Invalid atmosphere frame dt")
	local selectedSpeed = SimulationController.ValidateSpeed(speed or 1)
	local nextAccumulator = accumulator + frameDt * selectedSpeed
	local nextWallTime = wallTime + frameDt
	assert(finite(nextAccumulator) and finite(nextWallTime), "Atmosphere accumulator overflowed")
	local active = getSimulation(nil, nil)

	simulationSpeed = selectedSpeed
	wallTime = nextWallTime
	accumulator = nextAccumulator

	local steps = 0
	while accumulator >= FIXED_DT and steps < MAX_CATCH_UP_STEPS do
		active:Step(FIXED_DT)
		accumulator -= FIXED_DT
		steps += 1
	end

	if accumulator >= FIXED_DT then
		-- Keep the physical-time remainder; a stalled preview slows after bounded catch-up.
		local remainder = math.fmod(accumulator, FIXED_DT)
		local dropped = accumulator - remainder
		local nextDroppedTime = droppedTime + dropped
		assert(
			finite(remainder) and finite(nextDroppedTime),
			"Atmosphere backlog accounting overflowed"
		)
		accumulator = remainder
		droppedTime = nextDroppedTime

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
	return getSimulation(nil, nil).State
end

function SimulationController.GetGrid(): Grid3D.Grid3D
	return grid
end

function SimulationController.GetTime(): number
	return getSimulation(nil, nil).Time
end

function SimulationController.GetDiagnostics()
	local diagnostics =
		getSimulation(nil, nil):GetDiagnostics() :: Atmosphere.Diagnostics & { DroppedSimulationTime: number, SimulationSpeed: number }
	diagnostics.DroppedSimulationTime = droppedTime
	diagnostics.SimulationSpeed = simulationSpeed
	return diagnostics
end

function SimulationController.GetDroppedTime(): number
	return droppedTime
end

return SimulationController
