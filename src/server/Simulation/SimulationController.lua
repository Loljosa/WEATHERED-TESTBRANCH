--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere
local Atmosphere = require(AtmosphereRoot)
local Grid3D = require(AtmosphereRoot.Core.Grid3D)
local AtmosphereState = require(AtmosphereRoot.Core.AtmosphereState)
local CloudSourceManager = require(script.Parent.CloudSourceManager)

local SimulationController = {}

export type DisplayOptions = {
	CellSizeStuds: number?,
	CloudBottomStuds: number?, -- Roblox Y coordinate of the model's bottom wall.
	SizeX: number?,
	SizeY: number?,
	SizeZ: number?,
	Dx: number?, -- physical meters, independent of CellSizeStuds.
	Dy: number?,
	Dz: number?,
}

export type ExecutionOptions = {
	MaxCatchUpSteps: number?,
	FrameBudgetMilliseconds: number?, -- soft budget: a physical step cannot be interrupted.
	Clock: (() -> number)?, -- monotonic seconds; production uses os.clock.
}

export type GenerationOptions = CloudSourceManager.Settings & { SeedSource: string? }

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
	local bottom = settings.CloudBottomStuds or 424
	local sizeX, sizeY, sizeZ = settings.SizeX or 24, settings.SizeY or 12, settings.SizeZ or 24
	assert(finite(cellSize) and cellSize > 0, "CellSizeStuds must be finite and positive")
	assert(finite(bottom), "CloudBottomStuds must be finite")
	return Grid3D.new(
		sizeX,
		sizeY,
		sizeZ,
		cellSize,
		Vector3.new(-0.5 * sizeX * cellSize, bottom, -0.5 * sizeZ * cellSize),
		{
			Dx = settings.Dx or 100,
			Dy = settings.Dy or 100,
			Dz = settings.Dz or 100, -- physical meters; CellSize/Origin above remain display studs.
		}
	)
end

local grid = createGrid(nil)
local simulation: Atmosphere.Simulation? = nil
local accumulator = 0
local wallTime = 0
local droppedTime = 0
local nextBacklogWarning = 0
local simulationSpeed = 1
local maxCatchUpSteps = MAX_CATCH_UP_STEPS
local frameBudgetSeconds: number? = nil
local clock = os.clock
local lastAdvanceMilliseconds = 0
local lastAdvanceSteps = 0
local frameBudgetReached = false
local paused = false
local formationRemaining = 0 -- requested physical seconds; never fabricated state.
local requestedSpeed = 1
local sourceManager: CloudSourceManager.CloudSourceManager? = nil
local activeGeneration: GenerationOptions? = nil
local movementTime: number? = nil
local previousCentroidX, previousCentroidY, previousCentroidZ = 0, 0, 0
local previousCentroidDefined = false
local centroidDeltaX, centroidDeltaY, centroidDeltaZ, centroidDeltaSeconds = 0, 0, 0, 0
local centroidMovementDefined = false

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

local function clearMovementDiagnostics()
	movementTime = nil
	previousCentroidDefined, centroidMovementDefined = false, false
	centroidDeltaX, centroidDeltaY, centroidDeltaZ, centroidDeltaSeconds = 0, 0, 0, 0
end

-- Generation uses a physical world-region origin, independent of the display
-- Origin in studs. The default models a 2.4 km region centered at world X/Z=0.
local function createSimulation(
	selectedGrid: Grid3D.Grid3D,
	config: Atmosphere.Config?,
	generation: GenerationOptions?
): (Atmosphere.Simulation, CloudSourceManager.CloudSourceManager?)
	local settings = table.clone(config or {})
	if generation ~= nil then
		settings.DisableBubble = true
	end
	local created = Atmosphere.new(selectedGrid, settings)
	if generation == nil then
		return created, nil
	end
	local sourceSettings = table.clone(generation)
	if sourceSettings.Region == nil then
		sourceSettings.Region = {
			OriginX = -selectedGrid.SizeX * selectedGrid.Dx * 0.5,
			OriginY = 0,
			OriginZ = -selectedGrid.SizeZ * selectedGrid.Dz * 0.5,
			SizeX = selectedGrid.SizeX * selectedGrid.Dx,
			SizeY = selectedGrid.SizeY * selectedGrid.Dy,
			SizeZ = selectedGrid.SizeZ * selectedGrid.Dz,
			Dx = selectedGrid.Dx,
			Dy = selectedGrid.Dy,
			Dz = selectedGrid.Dz,
		}
	end
	local manager = CloudSourceManager.new(created, sourceSettings)
	manager:InitializeSources()
	return created, manager
