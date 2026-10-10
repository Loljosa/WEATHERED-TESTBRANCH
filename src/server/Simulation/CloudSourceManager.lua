--!native
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere
local Simulation = require(AtmosphereRoot.Simulation)
local Generator = require(AtmosphereRoot.Generation.CloudSourceGenerator)
local Density = require(AtmosphereRoot.Generation.CloudDensityField)
local WorldSeed = require(AtmosphereRoot.Generation.WorldSeed)
local Saturation = require(AtmosphereRoot.Thermodynamics.Saturation)
local Thermodynamics = require(AtmosphereRoot.Thermodynamics.Thermodynamics)
local Scheduler = require(script.Parent.CloudFormationScheduler)

local Manager = {}
Manager.__index = Manager

export type Region = Generator.Region
export type Settings = {
	Seed: number,
	InitialSourceCount: number?,
	MaxInitialSources: number?,
	AutoClouds: boolean?,
	FormationIntervalTicks: number?,
	FormationDurationSeconds: number?,
	FormationProbability: number?,
	BuildSamplesPerStep: number?,
	MaxPendingSources: number?,
	MaxExternalWaterFraction: number?,
	MaxExternalThetaPerCell: number?,
	SourceIntensity: number?,
	Region: Region?,
}

type Slot = {
	Source: Generator.Source?,
	ThetaTarget: buffer,
	WaterTarget: buffer,
	Weights: buffer,
	BuildIndex: number,
	Built: boolean,
	AgeSeconds: number,
}

export type Manager = typeof(setmetatable(
	{} :: {
		Simulation: Simulation.Simulation,
		Seed: number,
		Region: Region,
		InitialSourceCount: number,
		InitialSources: { Generator.Source },
		Slots: { Slot },
		Scheduler: Scheduler.Scheduler,
		Initialized: boolean,
		NextEventIndex: number,
		Tick: number,
		PreparedTick: number,
		PreparedDt: number,
		PreparedForcing: Simulation.SourceForcing?,
		PreparedScheduledSource: boolean,
		FormationDurationSeconds: number,
		BuildSamplesPerStep: number,
		ExternalWaterFraction: number,
		ExternalThetaPerCell: number,
		SourceIntensity: number,
		WaterBudget: number,
		ThetaBudget: number,
		MergedForcing: Simulation.SourceForcing,
		ManualSources: number,
		ScheduledSources: number,
		SamplesLastStep: number,
		SamplesTotal: number,
		InitialSamples: number,
		LastSourceId: string,
	},
	Manager
))

export type CloudSourceManager = Manager

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function integer(value: number, minimum: number, maximum: number, label: string): number
	assert(
		finite(value) and value % 1 == 0 and value >= minimum and value <= maximum,
		label .. " is outside its supported integer range"
	)
	return value
end

local function availableSlot(self: Manager): Slot?
	for _, slot in self.Slots do
		if slot.Source == nil then
			return slot
		end
	end
	return nil
end

