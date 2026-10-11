--!strict

local Root = game:GetService("ReplicatedStorage").Shared.Atmosphere
local Coordinates = require(Root.World.WorldCoordinates)
local WeatherField = require(Root.World.WeatherField)
local Sources = require(Root.World.WorldCloudSources)
local Coverage = require(Root.World.Coverage)
local WorldSeed = require(Root.Generation.WorldSeed)
local Coupling = require(script.Parent.AtmosphericCoupling)

local Controller = {}
Controller.__index = Controller
Controller.FixedDt = 0.25

export type Settings = {
	Seed: number?,
	SeedSource: string?,
	Preset: string?,
	Coverage: string?,
	Coordinates: any?,
	BackgroundU: number?,
	BackgroundV: number?,
	ShearU: number?,
	ShearV: number?,
	AutoClouds: boolean?,
	InitialSourceCount: number?,
	SourceIntensity: number?,
	Boundary: string?,
	Speed: number?,
	Clock: (() -> number)?,
}

local function finite(n: number): boolean
	return n == n and math.abs(n) < math.huge
end

function Controller.ValidateSpeed(n: number): number
	assert(finite(n) and n >= 0.25 and n <= 4, "Speed must be 0.25..4")
	return n
end

local function construct(options: Settings): (any, any, any)
	local full = options.Preset == "Full"
	local scenario = Coverage.Get(options.Coverage or "Scattered")
	local coordinates = Coordinates.new(options.Coordinates)
	local field = WeatherField.new(coordinates, {
		SizeX = if full then 48 else 32,
		SizeY = 6,
		SizeZ = if full then 48 else 32,
		BackgroundU = options.BackgroundU or 2,
		BackgroundV = options.BackgroundV or 1,
		ShearU = options.ShearU or 0,
		ShearV = options.ShearV or 0,
		BackgroundRelativeHumidity = scenario.EnvironmentalRH,
		Boundary = options.Boundary or "Periodic",
	})
	local sources = Sources.new(field, {
		Seed = options.Seed or 84219,
		Coverage = scenario.Name,
		FullPreset = full,
		InitialSourceCount = options.InitialSourceCount,
		SourceIntensity = options.SourceIntensity,
		AutoClouds = options.AutoClouds,
		BuildSamplesPerStep = if full then 192 else 128,
	})
	sources:InitializeSources()
	local detail = Coupling.new(field, { Preset = options.Preset or "Laptop" })
	return field, sources, detail
end

function Controller.new(options: Settings?): any
	local settings = table.clone(options or {})
	settings.Seed = WorldSeed.Validate(settings.Seed or 84219)
	settings.Preset = settings.Preset or "Laptop"
	assert(
		settings.Preset == "Laptop" or settings.Preset == "Full",
		"Preset must be Laptop or Full"
	)
	local field, sources, detail = construct(settings)
	return setmetatable({
		Field = field,
		Sources = sources,
		Coupling = detail,
		Options = settings,
		NextOptions = table.clone(settings),
		Clock = settings.Clock or os.clock,
		Speed = Controller.ValidateSpeed(settings.Speed or 1),
		Accumulator = 0,
		WallTime = 0,
		DroppedSimulationTime = 0,
		DroppedSteps = 0,
		Tick = 0,
		Paused = false,
		FormationRemainingSeconds = 0,
		MaxCatchUpSteps = if settings.Preset == "Full" then 2 else 1,
		FrameBudgetMilliseconds = 8,
		LastAdvanceMilliseconds = 0,
		LastAdvanceSteps = 0,
		DebugRegions = false,
		DebugVectors = false,
		DetailError = nil,
		MotionSample = nil,
		MotionDistanceMeters = 0,
	}, Controller)
end

function Controller:Regenerate()
	local options = table.clone(self.NextOptions)
	local field, sources, detail = construct(options)
	self.Field, self.Sources, self.Coupling = field, sources, detail
	self.Options = options
	self.Tick, self.Accumulator, self.WallTime, self.DroppedSimulationTime, self.DroppedSteps =
		0, 0, 0, 0, 0
	self.LastAdvanceMilliseconds, self.LastAdvanceSteps = 0, 0
	self.Paused, self.FormationRemainingSeconds, self.DetailError = false, 0, nil
	self.MotionSample, self.MotionDistanceMeters = nil, 0
end

