--!native
--!strict

-- A deliberately one-way, optional nested experiment. The world field owns the
-- physical water inventory. This MAC state is a diagnostic shadow, never added
-- to world totals or rendered as a second authoritative cloud distribution.
-- Existing MAC lateral boundaries remain periodic; boundary-ring relaxation is
-- an explicitly measured environmental source, NOT conservative two-way nesting.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AtmosphereFolder = ReplicatedStorage.Shared.Atmosphere
local Atmosphere = require(AtmosphereFolder)
local Grid3D = require(AtmosphereFolder.Core.Grid3D)
local Constants = require(AtmosphereFolder.Core.Constants)
local Thermodynamics = require(AtmosphereFolder.Thermodynamics.Thermodynamics)
local Validation = require(AtmosphereFolder.Utilities.Validation)
local WorldCoordinates = require(AtmosphereFolder.World.WorldCoordinates)
local PerformanceSettings = require(script.Parent.PerformanceSettings)

local AtmosphericCoupling = {}
AtmosphericCoupling.__index = AtmosphericCoupling

-- This structural interface deliberately cannot write the coarse field. The
-- production WeatherField provides this sampler; clients never own this adapter.
export type WorldSampler = {
	Coordinates: WorldCoordinates.Coordinates,
	Time: number,
	Tick: number,
	SamplePhysical: (WorldSampler, number, number, number, string) -> number,
}

export type Options = {
	Preset: string?, -- Laptop/Full selects existing local resolution, never more.
	Enabled: boolean?, -- false by default: world transport needs no local MAC.
	RegionId: number?, -- stable 1..16 administrative anchor, never player-relative.
	IntervalTicks: number?, -- at least four world ticks; one local step per call.
	CpuBudgetMilliseconds: number?, -- soft indivisible-step budget, not an FPS promise.
	ConditioningTimescaleSeconds: number?, -- signed boundary-ring relaxation, world s.
	ExperimentConfig: Atmosphere.Config?, -- cached legacy diagnostic source controls.
}

export type Diagnostics = {
	Enabled: boolean,
	Mode: string,
	RegionId: number,
	ActiveSolvers: number,
	AllocatedSolvers: number,
	WorldTime: number,
	LocalTime: number,
	ActivationWorldTime: number,
	IntervalTicks: number,
	LocalSteps: number,
	SkippedLocalSteps: number,
	Initializations: number,
	BoundaryCellCount: number,
	SamplesLastStep: number,
	SamplesTotal: number,
	StepMilliseconds: number,
	InitializationMilliseconds: number,
	CpuBudgetMilliseconds: number,
	BudgetOverruns: number,
	BufferBytes: number,
	BufferCount: number,
	WaterExchangeSum: number, -- signed unweighted local kg/kg sum, NOT kg.
	ThetaExchangeSum: number, -- signed summed K, NOT heat energy.
	EnthalpyExchangeSum: number, -- summed J/kg dry air, NOT domain joules.
	LocalWaterErrorFraction: number,
	ProjectionResidual: number,
	MaxCourant: number,
	DxMeters: number,
	DyMeters: number,
	DzMeters: number,
	LastFailure: string?,
}

export type Coupling = typeof(setmetatable(
	{} :: {
		World: WorldSampler,
		Preset: string,
		Enabled: boolean,
		Mode: string,
		RegionId: number,
		IntervalTicks: number,
		CpuBudgetMilliseconds: number,
		ConditioningTimescaleSeconds: number,
		Simulation: Atmosphere.Simulation?,
		BoundaryIndices: buffer?,
		BoundaryTheta: buffer?,
		BoundaryQv: buffer?,
		BoundaryCellCount: number,
		OriginXMeters: number,
		OriginZMeters: number,
		ActivationWorldTime: number,
		NextTick: number,
		LastWorldTick: number,
		LocalSteps: number,
		SkippedLocalSteps: number,
		Initializations: number,
		SamplesLastStep: number,
		SamplesTotal: number,
		StepMilliseconds: number,
		InitializationMilliseconds: number,
		BudgetOverruns: number,
		BufferBytes: number,
		BufferCount: number,
		WaterExchangeSum: number,
		ThetaExchangeSum: number,
		EnthalpyExchangeSum: number,
		LastFailure: string?,
		ExperimentConfig: Atmosphere.Config,
	},
	AtmosphericCoupling
))