function Manager.new(simulation: Simulation.Simulation, settings: Settings): Manager
	local grid = simulation.State.Grid
	local maximum = integer(settings.MaxInitialSources or 4, 1, 6, "Maximum initial sources")
	local count = integer(settings.InitialSourceCount or 2, 1, maximum, "Initial source count")
	local pending = integer(settings.MaxPendingSources or 2, 1, 2, "Pending source count")
	local samples = integer(settings.BuildSamplesPerStep or 128, 1, 512, "Source build samples")
	local duration = settings.FormationDurationSeconds or 8
	local waterFraction = settings.MaxExternalWaterFraction or 0.15
	local thetaPerCell = settings.MaxExternalThetaPerCell or 3
	local sourceIntensity = settings.SourceIntensity or 1
	assert(
		finite(duration) and duration >= Simulation.FixedDt and duration <= 120,
		"Source duration must be 0.25..120 physical seconds"
	)
	assert(
		duration / Simulation.FixedDt % 1 == 0,
		"Source duration must be a multiple of the 0.25-second physical timestep"
	)
	assert(
		finite(waterFraction) and waterFraction >= 0 and waterFraction <= 0.5,
		"External water budget must be 0..0.5 of initial water"
	)
	assert(
		finite(thetaPerCell) and thetaPerCell >= 0 and thetaPerCell <= 10,
		"External thermal budget must be 0..10 summed K per cell"
	)
	assert(
		finite(sourceIntensity) and sourceIntensity >= 0 and sourceIntensity <= 1,
		"SourceIntensity must be 0..1"
	)
	local region: Region = settings.Region
		or {
			OriginX = -grid.SizeX * grid.Dx * 0.5,
			OriginY = 0,
			OriginZ = -grid.SizeZ * grid.Dz * 0.5,
			SizeX = grid.SizeX * grid.Dx,
			SizeY = grid.SizeY * grid.Dy,
			SizeZ = grid.SizeZ * grid.Dz,
			Dx = grid.Dx,
			Dy = grid.Dy,
			Dz = grid.Dz,
		}
	assert(
		region.SizeX == grid.SizeX * grid.Dx
			and region.SizeY == grid.SizeY * grid.Dy
			and region.SizeZ == grid.SizeZ * grid.Dz,
		"Source region must match the active physical grid extent"
	)
	assert(
		region.Dx == grid.Dx and region.Dy == grid.Dy and region.Dz == grid.Dz,
		"Source region resolution must match the active physical grid"
	)
	local seed = WorldSeed.Validate(settings.Seed)
	local slots: { Slot } = {}
	for _ = 1, pending do
		table.insert(slots, {
			Source = nil,
			ThetaTarget = buffer.create(grid.Count * 4),
			WaterTarget = buffer.create(grid.Count * 4),
			Weights = buffer.create(grid.Count * 4),
			BuildIndex = 0,
			Built = false,
			AgeSeconds = 0,
		})
	end
	return setmetatable({
		Simulation = simulation,
		Seed = seed,
		Region = table.freeze(table.clone(region)),
		InitialSourceCount = count,
		InitialSources = {},
		Slots = slots,
		Scheduler = Scheduler.new(seed, {
			IntervalTicks = settings.FormationIntervalTicks,
			Enabled = settings.AutoClouds,
			FormationProbability = settings.FormationProbability,
		}),
		Initialized = false,
		NextEventIndex = count,
		Tick = 0,
		PreparedTick = 0,
		PreparedDt = 0,
		PreparedForcing = nil,
		PreparedScheduledSource = false,
		FormationDurationSeconds = duration,
		BuildSamplesPerStep = samples,
		ExternalWaterFraction = waterFraction,
		ExternalThetaPerCell = thetaPerCell,
		SourceIntensity = sourceIntensity,
		WaterBudget = 0,
		ThetaBudget = 0,
		MergedForcing = {
			ThetaTarget = buffer.create(grid.Count * 4),
			WaterTarget = buffer.create(grid.Count * 4),
			Weights = buffer.create(grid.Count * 4),
			Fraction = 0,
			MaxWaterSum = 0,
			MaxThetaSum = 0,
		},
		ManualSources = 0,
		ScheduledSources = 0,
		SamplesLastStep = 0,
		SamplesTotal = 0,
		InitialSamples = 0,
		LastSourceId = "",
	}, Manager)
end