end

local function getSimulation(
	config: Atmosphere.Config?,
	display: DisplayOptions?,
	execution: ExecutionOptions?,
	generation: GenerationOptions?
): Atmosphere.Simulation
	local existing = simulation
	if existing then
		return existing
	end
	local selectedGrid = if display then createGrid(display) else grid
	local options = execution or {}
	local selectedMaxSteps = options.MaxCatchUpSteps or MAX_CATCH_UP_STEPS
	assert(
		finite(selectedMaxSteps)
			and selectedMaxSteps % 1 == 0
			and selectedMaxSteps >= 1
			and selectedMaxSteps <= MAX_CATCH_UP_STEPS,
		"MaxCatchUpSteps must be an integer from 1 to 8"
	)
	local budget = options.FrameBudgetMilliseconds
	if budget ~= nil then
		assert(finite(budget) and budget > 0, "FrameBudgetMilliseconds must be finite and positive")
	end
	assert(options.Clock == nil or type(options.Clock) == "function", "Clock must be a function")
	local created, manager = createSimulation(selectedGrid, config, generation)
	grid = selectedGrid
	simulation = created
	sourceManager = manager
	activeGeneration = if generation then table.clone(generation) else nil
	clearMovementDiagnostics()
	maxCatchUpSteps = selectedMaxSteps
	frameBudgetSeconds = if budget then budget / 1000 else nil
	clock = options.Clock or os.clock
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
	display: DisplayOptions?,
	execution: ExecutionOptions?,
	generation: GenerationOptions?
): AtmosphereState.AtmosphereState
	return getSimulation(config, display, execution, generation).State
end

-- Construct first so a rejected sounding leaves the running simulation untouched.
-- Occasional developer resets allocate a new packed simulation, not per-step tables.
function SimulationController.Restart(
	config: Atmosphere.Config,
	generation: GenerationOptions?
): AtmosphereState.AtmosphereState
	local created, manager = createSimulation(grid, config, generation)
	simulation = created
	sourceManager = manager
	activeGeneration = if generation then table.clone(generation) else nil
	clearMovementDiagnostics()
	accumulator, wallTime, droppedTime, nextBacklogWarning = 0, 0, 0, 0
	lastAdvanceMilliseconds, lastAdvanceSteps = 0, 0
	frameBudgetReached, paused, formationRemaining = false, false, 0
	return created.State
end

function SimulationController.Regenerate(
	config: Atmosphere.Config,
	generation: GenerationOptions
): AtmosphereState.AtmosphereState
	return SimulationController.Restart(config, generation)
end

function SimulationController.SpawnSeeded(): string
	local manager = sourceManager
	assert(manager ~= nil, "Seeded generation is inactive; use regenerate first")
	return manager:QueueSource()
end

function SimulationController.SetAutoClouds(enabled: boolean)
	assert(type(enabled) == "boolean", "AutoClouds must be a boolean")
	local manager = sourceManager
	assert(manager ~= nil, "Seeded generation is inactive; use regenerate first")
	manager:SetAutoClouds(enabled)
	if activeGeneration then
		activeGeneration.AutoClouds = enabled
	end
end