local function finite(value: number, name: string)
	assert(Validation.IsFinite(value), name .. " must be finite")
end

local function integer(value: number, minimum: number, maximum: number, name: string)
	finite(value, name)
	assert(value % 1 == 0 and value >= minimum and value <= maximum, name .. " is out of range")
end

local function checkedSample(self: Coupling, x: number, y: number, z: number, name: string): number
	local value = self.World:SamplePhysical(x, y, z, name)
	if not Validation.IsFinite(value) then
		error("Nonfinite coarse sample " .. name)
	end
	if name == "theta" or name == "pressure" then
		assert(value > 0, "Coarse positive field is invalid")
	elseif name == "qv" then
		assert(value >= 0, "Coarse vapor must be nonnegative")
	end
	self.SamplesLastStep += 1
	self.SamplesTotal += 1
	return value
end

local function countStorage(self: Coupling)
	local seen: { [any]: boolean } = {}
	local bytes, count = 0, 0
	local function visit(value: any)
		if seen[value] then
			return
		end
		if typeof(value) == "buffer" then
			seen[value] = true
			bytes += buffer.len(value)
			count += 1
		elseif type(value) == "table" then
			seen[value] = true
			for _, child in value do
				visit(child)
			end
		end
	end
	visit(self.Simulation)
	visit(self.BoundaryIndices)
	visit(self.BoundaryTheta)
	visit(self.BoundaryQv)
	self.BufferBytes, self.BufferCount = bytes, count
end

-- Nine fixed physical samples per layer provide a cheap reference profile.
-- Profiles describe the selected world region, rather than a 0-m surface sounding.
local function refreshReference(self: Coupling, simulation: Atmosphere.Simulation)
	local grid = simulation.State.Grid
	local width, depth = grid.SizeX * grid.Dx, grid.SizeZ * grid.Dz
	local base = self.World.Coordinates.BaseAltitudeMeters
	for y = 1, grid.SizeY do
		local theta, qv, u, v = 0, 0, 0, 0
		local altitude = base + (y - 0.5) * grid.Dy
		for iz = 1, 3 do
			for ix = 1, 3 do
				local x = self.OriginXMeters + (ix - 0.5) * width / 3
				local z = self.OriginZMeters + (iz - 0.5) * depth / 3
				theta += checkedSample(self, x, altitude, z, "theta")
				qv += checkedSample(self, x, altitude, z, "qv")
				u += checkedSample(self, x, altitude, z, "u")
				v += checkedSample(self, x, altitude, z, "v")
			end
		end
		local offset = (y - 1) * 4
		buffer.writef32(simulation.Profile.Theta, offset, theta / 9)
		buffer.writef32(simulation.Profile.Qv, offset, qv / 9)
		-- Save wind samples in the reusable row buffers. SetWind subsequently
		-- shifts faces toward the fitted linear shear while preserving perturbations.
		buffer.writef32(simulation.Profile.U, offset, u / 9)
		buffer.writef32(simulation.Profile.V, offset, v / 9)
	end
end

local function createBoundaryStorage(self: Coupling, grid: Grid3D.Grid3D)
	local count = (grid.SizeX * grid.SizeZ - (grid.SizeX - 2) * (grid.SizeZ - 2)) * grid.SizeY
	local indices = buffer.create(count * 4)
	local slot = 0
	for y = 1, grid.SizeY do
		for z = 1, grid.SizeZ do
			for x = 1, grid.SizeX do
				if x == 1 or x == grid.SizeX or z == 1 or z == grid.SizeZ then
					buffer.writeu32(indices, slot * 4, grid:Index(x, y, z))
					slot += 1
				end
			end
		end
	end
	self.BoundaryIndices = indices
	self.BoundaryTheta = buffer.create(count * 4)
	self.BoundaryQv = buffer.create(count * 4)
	self.BoundaryCellCount = count
end