-- Geometry is compiled into two packed target fields. No noise evaluation is
-- performed by momentum/transport/microphysics, and no source writes qc.
local function build(self: Manager, slot: Slot, maximumSamples: number): number
	local source = slot.Source
	assert(source ~= nil, "Cannot build an empty cloud source")
	local simulation, region = self.Simulation, self.Region
	local grid, profile = simulation.State.Grid, simulation.Profile
	local stop = math.min(grid.Count, slot.BuildIndex + maximumSamples)
	local first = slot.BuildIndex
	local plane = grid.SizeX * grid.SizeZ
	for index = first, stop - 1 do
		local x = index % grid.SizeX
		local z = math.floor(index / grid.SizeX) % grid.SizeZ
		local y = math.floor(index / plane)
		local weight = Density.Sample(
			source,
			region.OriginX + (x + 0.5) * grid.Dx,
			region.OriginY + (y + 0.5) * grid.Dy,
			region.OriginZ + (z + 0.5) * grid.Dz,
			region
		) * source.Intensity * self.SourceIntensity
		local theta = buffer.readf32(profile.Theta, y * 4)
		local vapor = buffer.readf32(profile.Qv, y * 4)
		local thetaTarget = theta + source.TemperaturePerturbation * weight
		local pressure = buffer.readf32(simulation.State.Fields.pressure, index * 4)
		local saturatedTarget = source.TargetRelativeHumidity
			* Saturation.MixingRatio(Thermodynamics.Temperature(thetaTarget, pressure), pressure)
		-- A broad, near-saturated interior survives coarse-grid advection. Both
		-- targets remain bounded by the saturation value at the actual warm target.
		local wetStrength = math.min(1, weight / 0.5)
		wetStrength = wetStrength * wetStrength * (3 - 2 * wetStrength)
		local waterTarget = math.min(
			vapor + wetStrength * math.max(0, saturatedTarget - vapor),
			vapor + source.MoisturePerturbation * wetStrength
		)
		buffer.writef32(slot.ThetaTarget, index * 4, thetaTarget)
		buffer.writef32(slot.WaterTarget, index * 4, waterTarget)
		buffer.writef32(slot.Weights, index * 4, weight)
	end
	slot.BuildIndex = stop
	slot.Built = stop == grid.Count
	return stop - first
end

function Manager:InitializeSources()
	assert(
		not self.Initialized and self.Simulation.Time == 0,
		"Seeded sources must initialize a new atmosphere once"
	)
	local slot = self.Slots[1]
	for eventIndex = 0, self.InitialSourceCount - 1 do
		local source =
			Generator.Generate(self.Seed, eventIndex, self.Region, { GenerationTick = 0 })
		table.insert(self.InitialSources, source)
		slot.Source, slot.BuildIndex, slot.Built = source, 0, false
		self.InitialSamples += build(self, slot, self.Simulation.State.Grid.Count)
		self.Simulation:InjectSource({
			ThetaTarget = slot.ThetaTarget,
			WaterTarget = slot.WaterTarget,
			Fraction = 1,
			MaxWaterSum = self.Simulation.State.Grid.Count * 0.1,
			MaxThetaSum = self.Simulation.State.Grid.Count * 20,
		})
		self.LastSourceId = source.Id
	end
	slot.Source, slot.BuildIndex, slot.Built, slot.AgeSeconds = nil, 0, false, 0
	self.Simulation:ResetWaterBaseline()
	self.WaterBudget = self.Simulation.InitialWaterSum * self.ExternalWaterFraction
	self.ThetaBudget = self.Simulation.State.Grid.Count * self.ExternalThetaPerCell
	self.Initialized = true
end

local function queue(self: Manager, slot: Slot, generationTick: number, committed: boolean): string
	local source = Generator.Generate(
		self.Seed,
		self.NextEventIndex,
		self.Region,
		{ GenerationTick = generationTick }
	)
	if committed then
		self.NextEventIndex += 1
	end
	slot.Source, slot.BuildIndex, slot.Built, slot.AgeSeconds = source, 0, false, 0
	self.LastSourceId = source.Id
	return source.Id
end

function Manager:QueueSource(): string
	assert(self.Initialized, "Initialize seeded atmosphere before queuing a source")
	assert(self.PreparedTick == 0, "Cannot queue a source during an uncommitted physical step")
	assert(
		self.Simulation.ExternalWaterSum < self.WaterBudget
			or self.Simulation.ExternalThetaSum < self.ThetaBudget,
		"Cloud forcing budget is exhausted; regenerate to intentionally initialize a new atmosphere"
	)
	local slot = availableSlot(self)
	assert(slot ~= nil, "Cloud source queue is full; allow existing sources to finish")
	local id = queue(self, slot, self.Tick, true)
	self.ManualSources += 1
	return id
