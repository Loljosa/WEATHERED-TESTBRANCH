--!native
--!strict

local Atmosphere = script.Parent.Parent
local Generator = require(Atmosphere.Generation.CloudSourceGenerator)
local Density = require(Atmosphere.Generation.CloudDensityField)
local WorldSeed = require(Atmosphere.Generation.WorldSeed)
local Saturation = require(Atmosphere.Thermodynamics.Saturation)
local Thermodynamics = require(Atmosphere.Thermodynamics.Thermodynamics)
local Coverage = require(script.Parent.Coverage)
local WeatherField = require(script.Parent.WeatherField)

local Sources = {}
Sources.__index = Sources
local FIXED_DT = 0.25
local VALUE_BYTES = 8

export type Region = Generator.Region
export type Source = Generator.Source & { RegionX: number, RegionZ: number, RegionId: number }
export type Forcing = {
	ThetaTarget: buffer,
	WaterTarget: buffer,
	Weights: buffer?,
	Fraction: number,
	MaxWaterSum: number,
	MaxThetaSum: number,
}
export type Settings = {
	Seed: number,
	Coverage: string?,
	FullPreset: boolean?,
	InitialSourceCount: number?,
	AutoClouds: boolean?,
	BuildSamplesPerStep: number?,
	SourceIntensity: number?,
	FormationIntervalTicks: number?,
	FormationProbability: number?,
	FormationDurationSeconds: number?,
	MaxExternalWaterFraction: number?,
	MaxExternalThetaPerCell: number?,
	Region: Region?,
}

type Slot = {
	Source: Source?,
	ThetaTarget: buffer,
	WaterTarget: buffer,
	Weights: buffer,
	BuildIndex: number,
	Built: boolean,
	AgeSeconds: number,
}

export type Manager = typeof(setmetatable(
	{} :: {
		Field: WeatherField.WeatherField,
		Seed: number,
		Region: Region,
		Scenario: Coverage.Scenario,
		InitialSourceCount: number,
		InitialSources: { Source },
		Slots: { Slot },
		Initialized: boolean,
		NextEventIndex: number,
		Tick: number,
		PreparedTick: number,
		PreparedForcing: Forcing?,
		PreparedScheduledSource: boolean,
		PreparedOpportunity: boolean,
		FormationIntervalTicks: number,
		FormationProbability: number,
		FormationDurationSeconds: number,
		AutoClouds: boolean,
		BuildSamplesPerStep: number,
		SourceIntensity: number,
		WaterBudget: number,
		ThetaBudget: number,
		ExternalWaterFraction: number,
		ExternalThetaPerCell: number,
		MergedForcing: Forcing,
		ManualSources: number,
		ScheduledSources: number,
		Opportunities: number,
		SamplesLastStep: number,
		SamplesTotal: number,
		InitialSamples: number,
		LastSourceId: string,
	},
	Sources
))

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

local function unit(seed: number, label: string): number
	return WorldSeed.Hash(WorldSeed.Derive(seed, label)) / 4294967296
end