local function initializeWorldDetail(self: Coupling, regionId: number): Atmosphere.Simulation
	local started = os.clock()
	local coordinate = self.World.Coordinates
	local rx, rz = coordinate:RegionCoordinates(regionId)
	local bounds = coordinate:RegionBounds(rx, rz)
	local preset = PerformanceSettings.Resolve(self.Preset)
	local dx = (bounds.MaxXMeters - bounds.MinXMeters) / preset.SizeX
	local dz = (bounds.MaxZMeters - bounds.MinZMeters) / preset.SizeZ
	local dy = coordinate.HeightMeters / preset.SizeY
	-- Grid3D's legacy display spacing is isotropic. This shadow is intentionally
	-- not rendered through it; authoritative rendering uses WorldCoordinates.
	local grid = Grid3D.new(
		preset.SizeX,
		preset.SizeY,
		preset.SizeZ,
		bounds.WidthStuds / preset.SizeX,
		Vector3.new(bounds.MinX, coordinate.BottomStuds, bounds.MinZ),
		{ Dx = dx, Dy = dy, Dz = dz }
	)
	local simulation = Atmosphere.new(grid, {
		DisableBubble = true,
		MomentumOptions = { Viscosity = 1, DragTimescale = 30 },
	})
	self.OriginXMeters, self.OriginZMeters = bounds.MinXMeters, bounds.MinZMeters
	self.SamplesLastStep = 0
	local fields = simulation.State.Fields
	for y = 1, grid.SizeY do
		local altitude = coordinate.BaseAltitudeMeters + (y - 0.5) * grid.Dy
		for z = 1, grid.SizeZ do
			local pz = self.OriginZMeters + (z - 0.5) * grid.Dz
			for x = 1, grid.SizeX do
				local px = self.OriginXMeters + (x - 0.5) * grid.Dx
				local offset = (grid:Index(x, y, z) - 1) * 4
				buffer.writef32(
					fields.theta,
					offset,
					checkedSample(self, px, altitude, pz, "theta")
				)
				buffer.writef32(fields.qv, offset, checkedSample(self, px, altitude, pz, "qv"))
				buffer.writef32(
					fields.pressure,
					offset,
					checkedSample(self, px, altitude, pz, "pressure")
				)
			end
		end
	end
	refreshReference(self, simulation)
	for y = 1, grid.SizeY do
		local offset = (y - 1) * 4
		local u = buffer.readf32(simulation.Profile.U, offset)
		local v = buffer.readf32(simulation.Profile.V, offset)
		for index = (y - 1) * grid.SizeX * grid.SizeZ, y * grid.SizeX * grid.SizeZ - 1 do
			buffer.writef32(fields.u, index * 4, u)
			buffer.writef32(fields.v, index * 4, v)
		end
	end
	local lastOffset = (grid.SizeY - 1) * 4
	local heightBetweenCenters = (grid.SizeY - 1) * grid.Dy
	simulation.ShearU = (
		buffer.readf32(simulation.Profile.U, lastOffset) - buffer.readf32(simulation.Profile.U, 0)
	) / heightBetweenCenters
	simulation.ShearV = (
		buffer.readf32(simulation.Profile.V, lastOffset) - buffer.readf32(simulation.Profile.V, 0)
	) / heightBetweenCenters
	simulation.BackgroundU = buffer.readf32(simulation.Profile.U, 0)
		- simulation.ShearU * grid.Dy * 0.5
	simulation.BackgroundV = buffer.readf32(simulation.Profile.V, 0)
		- simulation.ShearV * grid.Dy * 0.5
	simulation.Faces:Initialize(simulation.State)
	simulation.Faces:WriteCellCenters(simulation.State)
	Validation.CheckState(simulation.State)
	simulation:ResetWaterBaseline()
	createBoundaryStorage(self, grid)
	self.InitializationMilliseconds = (os.clock() - started) * 1000
	return simulation
end