function SimulationController.GetSeedStatus(): { [string]: any }
	local manager = sourceManager
	local result = if manager then manager:GetDiagnostics() else {}
	(result :: any).SeededGeneration = manager ~= nil
	(result :: any).SeedSource = if activeGeneration
		then activeGeneration.SeedSource or "Configured"
		else "LegacyBubble"
	if manager then
		local status = result :: any
		status.SourceRegionOriginXMeters = manager.Region.OriginX
		status.SourceRegionOriginYMeters = manager.Region.OriginY
		status.SourceRegionOriginZMeters = manager.Region.OriginZ
		status.SourceRegionSizeXMeters = manager.Region.SizeX
		status.SourceRegionSizeYMeters = manager.Region.SizeY
		status.SourceRegionSizeZMeters = manager.Region.SizeZ
		status.SourceFormationIntervalTicks = manager.Scheduler.IntervalTicks
		status.SourceFormationProbability = manager.Scheduler.FormationProbability
		status.SourceFormationDurationSeconds = manager.FormationDurationSeconds
		status.SourceBuildSamplesPerStep = manager.BuildSamplesPerStep
	end
	return result :: any
end

function SimulationController.SetWind(u: number, v: number)
	getSimulation(nil, nil, nil, nil):SetWind(u, v)
end

function SimulationController.SetPaused(value: boolean)
	assert(type(value) == "boolean", "Paused must be a boolean")
	paused = value
end

-- A bounded preview request. Playback temporarily requests at least 2x, retains
-- the normal per-frame step/budget limits, and restores the user's speed on finish.
-- Dropped backlog never counts as completed formation time.
function SimulationController.QueueFormation(seconds: number)
	assert(
		finite(seconds) and seconds >= FIXED_DT and seconds <= 240,
		"Formation time must be 0.25..240 seconds"
	)
	assert(seconds / FIXED_DT % 1 == 0, "Formation time must be a multiple of 0.25 seconds")
	formationRemaining = seconds
	paused = false
end

-- Speed changes the number of fixed physical steps, never their size.
-- Throws on invalid input or failed physics; the bootstrap stops Heartbeat on failure.
function SimulationController.Advance(frameDt: number, speed: number?): number
	assert(finite(frameDt) and frameDt >= 0, "Invalid atmosphere frame dt")
	local selectedSpeed = SimulationController.ValidateSpeed(speed or 1)
	requestedSpeed = selectedSpeed
	local effectiveSpeed = if formationRemaining > 0
		then math.max(selectedSpeed, 2)
		else selectedSpeed
	local nextAccumulator = accumulator + (if paused then 0 else frameDt * effectiveSpeed)
	local nextWallTime = wallTime + frameDt
	assert(finite(nextAccumulator) and finite(nextWallTime), "Atmosphere accumulator overflowed")
	local active = getSimulation(nil, nil, nil, nil)

	simulationSpeed = effectiveSpeed
	wallTime = nextWallTime
	accumulator = nextAccumulator
	if paused then
		lastAdvanceMilliseconds, lastAdvanceSteps, frameBudgetReached = 0, 0, false
		return 0
	end

	local started = clock()
	assert(finite(started), "Atmosphere execution clock must be finite")
	frameBudgetReached = false
	local steps = 0
	while accumulator >= FIXED_DT and steps < maxCatchUpSteps do
		-- Always permit one step, then check before starting another. Fixed-step
		-- physics is indivisible; this budget bounds catch-up rather than its cost.
		if steps > 0 and frameBudgetSeconds ~= nil then
			local elapsed = clock() - started
			assert(finite(elapsed) and elapsed >= 0, "Atmosphere execution clock must be monotonic")
			if elapsed >= frameBudgetSeconds then
				frameBudgetReached = true
				break
			end
		end
		local manager = sourceManager
		local nextTick = math.floor(active.Time / FIXED_DT + 0.5) + 1
		local forcing = if manager then manager:PrepareStep(nextTick, FIXED_DT) else nil
		active:Step(FIXED_DT, forcing)
		if manager then
			manager:CommitStep(nextTick)
		end
		accumulator -= FIXED_DT
		steps += 1
		formationRemaining = math.max(0, formationRemaining - FIXED_DT)
	end
	local elapsed = clock() - started
	assert(finite(elapsed) and elapsed >= 0, "Atmosphere execution clock must be monotonic")
	lastAdvanceMilliseconds = elapsed * 1000
	lastAdvanceSteps = steps

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
					"[WEATHERED] Frame work limit reached; dropped %.2fs of simulation backlog (total %.2fs)",
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
	return getSimulation(nil, nil, nil, nil).State