-- A seeded coprime permutation visits every logical region once per 16-source
-- cycle. Regions classify sources; they are not physical simulation boundaries.
function Sources.Generate(
	seed: number,
	eventIndex: number,
	region: Region,
	tick: number?,
	coverage: string?
): Source
	WorldSeed.Validate(seed)
	integer(eventIndex, 0, 2147483647, "Source event index")
	Generator.ValidateRegion(region)
	local scenario = Coverage.Get(coverage)
	local weatherSeed = WorldSeed.Derive(seed, "world-cloud-sources")
	local cycleSeed = WorldSeed.Derive(weatherSeed, "region-cycle", math.floor(eventIndex / 16))
	local multiplier = 2 * math.floor(unit(cycleSeed, "stride") * 8) + 1
	local offset = math.floor(unit(cycleSeed, "offset") * 16)
	local regionId = ((eventIndex % 16) * multiplier + offset) % 16
	local rx, rz = regionId % 4, math.floor(regionId / 4)
	local generated = Generator.Generate(weatherSeed, eventIndex, region, {
		GenerationTick = tick or 0,
		TemperaturePerturbation = 0.2
			+ 0.5 * unit(WorldSeed.Derive(weatherSeed, "temperature", eventIndex), "value"),
		TargetRelativeHumidity = 0.999999,
		MoisturePerturbation = 0.025,
	})
	local source = table.clone(generated) :: any
	local logicalWidth, logicalDepth = region.SizeX / 4, region.SizeZ / 4
	local broad = generated.Kind == "Broad" or generated.Kind == "Broken"
	local extent = if broad then 0.55 else 0.38
	source.Id = string.format("world-cloud:%d:%d:%d", seed, eventIndex, generated.Seed)
	source.WorldSeed = seed
	source.X = region.OriginX + (rx + 0.25 + 0.5 * unit(generated.Seed, "world-x")) * logicalWidth
	source.Z = region.OriginZ + (rz + 0.25 + 0.5 * unit(generated.Seed, "world-z")) * logicalDepth
	source.RadiusX = math.min(
		region.SizeX * 0.4,
		math.max(
			2 * region.Dx,
			logicalWidth * extent * (0.85 + 0.3 * unit(generated.Seed, "world-radius-x"))
		)
	)
	source.RadiusZ = math.min(
		region.SizeZ * 0.4,
		math.max(
			2 * region.Dz,
			logicalDepth * extent * (0.85 + 0.3 * unit(generated.Seed, "world-radius-z"))
		)
	)
	local available = region.SizeY - 2 * region.Dy
	local thickness =
		math.max(3 * region.Dy, available * (0.75 + 0.25 * unit(generated.Seed, "world-thickness")))
	source.BaseAltitude = region.OriginY
		+ region.Dy
		+ (available - thickness) * unit(generated.Seed, "world-altitude")
	source.TopAltitude = source.BaseAltitude + thickness
	source.Y = (source.BaseAltitude + source.TopAltitude) * 0.5
	source.RadiusY = thickness * 0.5
	source.Intensity = generated.Intensity * scenario.Intensity
	source.RegionX, source.RegionZ, source.RegionId = rx, rz, regionId + 1
	return table.freeze(source)
end

function Sources.GetCoverage(name: string?, fullPreset: boolean?): any
	local result = table.clone(Coverage.Get(name)) :: any
	if fullPreset then
		result.InitialSourceCount = result.FullInitialSourceCount
	end
	return table.freeze(result)
end

local function availableSlot(self: Manager): Slot?
	for _, slot in self.Slots do
		if slot.Source == nil then
			return slot
		end
	end
	return nil
end