function AtmosphericCoupling.new(world: WorldSampler, options: Options?): Coupling
	local settings = options or {}
	local preset = settings.Preset or "Laptop"
	PerformanceSettings.Resolve(preset)
	assert(
		settings.Enabled == nil or type(settings.Enabled) == "boolean",
		"Detail Enabled must be boolean"
	)
	local interval = settings.IntervalTicks or 4
	integer(interval, 4, 240, "Detail IntervalTicks")
	local regionId = settings.RegionId or 6
	integer(regionId, 1, 16, "Detail RegionId")
	local budget = settings.CpuBudgetMilliseconds or 4
	finite(budget, "Detail CPU budget")
	assert(budget > 0 and budget <= 1000, "Detail CPU budget must be in (0,1000] ms")
	local timescale = settings.ConditioningTimescaleSeconds or 2
	finite(timescale, "Conditioning timescale")
	assert(timescale > 0, "Conditioning timescale must be positive")
	integer(world.Tick, 0, 9007199254740991, "World tick")
	finite(world.Time, "World time")
	local self = setmetatable({
		World = world,
		Preset = preset,
		Enabled = false,
		Mode = "WorldConditioned",
		RegionId = regionId,
		IntervalTicks = interval,
		CpuBudgetMilliseconds = budget,
		ConditioningTimescaleSeconds = timescale,
		Simulation = nil,
		BoundaryIndices = nil,
		BoundaryTheta = nil,
		BoundaryQv = nil,
		BoundaryCellCount = 0,
		OriginXMeters = 0,
		OriginZMeters = 0,
		ActivationWorldTime = world.Time,
		NextTick = world.Tick + interval,
		LastWorldTick = world.Tick,
		LocalSteps = 0,
		SkippedLocalSteps = 0,
		Initializations = 0,
		SamplesLastStep = 0,
		SamplesTotal = 0,
		StepMilliseconds = 0,
		InitializationMilliseconds = 0,
		BudgetOverruns = 0,
		BufferBytes = 0,
		BufferCount = 0,
		WaterExchangeSum = 0,
		ThetaExchangeSum = 0,
		EnthalpyExchangeSum = 0,
		LastFailure = nil,
		ExperimentConfig = table.clone(settings.ExperimentConfig or {
			BubbleShape = "Round",
			BubbleScale = 1,
			BubbleTemperaturePerturbation = 6,
			BubbleRelativeHumidity = 0.999,
		}),
	}, AtmosphericCoupling)
	if settings.Enabled then
		self:SetEnabled(true, regionId)
	end
	return self
end

function AtmosphericCoupling:SetEnabled(enabled: boolean, regionId: number?)
	assert(type(enabled) == "boolean", "Detail enabled must be boolean")
	local selected = regionId or self.RegionId
	integer(selected, 1, 16, "Detail RegionId")
	if not enabled then
		self.Enabled = false
		return
	end
	if
		self.Enabled
		and self.Simulation ~= nil
		and selected == self.RegionId
		and self.Mode == "WorldConditioned"
	then
		return -- idempotent administrative requests cannot postpone scheduled work.
	end
	if self.Simulation == nil or selected ~= self.RegionId or self.Mode ~= "WorldConditioned" then
		-- Replacing the sole shadow is an explicit request. It cannot reset world
		-- buffers, world time, source descriptions, or the physical inventory.
		-- Construction is transactional too: a rejected source sample must not
		-- change the anchor/storage of an already valid retained shadow.
		local staged = table.clone(self)
		local simulation = initializeWorldDetail(staged, selected)
		self.Simulation = simulation
		self.OriginXMeters, self.OriginZMeters = staged.OriginXMeters, staged.OriginZMeters
		self.BoundaryIndices, self.BoundaryTheta, self.BoundaryQv =
			staged.BoundaryIndices, staged.BoundaryTheta, staged.BoundaryQv
		self.BoundaryCellCount = staged.BoundaryCellCount
		self.SamplesLastStep, self.SamplesTotal = staged.SamplesLastStep, staged.SamplesTotal
		self.InitializationMilliseconds = staged.InitializationMilliseconds
		self.RegionId = selected
		self.Mode = "WorldConditioned"
		self.ActivationWorldTime = self.World.Time
		self.LocalSteps, self.SkippedLocalSteps = 0, 0
		self.WaterExchangeSum, self.ThetaExchangeSum, self.EnthalpyExchangeSum = 0, 0, 0
		self.Initializations += 1
		countStorage(self)
	end
	self.Enabled = true
	self.LastFailure = nil
	self.NextTick = self.World.Tick + self.IntervalTicks
	self.LastWorldTick = self.World.Tick
end