end

function Manager:SetAutoClouds(enabled: boolean)
	self.Scheduler:SetEnabled(enabled)
end

function Manager:PrepareStep(nextTick: number, dt: number?): Simulation.SourceForcing?
	assert(self.Initialized, "Initialize seeded atmosphere before advancing sources")
	local stepDt = dt or Simulation.FixedDt
	assert(
		stepDt == Simulation.FixedDt,
		"Seeded scheduling requires the fixed 0.25-second physical step"
	)
	assert(
		nextTick % 1 == 0 and nextTick == self.Tick + 1,
		"Cloud source manager requires the next committed tick"
	)
	if self.PreparedTick == nextTick then
		return self.PreparedForcing
	end
	assert(self.PreparedTick == 0, "Previous cloud source step is not committed")
	local forms = self.Scheduler:Prepare(nextTick)
	local waterRemaining = math.max(0, self.WaterBudget - self.Simulation.ExternalWaterSum)
	local thetaRemaining = math.max(0, self.ThetaBudget - self.Simulation.ExternalThetaSum)
	self.PreparedScheduledSource = false
	if forms and (waterRemaining > 0 or thetaRemaining > 0) then
		local slot = availableSlot(self)
		if slot then
			queue(self, slot, nextTick, false)
			self.PreparedScheduledSource = true
		end
	end
	local remainingSamples = self.BuildSamplesPerStep
	self.SamplesLastStep = 0
	local anyBuilt = false
	for _, slot in self.Slots do
		if slot.Source ~= nil and not slot.Built and remainingSamples > 0 then
			local samples = build(self, slot, remainingSamples)
			remainingSamples -= samples
			self.SamplesLastStep += samples
		end
		anyBuilt = anyBuilt or (slot.Source ~= nil and slot.Built)
	end
	self.SamplesTotal += self.SamplesLastStep
	self.PreparedForcing = nil
	if anyBuilt and (waterRemaining > 0 or thetaRemaining > 0) then
		local forcing = self.MergedForcing
		for index = 0, self.Simulation.State.Grid.Count - 1 do
			local y = math.floor(index / self.Simulation.Geometry.Plane)
			local thetaTarget = buffer.readf32(self.Simulation.Profile.Theta, y * 4)
			local waterTarget = buffer.readf32(self.Simulation.Profile.Qv, y * 4)
			local weight = 0
			for _, slot in self.Slots do
				if slot.Source ~= nil and slot.Built then
					local sourceWeight = buffer.readf32(slot.Weights, index * 4)
					if sourceWeight > 0 then
						thetaTarget =
							math.max(thetaTarget, buffer.readf32(slot.ThetaTarget, index * 4))
						waterTarget =
							math.max(waterTarget, buffer.readf32(slot.WaterTarget, index * 4))
						weight = math.max(weight, sourceWeight)
					end
				end
			end
			buffer.writef32(forcing.ThetaTarget, index * 4, thetaTarget)
			buffer.writef32(forcing.WaterTarget, index * 4, waterTarget)
			buffer.writef32(forcing.Weights :: buffer, index * 4, weight)
		end
		forcing.Fraction = stepDt / self.FormationDurationSeconds
		forcing.MaxWaterSum = waterRemaining
		forcing.MaxThetaSum = thetaRemaining
		self.PreparedForcing = forcing
	end
	self.PreparedTick, self.PreparedDt = nextTick, stepDt
	return self.PreparedForcing
end