function Sources.new(field: WeatherField.WeatherField, settings: Settings): Manager
	assert(field.ValueBytes == VALUE_BYTES, "World sources require the float64 coarse WeatherField")
	local grid = field.State.Grid
	local scenario = Coverage.Get(settings.Coverage)
	local count = integer(
		settings.InitialSourceCount
			or (
				if settings.FullPreset
					then scenario.FullInitialSourceCount
					else scenario.InitialSourceCount
			),
		0,
		16,
		"Initial world source count"
	)
	local samples = integer(
		settings.BuildSamplesPerStep or (if settings.FullPreset then 192 else 128),
		1,
		512,
		"Source build samples"
	)
	local interval = integer(
		settings.FormationIntervalTicks or scenario.FormationIntervalTicks,
		1,
		14400,
		"Source interval"
	)
	local probability = settings.FormationProbability or scenario.FormationProbability
	local duration = settings.FormationDurationSeconds or 8
	local waterFraction = settings.MaxExternalWaterFraction or 0.15
	local thetaPerCell = settings.MaxExternalThetaPerCell or 0.5
	local intensity = settings.SourceIntensity or 1
	assert(
		finite(probability) and probability >= 0 and probability <= 1,
		"Formation probability must be 0..1"
	)
	assert(
		finite(duration)
			and duration >= FIXED_DT
			and duration <= 120
			and duration / FIXED_DT % 1 == 0,
		"Source duration must be 0.25..120 seconds in fixed-step multiples"
	)
	assert(
		finite(waterFraction) and waterFraction >= 0 and waterFraction <= 0.5,
		"External water budget must be 0..0.5 of initial water"
	)
	assert(
		finite(thetaPerCell) and thetaPerCell >= 0 and thetaPerCell <= 10,
		"External thermal budget must be 0..10 summed K per cell"
	)
	assert(finite(intensity) and intensity >= 0 and intensity <= 1, "SourceIntensity must be 0..1")
	assert(
		settings.AutoClouds == nil or type(settings.AutoClouds) == "boolean",
		"AutoClouds must be a boolean"
	)
	local coordinates = field.Coordinates
	local region: Region = settings.Region
		or {
			OriginX = coordinates.MinXMeters,
			OriginY = coordinates.BaseAltitudeMeters,
			OriginZ = coordinates.MinZMeters,
			SizeX = coordinates.WidthMeters,
			SizeY = coordinates.HeightMeters,
			SizeZ = coordinates.DepthMeters,
			Dx = grid.Dx,
			Dy = grid.Dy,
			Dz = grid.Dz,
		}
	Generator.ValidateRegion(region)
	assert(
		region.SizeX == grid.SizeX * grid.Dx
			and region.SizeY == grid.SizeY * grid.Dy
			and region.SizeZ == grid.SizeZ * grid.Dz,
		"Source region must match coarse physical field bounds"
	)
	assert(
		region.OriginX == coordinates.MinXMeters
			and region.OriginY == coordinates.BaseAltitudeMeters
			and region.OriginZ == coordinates.MinZMeters,
		"Source region origin must match coarse physical field bounds"
	)
	assert(
		region.Dx == grid.Dx and region.Dy == grid.Dy and region.Dz == grid.Dz,
		"Source region must match coarse field spacing"
	)
	local slots: { Slot } = {}
	for _ = 1, 2 do
		table.insert(slots, {
			Source = nil,
			ThetaTarget = buffer.create(grid.Count * VALUE_BYTES),
			WaterTarget = buffer.create(grid.Count * VALUE_BYTES),
			Weights = buffer.create(grid.Count * VALUE_BYTES),
			BuildIndex = 0,
			Built = false,
			AgeSeconds = 0,
		})
	end
	return setmetatable({
		Field = field,
		Seed = WorldSeed.Validate(settings.Seed),
		Region = table.freeze(table.clone(region)),
		Scenario = scenario,
		InitialSourceCount = count,
		InitialSources = {},
		Slots = slots,
		Initialized = false,
		NextEventIndex = count,
		Tick = 0,
		PreparedTick = 0,
		PreparedForcing = nil,
		PreparedScheduledSource = false,
		PreparedOpportunity = false,
		FormationIntervalTicks = interval,
		FormationProbability = probability,
		FormationDurationSeconds = duration,
		AutoClouds = if settings.AutoClouds == nil then true else settings.AutoClouds,
		BuildSamplesPerStep = samples,
		SourceIntensity = intensity,
		WaterBudget = 0,
		ThetaBudget = 0,
		ExternalWaterFraction = waterFraction,
		ExternalThetaPerCell = thetaPerCell,
		MergedForcing = {
			ThetaTarget = buffer.create(grid.Count * VALUE_BYTES),
			WaterTarget = buffer.create(grid.Count * VALUE_BYTES),
			Weights = buffer.create(grid.Count * VALUE_BYTES),
			Fraction = 0,
			MaxWaterSum = 0,
			MaxThetaSum = 0,
		},
		ManualSources = 0,
		ScheduledSources = 0,
		Opportunities = 0,
		SamplesLastStep = 0,
		SamplesTotal = 0,
		InitialSamples = 0,
		LastSourceId = "",
	}, Sources)