-- Compatibility for legacy shape/size/formation experiments. The existing
-- Sounding and MAC solver run unchanged, in their historical physical box.
-- This mode is explicitly isolated: its pressure/geometry are not world samples.
local function numericArgument(value: any, name: string): number
	local result = if type(value) == "number"
		then value
		else if type(value) == "string" then tonumber(value) else nil
	assert(result ~= nil and Validation.IsFinite(result), name .. " must be finite")
	return result :: number
end

function AtmosphericCoupling:StartExperiment(command: any?, ...: any): string
	local config = table.clone(self.ExperimentConfig)
	if type(command) == "table" then
		assert(select("#", ...) == 0, "A local experiment config accepts no extra arguments")
		-- Typed programmatic configuration is also useful for numerical tests.
		config = table.clone(command) :: Atmosphere.Config
	elseif command ~= nil then
		assert(
			type(command) == "string",
			"Use spawn, reset, size or condensation for a local experiment"
		)
		local selected = string.lower(command)
		local arguments = table.pack(...)
		local shape, formation, scale = nil, nil, nil
		if selected == "spawn" or selected == "reset" then
			assert(arguments.n <= 3, "Use spawn [Round|Wide|Tower] [Normal|Fast] [0.5..1.5]")
			shape, formation, scale = arguments[1], arguments[2], arguments[3]
		elseif selected == "size" then
			assert(arguments.n == 1 and arguments[1] ~= nil, "Use size 0.5..1.5")
			scale = arguments[1]
		elseif selected == "condensation" then
			assert(arguments.n == 1 and arguments[1] ~= nil, "Use condensation Normal|Fast")
			formation = arguments[1]
		else
			error("Local experiment accepts spawn, reset, size or condensation")
		end
		if shape ~= nil then
			assert(type(shape) == "string", "Shape must be Round, Wide or Tower")
			local names: { [string]: string } = { round = "Round", wide = "Wide", tower = "Tower" }
			config.BubbleShape = names[string.lower(shape)]
			assert(config.BubbleShape ~= nil, "Shape must be Round, Wide or Tower")
		end
		if formation ~= nil then
			assert(type(formation) == "string", "Formation must be Normal or Fast")
			local name = string.lower(formation)
			assert(name == "normal" or name == "fast", "Formation must be Normal or Fast")
			config.BubbleTemperaturePerturbation = if name == "fast" then 8 else 6
			config.BubbleRelativeHumidity = if name == "fast" then 0.9999 else 0.999
		end
		if scale ~= nil then
			local size = numericArgument(scale, "Size")
			assert(size >= 0.5 and size <= 1.5, "Size must be 0.5..1.5")
			config.BubbleScale = size
		end
	else
		assert(select("#", ...) == 0, "Use spawn [Round|Wide|Tower] [Normal|Fast] [0.5..1.5]")
	end
	local started = os.clock()
	local preset = PerformanceSettings.Resolve(self.Preset)
	local grid = Grid3D.new(preset.SizeX, preset.SizeY, preset.SizeZ, 12, Vector3.new(0, 424, 0), {
		Dx = preset.Dx,
		Dy = preset.Dy,
		Dz = preset.Dz,
	})
	local simulation = Atmosphere.new(grid, config)
	self.ExperimentConfig = config
	self.Simulation = simulation
	self.Mode = "LegacyExperiment"
	self.Enabled = true
	self.BoundaryIndices, self.BoundaryTheta, self.BoundaryQv = nil, nil, nil
	self.BoundaryCellCount = 0
	self.ActivationWorldTime = self.World.Time
	self.NextTick, self.LastWorldTick = self.World.Tick + self.IntervalTicks, self.World.Tick
	self.LocalSteps, self.SkippedLocalSteps = 0, 0
	self.WaterExchangeSum, self.ThetaExchangeSum, self.EnthalpyExchangeSum = 0, 0, 0
	self.Initializations += 1
	self.InitializationMilliseconds = (os.clock() - started) * 1000
	self.LastFailure = nil
	countStorage(self)
	return string.format(
		"Started isolated %s local MAC experiment, size %.2fx, theta excess %.1f K, RH %.4f. Diagnostic only: global cloud water, world sources and time are unchanged.",
		config.BubbleShape or "Round",
		config.BubbleScale or 1,
		config.BubbleTemperaturePerturbation or 2,
		config.BubbleRelativeHumidity or 0.98
	)
