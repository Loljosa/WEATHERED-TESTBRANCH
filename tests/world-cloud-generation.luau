--!strict

return function(root: any, loadModule: any, check: any, near: any, rejects: any, quick: boolean?)
	local Sources = loadModule(root.World.WorldCloudSources)
	local Coverage = loadModule(root.World.Coverage)
	local Density = loadModule(root.Generation.CloudDensityField)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local Field = loadModule(root.World.WeatherField)
	local coordinates = Coordinates.new()
	local region = coordinates:PhysicalRegion(32, 6, 32)
	local function equal(a: any, b: any): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for key, value in a do
			if not equal(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	end
	local seenSeeds = {}
	for _, seed in { -2147483648, -39, 0, 39, 84219, 2147483647 } do
		local ids, regions = {}, {}
		local positions = ""
		for event = 0, 31 do
			local a = Sources.Generate(seed, event, region, event * 4, "Scattered")
			local b = Sources.Generate(seed, event, region, event * 4, "scattered")
			check(equal(a, b), "World source generation is identical across repeated runs")
			check(
				a.WorldSeed == seed and a.EventIndex == event and a.GenerationTick == event * 4,
				"World source provenance retains canonical seed and tick"
			)
			check(not ids[a.Id], "Source identifier is unique per world event")
			ids[a.Id] = true
			check(
				a.RegionX >= 0 and a.RegionX <= 3 and a.RegionZ >= 0 and a.RegionZ <= 3,
				"Source has stable integer logical region coordinates"
			)
			check(
				a.RegionId == a.RegionZ * 4 + a.RegionX + 1,
				"Source IDs match world region indexing"
			)
			if event < 16 then
				check(not regions[a.RegionId], "One initial source cycle visits each region once")
				regions[a.RegionId] = true
			end
			local bounds = coordinates.Bounds[a.RegionId]
			check(
				a.X >= bounds.MinXMeters
					and a.X < bounds.MaxXMeters
					and a.Z >= bounds.MinZMeters
					and a.Z < bounds.MaxZMeters,
				"Source center lies in its declared world region"
			)
			check(
				a.BaseAltitude >= region.OriginY + region.Dy
					and a.TopAltitude <= region.OriginY + region.SizeY - region.Dy,
				"Source altitude envelope remains inside sealed atmospheric layer"
			)
			check(
				a.TopAltitude - a.BaseAltitude >= 3 * region.Dy
					and a.RadiusX >= 2 * region.Dx
					and a.RadiusZ >= 2 * region.Dz,
				"Procedural features are resolved on coarse grid"
			)
			check(
				a.TemperaturePerturbation >= 0.2 and a.TemperaturePerturbation <= 0.7,
				"World sources use bounded physical thermal anomalies"
			)
			near(Density.Sample(a, a.X, a.BaseAltitude, a.Z, region), 0, 0, "Source base is clear")
			near(Density.Sample(a, a.X, a.TopAltitude, a.Z, region), 0, 0, "Source top is clear")
			local weight = Density.Sample(a, a.X, a.Y, a.Z, region)
			check(
				weight >= 0 and weight <= 1 and weight == weight,
				"Source weight is a finite bounded geometric forcing field"
			)
			near(
				Density.Sample(a, a.X + region.SizeX, a.Y, a.Z, region),
				weight,
				1e-12,
				"Periodic source generation matches only at full-world boundary"
			)
			positions ..= string.format("%.6f:%.6f;", a.X, a.Z)
		end
		check(not seenSeeds[positions], "Different world seeds change source geography")
		seenSeeds[positions] = true
	end
	-- Optional sealed outer boundaries clip a source envelope instead of
	-- creating its periodic image at the opposite physical wall.
	local edgeSeed: number? = nil
	local edgeIndex: number? = nil
	for seed = 0, 128 do
		local source = Sources.Generate(seed, 0, region)
		for z = 0, 31 do
			for _, x in { 0, 31 } do
				local px = region.OriginX + (x + 0.5) * region.Dx
				local pz = region.OriginZ + (z + 0.5) * region.Dz
				local py = region.OriginY + 2.5 * region.Dy
				if
					math.abs(px - source.X) > source.RadiusX
					and Density.Sample(source, px, py, pz, region) > 0.01
				then
					edgeSeed, edgeIndex = seed, (2 * 32 * 32 + z * 32 + x)
					break
				end
			end
			if edgeSeed then
				break
			end
		end
		if edgeSeed then
			break
		end
	end
	check(
		edgeSeed ~= nil and edgeIndex ~= nil,
		"Geometry regression finds a resolved source crossing the outer world seam"
	)
	local sealed = Field.new(coordinates, {
		SizeX = 32,
		SizeY = 6,
		SizeZ = 32,
		Boundary = "Sealed",
		BackgroundU = 0,
		BackgroundV = 0,
		ShearU = 0,
		ShearV = 0,
	})
	local sealedSources = Sources.new(
		sealed,
		{ Seed = edgeSeed :: number, InitialSourceCount = 1, AutoClouds = false }
	)
	sealedSources:InitializeSources()
	near(
		buffer.readf64(sealed.Fields.theta, (edgeIndex :: number) * 8),
		buffer.readf64(sealed.Profile.Theta, 2 * 8),
		0,
		"Sealed domain never injects a periodic ghost source at the opposite wall"
	)
	near(
		buffer.readf64(sealed.Fields.qv, (edgeIndex :: number) * 8),
		buffer.readf64(sealed.Profile.Qv, 2 * 8),
		0,
		"Sealed source clipping preserves unforced vapor at the opposite wall"
	)
	local priorHumidity, priorCount, priorProbability = 0, -1, -1
	for _, mode in { "Clear", "Few", "Scattered", "Broken", "Overcast" } do
		local scenario = Coverage.Get(mode)
		check(
			scenario.EnvironmentalRH > priorHumidity
				and scenario.InitialSourceCount > priorCount
				and scenario.FormationProbability > priorProbability,
			"Coverage modes change humidity, geography and event frequency"
		)
		check(
			scenario.InitialSourceCount <= 16 and scenario.FullInitialSourceCount <= 16,
			"Coverage source counts remain bounded"
		)
		check(
			Sources.GetCoverage(mode, true).InitialSourceCount == scenario.FullInitialSourceCount,
			"Full preset source count is explicit"
		)
		priorHumidity, priorCount, priorProbability =
			scenario.EnvironmentalRH, scenario.InitialSourceCount, scenario.FormationProbability
	end
	rejects(function()
		Coverage.Get("storm")
	end, "Unsupported decorative coverage target is rejected")
	rejects(function()
		Sources.Generate(1.5, 0, region)
	end, "Fractional canonical seed is rejected")
	rejects(function()
		Sources.Generate(1, -1, region)
	end, "Negative event indices are rejected")

	local function create(seed: number, mode: string, auto: boolean?): (any, any)
		local scenario = Coverage.Get(mode)
		local field = Field.new(coordinates, {
			SizeX = 16,
			SizeY = 6,
			SizeZ = 16,
			BackgroundRelativeHumidity = scenario.EnvironmentalRH,
			BackgroundU = 8,
			BackgroundV = 2,
		})
		local manager = Sources.new(field, {
			Seed = seed,
			Coverage = mode,
			AutoClouds = auto,
			BuildSamplesPerStep = 128,
			FormationIntervalTicks = 8,
			FormationProbability = 1,
		})
		manager:InitializeSources()
		return field, manager
	end
	local clear, clearSources = create(0, "Clear", false)
	near(clearSources.InitialSourceCount, 0, 0, "Clear scenario starts without manufactured clouds")
	for index = 0, clear.State.Grid.Count - 1 do
		near(buffer.readf64(clear.Fields.qc, index * 8), 0, 0, "Clear world qc starts at zero")
	end
	local field, manager = create(84219, "Scattered", false)
	local repeated, repeatedSources = create(84219, "Scattered", false)
	near(field.Time, 0, 0, "Seeded initial conditions do not advance physical time")
	near(field.ExternalWaterSum, 0, 0, "Initial vapor input belongs to initial condition baseline")
	near(field.ExternalThetaSum, 0, 0, "Initial heat belongs to initial condition baseline")
	local distinct = {}
	for _, source in manager.InitialSources do
		distinct[source.RegionId] = true
	end
	local distinctCount = 0
	for _ in distinct do
		distinctCount += 1
	end
	near(distinctCount, 6, 0, "Scattered world starts in six distinct logical regions")
	for _, name in { "theta", "qv", "qc", "qr", "pressure", "u", "v", "w" } do
		check(
			buffer.tostring(field.Fields[name]) == buffer.tostring(repeated.Fields[name]),
			"Canonical seed initializes identical production fields"
		)
	end
	local count = field.State.Grid.Count
	for index = 0, count - 1 do
		near(
			buffer.readf64(field.Fields.qc, index * 8),
			0,
			0,
			"Generated geometry never directly initializes liquid cloud water"
		)
	end
	local savedQc = buffer.tostring(field.Fields.qc)
	local queuedId = manager:QueueSource()
	near(field.Time, 0, 0, "Queuing another source does not reset or advance simulation")
	check(
		savedQc == buffer.tostring(field.Fields.qc),
		"Queuing sources leaves existing liquid state untouched"
	)
	check(
		type(queuedId) == "string" and manager:GetDiagnostics().PendingSources == 1,
		"Manual deterministic source has bounded queue entry"
	)
	manager:QueueSource()
	rejects(function()
		manager:QueueSource()
	end, "Third simultaneous source is rejected instead of allocating another slot")
	local slotBuffers = {}
	for _, slot in manager.Slots do
		table.insert(slotBuffers, { slot.ThetaTarget, slot.WaterTarget, slot.Weights })
	end
	local steps = if quick then 24 else 160
	local sawForcing, sawCondensation = false, false
	for tick = 1, steps do
		local forcing = manager:PrepareStep(tick, 0.25)
		check(
			forcing == manager:PrepareStep(tick, 0.25),
			"Source preparation is idempotent after rejected physical attempts"
		)
		near(
			manager.Tick,
			tick - 1,
			0,
			"Prepared source construction does not advance committed clock"
		)
		check(
			manager.SamplesLastStep <= manager.BuildSamplesPerStep,
			"Procedural noise samples are bounded per step"
		)
		if forcing then
			sawForcing = true
			for index = 0, count - 1 do
				local support = buffer.readf64(forcing.Weights, index * 8)
				check(
					support >= 0 and support <= 1 and support == support,
					"World source support weights remain bounded"
				)
			end
		end
		field:Step(0.25, forcing)
		manager:CommitStep(tick)
		for index = 0, count - 1 do
			sawCondensation = sawCondensation or buffer.readf64(field.Fields.qc, index * 8) > 1e-10
		end
		near(manager.Tick, tick, 0, "Schedule advances only after successful world physics")
		near(field.Time, tick * 0.25, 0, "Adding sources preserves physical timeline")
	end
	check(sawForcing, "Time-sliced source geometry eventually becomes active forcing")
	check(
		sawCondensation,
		"Subsaturated initialized sources develop qc through actual transport and microphysics"
	)
	check(
		field.ExternalWaterSum > 0 and field.ExternalThetaSum > 0,
		"Ongoing source moisture and heat are accounted explicitly"
	)
	check(
		field.ExternalWaterSum <= manager.WaterBudget + 1e-12
			and field.ExternalThetaSum <= manager.ThetaBudget + 1e-12,
		"Source injection remains within cumulative budgets"
	)
	for i, slot in manager.Slots do
		check(
			slot.ThetaTarget == slotBuffers[i][1]
				and slot.WaterTarget == slotBuffers[i][2]
				and slot.Weights == slotBuffers[i][3],
			"World source targets reuse packed buffers across all steps"
		)
	end
	local scheduled, scheduler = create(-39, "Few", true)
	local scheduledRepeat, schedulerRepeat = create(-39, "Few", true)
	for tick = 1, 16 do
		local a = scheduler:PrepareStep(tick, 0.25)
		local b = schedulerRepeat:PrepareStep(tick, 0.25)
		scheduled:Step(0.25, a)
		scheduler:CommitStep(tick)
		scheduledRepeat:Step(0.25, b)
		schedulerRepeat:CommitStep(tick)
	end
	check(
		scheduler.ScheduledSources == 2 and scheduler.Opportunities == 2,
		"World events schedule by committed tick without wall-clock input"
	)
	check(
		scheduler.LastSourceId == schedulerRepeat.LastSourceId
			and buffer.tostring(scheduled.Fields.qv)
				== buffer.tostring(scheduledRepeat.Fields.qv),
		"Repeated source schedules and transport are deterministic"
	)
	scheduler:SetAutoClouds(false)
	local existing = scheduler:GetDiagnostics().PendingSources
	for tick = 17, 24 do
		scheduled:Step(0.25, scheduler:PrepareStep(tick, 0.25))
		scheduler:CommitStep(tick)
	end
	check(
		scheduler.ScheduledSources == 2 and scheduler.Opportunities == 3,
		"Disabled opportunities do not add new sources"
	)
	check(
		scheduler:GetDiagnostics().PendingSources <= existing,
		"Disabling scheduled events preserves already accepted sources"
	)
	rejects(function()
		Sources.new(field, { Seed = 0, InitialSourceCount = 17 })
	end, "World source count cannot exceed sixteen")
	rejects(function()
		Sources.new(field, { Seed = 0, BuildSamplesPerStep = 513 })
	end, "Noise workload limit is validated")
	rejects(function()
		Sources.new(field, { Seed = 0, Coverage = "rain" })
	end, "Unimplemented coverage modes are rejected")
	return {
		InitialSourceCount = manager.InitialSourceCount,
		DistinctSourceRegions = distinctCount,
		SourceBuildSamplesPerStep = manager.BuildSamplesPerStep,
		SourceBuffers = 9,
		SourceBufferBytes = count * 8 * 9,
		ExternalWaterSum = field.ExternalWaterSum,
		ExternalThetaSum = field.ExternalThetaSum,
		Steps = steps,
	}
end