end

local function build(self: Manager, slot: Slot, maximumSamples: number): number
	local source = slot.Source
	assert(source ~= nil, "Cannot compile an empty world source")
	local field, region = self.Field, self.Region
	local grid, profile = field.State.Grid, field.Profile
	local stop = math.min(grid.Count, slot.BuildIndex + maximumSamples)
	local first, plane = slot.BuildIndex, grid.SizeX * grid.SizeZ
	local sealed = field.Boundary == "Sealed"
	for index = first, stop - 1 do
		local x, z, y =
			index % grid.SizeX,
			math.floor(index / grid.SizeX) % grid.SizeZ,
			math.floor(index / plane)
		local physicalX = region.OriginX + (x + 0.5) * grid.Dx
		local physicalZ = region.OriginZ + (z + 0.5) * grid.Dz
		-- Optional sealed outer walls clip support. Only the default globally
		-- periodic domain permits a source envelope to cross the world seam.
		local weight = 0
		if
			not sealed
			or (
				math.abs(physicalX - source.X) < source.RadiusX
				and math.abs(physicalZ - source.Z) < source.RadiusZ
			)
		then
			weight = Density.Sample(
				source,
				physicalX,
				region.OriginY + (y + 0.5) * grid.Dy,
				physicalZ,
				region
			) * source.Intensity * self.SourceIntensity
		end
		local theta, vapor =
			buffer.readf64(profile.Theta, y * VALUE_BYTES),
			buffer.readf64(profile.Qv, y * VALUE_BYTES)
		local thetaTarget = theta + source.TemperaturePerturbation * weight
		local pressure = buffer.readf64(field.State.Fields.pressure, index * VALUE_BYTES)
		local saturated = source.TargetRelativeHumidity
			* Saturation.MixingRatio(Thermodynamics.Temperature(thetaTarget, pressure), pressure)
		local wet = math.min(1, weight / 0.5)
		wet = wet * wet * (3 - 2 * wet)
		local waterTarget = math.min(
			vapor + wet * math.max(0, saturated - vapor),
			vapor + source.MoisturePerturbation * wet
		)
		buffer.writef64(slot.ThetaTarget, index * VALUE_BYTES, thetaTarget)
		buffer.writef64(slot.WaterTarget, index * VALUE_BYTES, waterTarget)
		buffer.writef64(slot.Weights, index * VALUE_BYTES, weight)
	end
	slot.BuildIndex, slot.Built = stop, stop == grid.Count
	return stop - first
end

function Sources:InitializeSources()
	assert(
		not self.Initialized and self.Field.Time == 0,
		"Initialize world sources only once on a new field"
	)
	local slot = self.Slots[1]
	for index = 0, self.InitialSourceCount - 1 do
		local source = Sources.Generate(self.Seed, index, self.Region, 0, self.Scenario.Name)
		table.insert(self.InitialSources, source)
		slot.Source, slot.BuildIndex, slot.Built = source, 0, false
		self.InitialSamples += build(self, slot, self.Field.State.Grid.Count)
		self.Field:InjectSource({
			ThetaTarget = slot.ThetaTarget,
			WaterTarget = slot.WaterTarget,
			Fraction = 1,
			MaxWaterSum = self.Field.State.Grid.Count * 0.1,
			MaxThetaSum = self.Field.State.Grid.Count * 20,
		})
		self.LastSourceId = source.Id
	end
	slot.Source, slot.BuildIndex, slot.Built, slot.AgeSeconds = nil, 0, false, 0
	self.Field:ResetWaterBaseline()
	self.WaterBudget = self.Field.InitialWaterSum * self.ExternalWaterFraction
	self.ThetaBudget = self.Field.State.Grid.Count * self.ExternalThetaPerCell
	self.Initialized = true