end

local function advanceLocal(self: Coupling): (number, number, number)
	local simulation = self.Simulation
	assert(simulation ~= nil, "Active detail has no solver")
	local waterInput, thetaInput, enthalpyInput = 0, 0, 0
	if self.Mode == "WorldConditioned" then
		local grid, fields = simulation.State.Grid, simulation.State.Fields
		local indices, thetaTargets, vaporTargets =
			self.BoundaryIndices, self.BoundaryTheta, self.BoundaryQv
		assert(
			indices ~= nil and thetaTargets ~= nil and vaporTargets ~= nil,
			"Missing boundary storage"
		)
		local fraction = 1
			- math.exp(-self.IntervalTicks * Atmosphere.FixedDt / self.ConditioningTimescaleSeconds)
		local base = self.World.Coordinates.BaseAltitudeMeters
		-- Stage every target before editing local thermodynamics. Convex relaxation
		-- preserves positivity without clipping. Only the lateral one-cell ring is
		-- conditioned; sealed top/bottom remain the existing physical MAC walls.
		for slot = 0, self.BoundaryCellCount - 1 do
			local index = buffer.readu32(indices, slot * 4)
			local x, y, z = grid:Coordinates(index)
			local px = self.OriginXMeters + (x - 0.5) * grid.Dx
			local py = base + (y - 0.5) * grid.Dy
			local pz = self.OriginZMeters + (z - 0.5) * grid.Dz
			local offset = (index - 1) * 4
			local theta = buffer.readf32(fields.theta, offset)
			local qv = buffer.readf32(fields.qv, offset)
			buffer.writef32(
				thetaTargets,
				slot * 4,
				theta + fraction * (checkedSample(self, px, py, pz, "theta") - theta)
			)
			buffer.writef32(
				vaporTargets,
				slot * 4,
				qv + fraction * (checkedSample(self, px, py, pz, "qv") - qv)
			)
		end
		-- SetWind must see the old drag targets to shift MAC perturbations correctly.
		local oldU, oldV = simulation.BackgroundU, simulation.BackgroundV
		refreshReference(self, simulation)
		local last = (grid.SizeY - 1) * 4
		local height = (grid.SizeY - 1) * grid.Dy
		local targetShearU = (
			buffer.readf32(simulation.Profile.U, last) - buffer.readf32(simulation.Profile.U, 0)
		) / height
		local targetShearV = (
			buffer.readf32(simulation.Profile.V, last) - buffer.readf32(simulation.Profile.V, 0)
		) / height
		local targetU = buffer.readf32(simulation.Profile.U, 0) - targetShearU * grid.Dy * 0.5
		local targetV = buffer.readf32(simulation.Profile.V, 0) - targetShearV * grid.Dy * 0.5
		for y = 1, grid.SizeY do
			local h = (y - 0.5) * grid.Dy
			buffer.writef32(simulation.Profile.U, (y - 1) * 4, oldU + simulation.ShearU * h)
			buffer.writef32(simulation.Profile.V, (y - 1) * 4, oldV + simulation.ShearV * h)
		end
		simulation.ShearU, simulation.ShearV = targetShearU, targetShearV
		simulation:SetWind(targetU, targetV)
		for slot = 0, self.BoundaryCellCount - 1 do
			local offset = (buffer.readu32(indices, slot * 4) - 1) * 4
			local theta = buffer.readf32(thetaTargets, slot * 4)
			local qv = buffer.readf32(vaporTargets, slot * 4)
			local dTheta = theta - buffer.readf32(fields.theta, offset)
			local dQv = qv - buffer.readf32(fields.qv, offset)
			buffer.writef32(fields.theta, offset, theta)
			buffer.writef32(fields.qv, offset, qv)
			waterInput += dQv
			thetaInput += dTheta
			enthalpyInput += Constants.SpecificHeatDryAir * Thermodynamics.Exner(
				buffer.readf32(fields.pressure, offset)
			) * dTheta + Constants.LatentHeatVaporization * dQv
		end
	end
	simulation:Step(Atmosphere.FixedDt)
	return waterInput, thetaInput, enthalpyInput
end