end

function SimulationController.GetGrid(): Grid3D.Grid3D
	return grid
end

function SimulationController.GetTime(): number
	return getSimulation(nil, nil, nil, nil).Time
end

function SimulationController.GetDiagnostics()
	local diagnostics =
		getSimulation(nil, nil, nil, nil):GetDiagnostics() :: Atmosphere.Diagnostics & {
			DroppedSimulationTime: number,
			SimulationSpeed: number,
			MaxCatchUpSteps: number,
			FrameBudgetMilliseconds: number,
			LastAdvanceMilliseconds: number,
			LastAdvanceSteps: number,
			FrameBudgetReached: boolean,
			Paused: boolean,
			FormationRemainingSeconds: number,
			RequestedSpeed: number,
			CloudMovementDefined: boolean,
			CloudCentroidDeltaSeconds: number,
			CloudCentroidDeltaXMeters: number,
			CloudCentroidDeltaYMeters: number,
			CloudCentroidDeltaZMeters: number,
			CloudCentroidDeltaXStuds: number,
			CloudCentroidDeltaYStuds: number,
			CloudCentroidDeltaZStuds: number,
		}
	if movementTime ~= diagnostics.Time then
		centroidDeltaSeconds = if movementTime then diagnostics.Time - movementTime else 0
		centroidMovementDefined = previousCentroidDefined
			and diagnostics.CloudCentroidDefined
			and centroidDeltaSeconds > 0
		if centroidMovementDefined then
			local lengthX, lengthZ = grid.SizeX * grid.Dx, grid.SizeZ * grid.Dz
			centroidDeltaX = (diagnostics.CloudCentroidX - previousCentroidX + lengthX * 0.5)
					% lengthX
				- lengthX * 0.5
			centroidDeltaY = diagnostics.CloudCentroidY - previousCentroidY
			centroidDeltaZ = (diagnostics.CloudCentroidZ - previousCentroidZ + lengthZ * 0.5)
					% lengthZ
				- lengthZ * 0.5
		else
			centroidDeltaX, centroidDeltaY, centroidDeltaZ = 0, 0, 0
		end
		movementTime = diagnostics.Time
		previousCentroidX, previousCentroidY, previousCentroidZ =
			diagnostics.CloudCentroidX, diagnostics.CloudCentroidY, diagnostics.CloudCentroidZ
		previousCentroidDefined = diagnostics.CloudCentroidDefined
	end
	diagnostics.CloudMovementDefined = centroidMovementDefined
	diagnostics.CloudCentroidDeltaSeconds = centroidDeltaSeconds
	diagnostics.CloudCentroidDeltaXMeters = centroidDeltaX
	diagnostics.CloudCentroidDeltaYMeters = centroidDeltaY
	diagnostics.CloudCentroidDeltaZMeters = centroidDeltaZ
	diagnostics.CloudCentroidDeltaXStuds = centroidDeltaX * grid.CellSize / grid.Dx
	diagnostics.CloudCentroidDeltaYStuds = centroidDeltaY * grid.CellSize / grid.Dy
	diagnostics.CloudCentroidDeltaZStuds = centroidDeltaZ * grid.CellSize / grid.Dz
	for name, value in SimulationController.GetSeedStatus() do
		(diagnostics :: any)[name] = value
	end
	diagnostics.DroppedSimulationTime = droppedTime
	diagnostics.SimulationSpeed = simulationSpeed
	diagnostics.MaxCatchUpSteps = maxCatchUpSteps
	diagnostics.FrameBudgetMilliseconds = (frameBudgetSeconds or 0) * 1000
	diagnostics.LastAdvanceMilliseconds = lastAdvanceMilliseconds
	diagnostics.LastAdvanceSteps = lastAdvanceSteps
	diagnostics.FrameBudgetReached = frameBudgetReached
	diagnostics.Paused = paused
	diagnostics.FormationRemainingSeconds = formationRemaining
	diagnostics.RequestedSpeed = requestedSpeed
	return diagnostics
end

function SimulationController.GetDroppedTime(): number
	return droppedTime
end

return SimulationController