end

local function queue(self: Manager, slot: Slot, tick: number, committed: boolean): string
	local source =
		Sources.Generate(self.Seed, self.NextEventIndex, self.Region, tick, self.Scenario.Name)
	if committed then
		self.NextEventIndex += 1
	end
	slot.Source, slot.BuildIndex, slot.Built, slot.AgeSeconds = source, 0, false, 0
	self.LastSourceId = source.Id
	return source.Id
end

function Sources:QueueSource(): string
	assert(self.Initialized, "Initialize world sources before adding a source")
	assert(self.PreparedTick == 0, "Cannot add a source during an uncommitted world step")
	assert(
		self.Field.ExternalWaterSum < self.WaterBudget
			or self.Field.ExternalThetaSum < self.ThetaBudget,
		"World cloud source budget exhausted; regenerate explicitly"
	)
	local slot = availableSlot(self)
	assert(slot ~= nil, "World cloud source queue is full; wait for pending sources to finish")
	local id = queue(self, slot, self.Tick, true)
	self.ManualSources += 1
	return id
end

function Sources:SetAutoClouds(enabled: boolean)
	assert(type(enabled) == "boolean", "AutoClouds must be a boolean")
	assert(self.PreparedTick == 0, "Cannot change scheduling during an uncommitted world step")
	self.AutoClouds = enabled
end

function Sources:PrepareStep(nextTick: number, dt: number?): Forcing?
	assert(self.Initialized, "Initialize world sources before advancing the field")
	assert(
		(dt or FIXED_DT) == FIXED_DT,
		"World source scheduling requires the fixed 0.25-second step"
	)
	assert(
		nextTick % 1 == 0 and nextTick == self.Tick + 1,
		"World source manager requires the next committed tick"
	)
	if self.PreparedTick == nextTick then
		return self.PreparedForcing
	end
	assert(self.PreparedTick == 0, "Previous world source step is not committed")
	local waterRemaining = math.max(0, self.WaterBudget - self.Field.ExternalWaterSum)
	local thetaRemaining = math.max(0, self.ThetaBudget - self.Field.ExternalThetaSum)
	self.PreparedScheduledSource, self.PreparedOpportunity =
		false, nextTick % self.FormationIntervalTicks == 0
	if
		self.PreparedOpportunity
		and self.AutoClouds
		and (waterRemaining > 0 or thetaRemaining > 0)
	then
		local sample = unit(
			WorldSeed.Derive(self.Seed, "world-source-schedule", self.Opportunities + 1),
			"formation"
		)
		if sample < self.FormationProbability then
			local slot = availableSlot(self)
			if slot then
				queue(self, slot, nextTick, false)
				self.PreparedScheduledSource = true
			end
		end
	end
	local remaining = self.BuildSamplesPerStep
	self.SamplesLastStep = 0
	local anyBuilt = false
	for _, slot in self.Slots do
		if slot.Source and not slot.Built and remaining > 0 then
			local samples = build(self, slot, remaining)
			remaining -= samples
			self.SamplesLastStep += samples
		end
		anyBuilt = anyBuilt or (slot.Source ~= nil and slot.Built)
	end
	self.SamplesTotal += self.SamplesLastStep
	self.PreparedForcing = nil
	if anyBuilt and (waterRemaining > 0 or thetaRemaining > 0) then
		local forcing = self.MergedForcing
		local grid = self.Field.State.Grid
		for index = 0, grid.Count - 1 do
			local y = math.floor(index / (grid.SizeX * grid.SizeZ))
			local theta = buffer.readf64(self.Field.Profile.Theta, y * VALUE_BYTES)
			local water = buffer.readf64(self.Field.Profile.Qv, y * VALUE_BYTES)
			local weight = 0
			for _, slot in self.Slots do
				if slot.Source and slot.Built then
					local support = buffer.readf64(slot.Weights, index * VALUE_BYTES)
					if support > 0 then
						theta =
							math.max(theta, buffer.readf64(slot.ThetaTarget, index * VALUE_BYTES))
						water =
							math.max(water, buffer.readf64(slot.WaterTarget, index * VALUE_BYTES))
						weight = math.max(weight, support)
					end
				end
			end
			buffer.writef64(forcing.ThetaTarget, index * VALUE_BYTES, theta)
			buffer.writef64(forcing.WaterTarget, index * VALUE_BYTES, water)
			buffer.writef64(forcing.Weights :: buffer, index * VALUE_BYTES, weight)
		end
		forcing.Fraction, forcing.MaxWaterSum, forcing.MaxThetaSum =
			FIXED_DT / self.FormationDurationSeconds, waterRemaining, thetaRemaining
		self.PreparedForcing = forcing
	end
	self.PreparedTick = nextTick
	return self.PreparedForcing