-- Called AFTER a successful coarse commit. A paused/repeated tick does no work.
-- Fine time deliberately advances more slowly: .25 s per >=1 s world time. It
-- is a CPU-bounded experiment, not a synchronized conservative nested solution.
function AtmosphericCoupling:Advance(worldTick: number): boolean
	integer(worldTick, 0, 9007199254740991, "Committed world tick")
	assert(worldTick == self.World.Tick, "Detail requires the authoritative committed world tick")
	assert(
		worldTick >= self.LastWorldTick,
		"World ticks cannot reverse without regenerating coupling"
	)
	if worldTick == self.LastWorldTick then
		return false
	end
	self.LastWorldTick = worldTick
	self.SamplesLastStep = 0
	if not self.Enabled or worldTick < self.NextTick then
		return false
	end
	self.SkippedLocalSteps += math.floor((worldTick - self.NextTick) / self.IntervalTicks)
	self.NextTick = worldTick + self.IntervalTicks
	local started = os.clock()
	local success, water, theta, enthalpy = pcall(advanceLocal, self)
	self.StepMilliseconds = (os.clock() - started) * 1000
	if self.StepMilliseconds > self.CpuBudgetMilliseconds then
		self.BudgetOverruns += 1
	end
	if not success then
		-- Failure of optional detail never changes or stalls the coarse world.
		-- Discard the sole conditioned shadow rather than exposing partially
		-- updated boundary/profile state. Re-enable is an explicit fresh request.
		self.LastFailure = tostring(water)
		self.Enabled = false
		self.Simulation = nil
		self.BoundaryIndices, self.BoundaryTheta, self.BoundaryQv = nil, nil, nil
		self.BoundaryCellCount = 0
		self.BufferBytes, self.BufferCount = 0, 0
		return false
	end
	self.WaterExchangeSum += water
	self.ThetaExchangeSum += theta
	self.EnthalpyExchangeSum += enthalpy
	self.LocalSteps += 1
	return true
end

function AtmosphericCoupling:GetDiagnostics(): Diagnostics
	local simulation = self.Simulation
	local diagnostic = if simulation then simulation:GetDiagnostics() else nil
	local grid = if simulation then simulation.State.Grid else nil
	local waterError = 0
	if diagnostic and simulation and simulation.InitialWaterSum > 0 then
		waterError = (
			diagnostic.WaterSum
			- simulation.InitialWaterSum
			- self.WaterExchangeSum
			- simulation.ExternalWaterSum
		) / simulation.InitialWaterSum
	end
	return {
		Enabled = self.Enabled,
		Mode = self.Mode,
		RegionId = self.RegionId,
		ActiveSolvers = if self.Enabled and simulation then 1 else 0,
		AllocatedSolvers = if simulation then 1 else 0,
		WorldTime = self.World.Time,
		LocalTime = if simulation then simulation.Time else 0,
		ActivationWorldTime = self.ActivationWorldTime,
		IntervalTicks = self.IntervalTicks,
		LocalSteps = self.LocalSteps,
		SkippedLocalSteps = self.SkippedLocalSteps,
		Initializations = self.Initializations,
		BoundaryCellCount = self.BoundaryCellCount,
		SamplesLastStep = self.SamplesLastStep,
		SamplesTotal = self.SamplesTotal,
		StepMilliseconds = self.StepMilliseconds,
		InitializationMilliseconds = self.InitializationMilliseconds,
		CpuBudgetMilliseconds = self.CpuBudgetMilliseconds,
		BudgetOverruns = self.BudgetOverruns,
		BufferBytes = self.BufferBytes,
		BufferCount = self.BufferCount,
		WaterExchangeSum = self.WaterExchangeSum,
		ThetaExchangeSum = self.ThetaExchangeSum,
		EnthalpyExchangeSum = self.EnthalpyExchangeSum,
		LocalWaterErrorFraction = waterError,
		ProjectionResidual = if diagnostic then diagnostic.ProjectionResidual else 0,
		MaxCourant = if diagnostic then diagnostic.MaxCourant else 0,
		DxMeters = if grid then grid.Dx else 0,
		DyMeters = if grid then grid.Dy else 0,
		DzMeters = if grid then grid.Dz else 0,
		LastFailure = self.LastFailure,
	}
end

return table.freeze(AtmosphericCoupling)