-- Called only after successful Simulation:Step. Geometry compilation may remain
-- cached after a failure, but event age, schedule clock and input ledgers do not advance.
function Manager:CommitStep(nextTick: number)
	assert(
		self.PreparedTick == nextTick and nextTick == self.Tick + 1,
		"Cloud source commit must match its preparation"
	)
	assert(
		math.abs(self.Simulation.Time - nextTick * Simulation.FixedDt) < 1e-9,
		"Commit cloud sources only after the matching physical step succeeds"
	)
	for _, slot in self.Slots do
		if slot.Source ~= nil and slot.Built then
			slot.AgeSeconds += self.PreparedDt
			if slot.AgeSeconds >= self.FormationDurationSeconds then
				slot.Source, slot.BuildIndex, slot.Built, slot.AgeSeconds = nil, 0, false, 0
			end
		end
	end
	if self.PreparedScheduledSource then
		self.ScheduledSources += 1
		self.NextEventIndex += 1
	end
	self.Scheduler:Commit(nextTick)
	self.Tick = nextTick
	self.PreparedTick, self.PreparedDt, self.PreparedForcing = 0, 0, nil
	self.PreparedScheduledSource = false
end

function Manager:GetDiagnostics()
	local pending, building, active = 0, 0, 0
	for _, slot in self.Slots do
		if slot.Source ~= nil then
			pending += 1
			if slot.Built then
				active += 1
			else
				building += 1
			end
		end
	end
	local waterRemaining = math.max(0, self.WaterBudget - self.Simulation.ExternalWaterSum)
	local thetaRemaining = math.max(0, self.ThetaBudget - self.Simulation.ExternalThetaSum)
	local initialDescriptions = {}
	for _, source in self.InitialSources do
		table.insert(initialDescriptions, {
			Id = source.Id,
			Kind = source.Kind,
			X = source.X,
			Y = source.Y,
			Z = source.Z,
			RadiusX = source.RadiusX,
			RadiusY = source.RadiusY,
			RadiusZ = source.RadiusZ,
			BaseAltitude = source.BaseAltitude,
			TopAltitude = source.TopAltitude,
			TemperaturePerturbation = source.TemperaturePerturbation,
			MoisturePerturbation = source.MoisturePerturbation,
			TargetRelativeHumidity = source.TargetRelativeHumidity,
			Intensity = source.Intensity * self.SourceIntensity,
			GenerationTick = source.GenerationTick,
		})
	end
	return {
		WorldSeed = self.Seed,
		InitialSourceCount = self.InitialSourceCount,
		InitialCloudSources = initialDescriptions,
		SourceRegion = self.Region,
		SourceIntensity = self.SourceIntensity,
		SourceFormationDurationSeconds = self.FormationDurationSeconds,
		SourceBuildSamplesPerStep = self.BuildSamplesPerStep,
		SourceFormationIntervalTicks = self.Scheduler.IntervalTicks,
		SourceFormationProbability = self.Scheduler.FormationProbability,
		MaxPendingSources = #self.Slots,
		AutoClouds = self.Scheduler.Enabled,
		SourceTick = self.Tick,
		ScheduledOpportunities = self.Scheduler.Opportunities,
		ScheduledSources = self.ScheduledSources,
		ManualSources = self.ManualSources,
		PendingSources = pending,
		BuildingSources = building,
		ActiveSources = active,
		SourceSamplesLastStep = self.SamplesLastStep,
		SourceSamplesTotal = self.SamplesTotal,
		InitialSourceSamples = self.InitialSamples,
		SourceBudgetExhausted = waterRemaining == 0 and thetaRemaining == 0,
		SourceWaterBudgetExhausted = waterRemaining == 0,
		SourceThetaBudgetExhausted = thetaRemaining == 0,
		SourceWaterBudgetRemaining = waterRemaining,
		SourceThetaBudgetRemaining = thetaRemaining,
		SourceWaterBudget = self.WaterBudget,
		SourceThetaBudget = self.ThetaBudget,
		LastSourceId = self.LastSourceId,
		NextSourceEventIndex = self.NextEventIndex,
	}
end

return Manager