end

function Sources:CommitStep(nextTick: number)
	assert(
		self.PreparedTick == nextTick and nextTick == self.Tick + 1,
		"World source commit must match preparation"
	)
	assert(
		math.abs(self.Field.Time - nextTick * FIXED_DT) < 1e-9,
		"Commit sources only after the matching successful world step"
	)
	for _, slot in self.Slots do
		if slot.Source and slot.Built then
			slot.AgeSeconds += FIXED_DT
			if slot.AgeSeconds >= self.FormationDurationSeconds then
				slot.Source, slot.BuildIndex, slot.Built, slot.AgeSeconds = nil, 0, false, 0
			end
		end
	end
	if self.PreparedScheduledSource then
		self.ScheduledSources += 1
		self.NextEventIndex += 1
	end
	if self.PreparedOpportunity then
		self.Opportunities += 1
	end
	self.Tick, self.PreparedTick, self.PreparedForcing = nextTick, 0, nil
	self.PreparedScheduledSource, self.PreparedOpportunity = false, false
end

function Sources:GetDiagnostics(): any
	local pending, building, active = 0, 0, 0
	for _, slot in self.Slots do
		if slot.Source then
			pending += 1
			if slot.Built then
				active += 1
			else
				building += 1
			end
		end
	end
	local waterRemaining = math.max(0, self.WaterBudget - self.Field.ExternalWaterSum)
	local thetaRemaining = math.max(0, self.ThetaBudget - self.Field.ExternalThetaSum)
	return {
		WorldSeed = self.Seed,
		Coverage = self.Scenario.Name,
		InitialSourceCount = self.InitialSourceCount,
		InitialCloudSources = self.InitialSources,
		SourceRegion = self.Region,
		SourceIntensity = self.SourceIntensity,
		SourceFormationDurationSeconds = self.FormationDurationSeconds,
		SourceBuildSamplesPerStep = self.BuildSamplesPerStep,
		SourceFormationIntervalTicks = self.FormationIntervalTicks,
		SourceFormationProbability = self.FormationProbability,
		MaxPendingSources = 2,
		AutoClouds = self.AutoClouds,
		SourceTick = self.Tick,
		ScheduledOpportunities = self.Opportunities,
		ScheduledSources = self.ScheduledSources,
		ManualSources = self.ManualSources,
		PendingSources = pending,
		BuildingSources = building,
		ActiveSources = active,
		SourceSamplesLastStep = self.SamplesLastStep,
		SourceSamplesTotal = self.SamplesTotal,
		InitialSourceSamples = self.InitialSamples,
		SourceBudgetExhausted = waterRemaining == 0 and thetaRemaining == 0,
		SourceWaterBudgetRemaining = waterRemaining,
		SourceThetaBudgetRemaining = thetaRemaining,
		SourceWaterBudget = self.WaterBudget,
		SourceThetaBudget = self.ThetaBudget,
		LastSourceId = self.LastSourceId,
		NextSourceEventIndex = self.NextEventIndex,
	}
end

return Sources