function Controller:Advance(frameDt: number): number
	assert(finite(frameDt) and frameDt >= 0, "Frame dt must be finite and nonnegative")
	self.WallTime += frameDt
	assert(finite(self.WallTime), "Wall clock overflow")
	self.LastAdvanceSteps, self.LastAdvanceMilliseconds = 0, 0
	if self.Paused then
		return 0
	end
	local speed = if self.FormationRemainingSeconds > 0 then math.max(self.Speed, 2) else self.Speed
	self.Accumulator += frameDt * speed
	assert(finite(self.Accumulator), "World accumulator overflow")
	local started = self.Clock()
	assert(finite(started), "Invalid execution clock")
	while self.Accumulator >= Controller.FixedDt and self.LastAdvanceSteps < self.MaxCatchUpSteps do
		if
			self.LastAdvanceSteps > 0
			and (self.Clock() - started) * 1000 >= self.FrameBudgetMilliseconds
		then
			break
		end
		local tick = self.Tick + 1
		local forcing = self.Sources:PrepareStep(tick, Controller.FixedDt)
		self.Field:Step(Controller.FixedDt, forcing)
		self.Sources:CommitStep(tick)
		self.Tick = tick
		self.Accumulator -= Controller.FixedDt
		self.LastAdvanceSteps += 1
		self.FormationRemainingSeconds =
			math.max(0, self.FormationRemainingSeconds - Controller.FixedDt)
		-- Shadow detail failure must not invalidate the authoritative world step.
		local ok, problem = pcall(self.Coupling.Advance, self.Coupling, tick)
		if not ok then
			self.DetailError = tostring(problem)
			self.Coupling:SetEnabled(false)
		end
	end
	local elapsed = self.Clock() - started
	assert(finite(elapsed) and elapsed >= 0, "Execution clock must be monotonic")
	self.LastAdvanceMilliseconds = elapsed * 1000
	local dropped = math.floor(self.Accumulator / Controller.FixedDt)
	if dropped > 0 then
		self.Accumulator -= dropped * Controller.FixedDt
		self.DroppedSteps += dropped
		self.DroppedSimulationTime += dropped * Controller.FixedDt
	end
	return self.LastAdvanceSteps
end

function Controller:GetDiagnostics(): any
	local result = self.Field:GetDiagnostics()
	if self.MotionSample == nil or self.MotionSample.Time ~= result.Time then
		local previous = self.MotionSample
		local defined = previous ~= nil
			and previous.CloudCentroidDefined
			and result.CloudCentroidDefined
		local dx, dy, dz, seconds = 0, 0, 0, 0
		if defined then
			local coords = self.Field.Coordinates
			dx = result.CloudCentroidX - previous.CloudCentroidX
			dz = result.CloudCentroidZ - previous.CloudCentroidZ
			if self.Field.Boundary == "Periodic" then
				dx = (dx + coords.WidthMeters / 2) % coords.WidthMeters - coords.WidthMeters / 2
				dz = (dz + coords.DepthMeters / 2) % coords.DepthMeters - coords.DepthMeters / 2
			end
			dy = result.CloudCentroidY - previous.CloudCentroidY
			seconds = result.Time - previous.Time
			self.MotionDistanceMeters += math.sqrt(dx * dx + dy * dy + dz * dz)
		end
		self.MotionInterval =
			{ Defined = defined, Seconds = seconds, XMeters = dx, YMeters = dy, ZMeters = dz }
		self.MotionSample = result
	end
	result.CloudMotion = self.MotionInterval
	result.CloudCentroidSampledPathMeters = self.MotionDistanceMeters
	result.CloudCentroidSampledPathStuds = self.MotionDistanceMeters
		* self.Field.Coordinates.StudsPerMeter
	result.MotionInterpretation =
		"Sampled qc centroid path includes formation, evaporation, merging and periodic ambiguity; not parcel travel"
	result.WallTime = self.WallTime
	result.DroppedSimulationTime, result.DroppedSteps =
		self.DroppedSimulationTime, self.DroppedSteps
	result.LastAdvanceMilliseconds, result.LastAdvanceSteps =
		self.LastAdvanceMilliseconds, self.LastAdvanceSteps
	result.SimulationSpeed, result.Paused = self.Speed, self.Paused
	result.SeedSource = self.Options.SeedSource or "DevelopmentFallback"
	result.Sources, result.Detail = self.Sources:GetDiagnostics(), self.Coupling:GetDiagnostics()
	result.DetailError = self.DetailError
	return result
end

return Controller
