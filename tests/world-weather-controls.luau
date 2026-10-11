--!strict

local createLoader = require("./RobloxModuleLoader")

-- This test exercises the real server controller, command parser, world field,
-- scheduler and optional MAC coupling. Only the Roblox service lookup is mocked.
return function(root: any, _loadModule: any, check: any, near: any, rejects: any, _quick: boolean?)
	local serverRoot, loadServer = createLoader("src/server/Simulation", {
		game = {
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage", "Unexpected service in world controls test")
				return { Shared = { Atmosphere = root } }
			end,
		},
		print = function() end,
		warn = function() end,
	})
	local Controller = loadServer(serverRoot.WorldWeatherController)
	local Controls = loadServer(serverRoot.WorldWeatherControls)
	local function settings(preset: string?): any
		return {
			Seed = 0,
			SeedSource = "TestCanonical",
			Preset = preset or "Laptop",
			Coverage = "Clear",
			AutoClouds = false,
			InitialSourceCount = 0,
			BackgroundU = 2,
			BackgroundV = 1,
			Clock = function(): number
				return 0
			end,
		}
	end
	local function copyOptions(options: any): any
		return table.clone(options)
	end
	local function sameOptions(actual: any, expected: any, message: string)
		for key, value in expected do
			check(actual[key] == value, message .. ": " .. tostring(key))
		end
		for key, value in actual do
			check(expected[key] == value, message .. ": no new " .. tostring(key))
		end
	end
	local function fieldBytes(field: any): any
		local result = {}
		for name, value in field.Fields do
			result[name] = buffer.tostring(value)
		end
		result.FacesU, result.FacesV, result.FacesW =
			buffer.tostring(field.FacesU),
			buffer.tostring(field.FacesV),
			buffer.tostring(field.FacesW)
		return result
	end
	local function sameFields(field: any, expected: any, message: string, includeVelocity: boolean?)
		for name, value in expected do
			local velocity = name == "u"
				or name == "v"
				or name == "w"
				or string.sub(name, 1, 5) == "Faces"
			if includeVelocity ~= false or not velocity then
				local current = field.Fields[name] or field[name]
				check(buffer.tostring(current) == value, message .. ": " .. name)
			end
		end
	end
	local function sourceStatus(manager: any): any
		local diagnostic = manager:GetDiagnostics()
		return {
			Tick = diagnostic.SourceTick,
			Seed = diagnostic.WorldSeed,
			Coverage = diagnostic.Coverage,
			Count = diagnostic.InitialSourceCount,
			Event = diagnostic.NextSourceEventIndex,
			Manual = diagnostic.ManualSources,
			Pending = diagnostic.PendingSources,
			Building = diagnostic.BuildingSources,
			Active = diagnostic.ActiveSources,
			Opportunities = diagnostic.ScheduledOpportunities,
			Scheduled = diagnostic.ScheduledSources,
			Samples = diagnostic.SourceSamplesTotal,
			WaterBudget = diagnostic.SourceWaterBudgetRemaining,
			ThetaBudget = diagnostic.SourceThetaBudgetRemaining,
			Auto = diagnostic.AutoClouds,
		}
	end

	local controller = Controller.new(settings())
	local controls = Controls.new(controller)
	local initial = controller.Field
	local initialBytes = fieldBytes(initial)
	near(initial.SizeX, 32, 0, "Laptop world grid keeps bounded horizontal resolution")
	near(initial.SizeY, 6, 0, "World field uses six bounded atmospheric layers")
	near(
		initial.SizeZ,
		32,
		0,
		"Laptop world grid spans the full world without local-cell explosion"
	)
	near(initial.Coordinates.WidthStuds, 4028, 0, "Controller owns exactly 4028-stud width")
	near(initial.Coordinates.DepthStuds, 4028, 0, "Controller owns exactly 4028-stud depth")
	check(not controller.Coupling.Enabled, "Local MAC detail is explicitly disabled by default")
	check(
		controller.Coupling.Simulation == nil,
		"Default world construction allocates no local MAC solver"
	)
	near(
		controller.Coupling:GetDiagnostics().BufferBytes,
		0,
		0,
		"Default detail contributes no solver buffers"
	)
	for index = 1, initial.Count do
		near(
			initial.State:Get("qc", index),
			0,
			0,
			"New clear atmosphere contains no painted cloud water"
		)
	end
	for _, command in { "worldsize", "worldsize 4028", "WoRlDsIzE 4028" } do
		local result = controls:ExecuteText(command)
		near(result.WidthStuds, 4028, 0, "World size command reports exact width")
		near(result.DepthStuds, 4028, 0, "World size command reports exact depth")
		check(
			result.Coordinates == initial.Coordinates,
			"World size validation preserves active geometry"
		)
	end
	local regions = controls:ExecuteText("weatherregions")
	near(#regions, 16, 0, "Weather regions command reports all sixteen logical regions")
	local regionalWater = 0
	for id, region in regions do
		near(region.Id, id, 0, "Region diagnostics use stable world IDs")
		check(
			region.Active and region.Processing == "GlobalSharedField",
			"Logical regions share one authoritative physics field"
		)
		near(
			region.Bounds.WidthStuds,
			1007,
			0,
			"Diagnostic region bounds preserve exact world tiling"
		)
		regionalWater += region.QvSum + region.QcSum + region.QrSum
	end
	near(
		regionalWater,
		controller:GetDiagnostics().WaterSum,
		1e-10,
		"Region reports do not duplicate the world water inventory"
	)
	local active = controls:ExecuteText("seedstatus")
	near(active.WorldSeed, 0, 0, "Canonical zero seed remains valid through world commands")
	check(active.Coverage == "Clear", "Active coverage scenario is diagnosed")
	controls:ExecuteText("seed -2147483648")
	controls:ExecuteText("cloudcoverage broken")
	controls:ExecuteText("cloudcount 3")
	local pending = controls:ExecuteText("seedstatus")
	near(pending.WorldSeed, 0, 0, "Next seed selection does not change active weather")
	near(
		pending.NextWorldSeed,
		-2147483648,
		0,
		"Signed minimum seed can be selected for regeneration"
	)
	check(
		pending.Coverage == "Clear" and pending.NextCoverage == "Broken",
		"Coverage command separates active and next settings"
	)
	near(
		pending.NextInitialSourceCount,
		3,
		0,
		"Source count is selected for the next initialization"
	)
	check(
		controller.Field == initial,
		"Seed, coverage and count selection retain authoritative field ownership"
	)
	sameFields(initial, initialBytes, "Next initialization settings preserve field bytes")
	for _, command in
		{
			"worldsize 2014",
			"worldsize 4029",
			"worldsize nope",
			"worldsize 4028 extra",
			"weatherregions extra",
			"cloudmotion extra",
			"seed",
			"seed 1.5",
			"seed 2147483648",
			"seed -2147483649",
			"seed nan",
			"seed 3 extra",
			"cloudcount",
			"cloudcount -1",
			"cloudcount 1.5",
			"cloudcount 17",
			"cloudcoverage",
			"cloudcoverage rainy",
			"autoclouds true",
			"debugregions true",
			"debugvectors false",
			"detail yes",
			"wind",
			"wind 8",
			"wind 101 0",
			"wind 0 -101",
			"wind nan 2",
			"wind 8 2 extra",
			"speed 0",
			"speed 4.01",
			"speed nan",
			"form 0",
			"form 240.25",
			"form 0.3",
			"pause extra",
			"spawnseeded extra",
			"regenerate extra",
			"unknown",
			"",
			"   ",
			string.rep("a", 129),
		}
	do
		local nextOptions = copyOptions(controller.NextOptions)
		local currentOptions = copyOptions(controller.Options)
		local beforeSource = sourceStatus(controller.Sources)
		local beforeTime, beforeTick = controller.Field.Time, controller.Tick
		local beforeSpeed, beforePause = controller.Speed, controller.Paused
		local beforeDebugRegions, beforeDebugVectors =
			controller.DebugRegions, controller.DebugVectors
		rejects(function()
			controls:ExecuteText(command)
		end, "World commands reject malformed input: " .. command)
		check(controller.Field == initial, "Rejected command cannot replace the atmosphere")
		sameFields(initial, initialBytes, "Rejected command preserves all physical buffers")
		sameOptions(controller.NextOptions, nextOptions, "Rejected command preserves next options")
		sameOptions(controller.Options, currentOptions, "Rejected command preserves active options")
		sameOptions(
			sourceStatus(controller.Sources),
			beforeSource,
			"Rejected command preserves source scheduler"
		)
		near(controller.Field.Time, beforeTime, 0, "Rejected command preserves simulated time")
		near(controller.Tick, beforeTick, 0, "Rejected command preserves fixed tick")
		near(controller.Speed, beforeSpeed, 0, "Rejected command preserves playback speed")
		check(controller.Paused == beforePause, "Rejected command preserves pause state")
		check(
			controller.DebugRegions == beforeDebugRegions
				and controller.DebugVectors == beforeDebugVectors,
			"Rejected command preserves debug flags"
		)
	end
	for _, flag in { "debugregions", "debugvectors" } do
		controls:ExecuteText(flag .. " on")
		check(
			if flag == "debugregions" then controller.DebugRegions else controller.DebugVectors,
			"Developer visualization flag can be enabled"
		)
		controls:ExecuteText(flag .. " off")
		check(
			not (
					if flag == "debugregions"
						then controller.DebugRegions
						else controller.DebugVectors
				),
			"Developer visualization flag can be disabled"
		)
	end
	controls:ExecuteText("autoclouds on")
	check(controller.Sources.AutoClouds, "Autoclouds on changes the authoritative scheduler")
	controls:ExecuteText("autoclouds off")
	check(
		not controller.Sources.AutoClouds,
		"Autoclouds off preserves clouds while preventing new scheduled events"
	)
	controls:ExecuteText("wind 8 -2")
	near(initial.BackgroundU, 8, 0, "Wind X is applied live in physical meters per second")
	near(initial.BackgroundV, -2, 0, "Wind Z is applied live in physical meters per second")
	near(controller.Field.Time, 0, 0, "Wind command does not restart or advance the atmosphere")
	sameFields(initial, initialBytes, "Live wind preserves temperature and water bytes", false)
	controls:ExecuteText("regenerate")
	check(controller.Field ~= initial, "Explicit regeneration replaces the authoritative field")
	near(controller.Field.Time, 0, 0, "Explicit regeneration resets physical time")
	near(controller.Tick, 0, 0, "Explicit regeneration resets committed tick")
	near(controller.Sources.Seed, -2147483648, 0, "Regeneration applies the selected signed seed")
	check(
		controller.Sources.Scenario.Name == "Broken",
		"Regeneration applies the selected coverage conditions"
	)
	near(
		controller.Sources.InitialSourceCount,
		3,
		0,
		"Regeneration applies the selected number of sources"
	)
	near(controller.Field.BackgroundU, 8, 0, "Regeneration retains configured live X wind")
	near(controller.Field.BackgroundV, -2, 0, "Regeneration retains configured live Z wind")
	check(
		not controller.Coupling.Enabled,
		"Regeneration keeps expensive detail disabled by default"
	)
	for index = 1, controller.Field.Count do
		near(
			controller.Field.State:Get("qc", index),
			0,
			0,
			"Seeded regeneration still starts without directly painted qc"
		)
	end
	local seededField = controller.Field
	controller:Advance(0.25)
	local beforeSpawn = fieldBytes(seededField)
	local beforeTime = seededField.Time
	local beforeBudget = seededField.ExternalWaterSum
	local id = controls:ExecuteText("spawnseeded")
	check(
		type(id) == "string" and #id > 0,
		"Nonreset spawn returns a deterministic source identifier"
	)
	check(controller.Field == seededField, "Nonreset source queue retains the current atmosphere")
	near(seededField.Time, beforeTime, 0, "Nonreset source queue preserves physical time")
	near(
		seededField.ExternalWaterSum,
		beforeBudget,
		0,
		"Queueing does not fabricate immediate external moisture"
	)
	sameFields(seededField, beforeSpawn, "Queueing a source does not alter current field bytes")
	near(
		controller.Sources:GetDiagnostics().ManualSources,
		1,
		0,
		"Manual source request is diagnosed"
	)
	near(
		controller.Sources:GetDiagnostics().PendingSources,
		1,
		0,
		"Manual source remains in the bounded preparation queue"
	)
	controls:ExecuteText("spawnseeded")
	near(
		controller.Sources:GetDiagnostics().PendingSources,
		2,
		0,
		"At most two independent source jobs can be queued"
	)
	local queued = sourceStatus(controller.Sources)
	rejects(function()
		controls:ExecuteText("spawnseeded")
	end, "A full queue rejects excess source work")
	sameOptions(
		sourceStatus(controller.Sources),
		queued,
		"Queue overflow preserves deterministic scheduling"
	)
	local tickBeforePause, timeBeforePause = controller.Tick, seededField.Time
	controls:ExecuteText("pause")
	near(controller:Advance(2), 0, 0, "Paused controller executes no physical steps")
	near(controller.Tick, tickBeforePause, 0, "Pause preserves committed physics tick")
	near(seededField.Time, timeBeforePause, 0, "Pause preserves simulation time")
	near(
		controller.Sources.Tick,
		tickBeforePause,
		0,
		"Pause preserves deterministic source timeline"
	)
	near(controller.WallTime, 2.25, 0, "Wall-time diagnostics continue during pause")
	controls:ExecuteText("resume")
	for _ = 1, 3 do
		near(
			controller:Advance(0.25),
			1,
			0,
			"Resumed controller advances one conservative fixed step"
		)
	end
	near(seededField.Time, timeBeforePause + 0.75, 0, "Resume advances only actual executed time")
	check(
		controller.Sources:GetDiagnostics().SourceSamplesLastStep <= 128,
		"Laptop source construction remains time-sliced"
	)
	near(
		controller.Sources.Tick,
		controller.Tick,
		0,
		"Source scheduler follows committed world tick exactly"
	)
	controls:ExecuteText("speed 4")
	local timeBeforeCatchup, tickBeforeCatchup = seededField.Time, controller.Tick
	near(controller:Advance(1), 1, 0, "Laptop catches up no more than one physics step per frame")
	near(
		seededField.Time,
		timeBeforeCatchup + 0.25,
		0,
		"Dropped simulation backlog does not count as integrated physical time"
	)
	near(
		controller.Tick,
		tickBeforeCatchup + 1,
		0,
		"Dropped steps do not advance authoritative tick"
	)
	near(
		controller.DroppedSteps,
		15,
		0,
		"Four seconds of requested playback reports fifteen dropped fixed steps"
	)
	near(controller.DroppedSimulationTime, 3.75, 0, "Dropped physical time is measured explicitly")
	controls:ExecuteText("speed 1")
	controls:ExecuteText("form 0.5")
	near(
		controller.FormationRemainingSeconds,
		0.5,
		0,
		"Formation preview queues bounded physical time"
	)
	controller:Advance(0.25)
	near(
		controller.FormationRemainingSeconds,
		0.25,
		0,
		"Only a committed fixed step reduces preview time"
	)
	controller:Advance(0.25)
	near(
		controller.FormationRemainingSeconds,
		0,
		0,
		"Preview completes after the requested committed steps"
	)
	controls:ExecuteText("detail on")
	check(
		controller.Coupling.Enabled and controller.Coupling.Simulation ~= nil,
		"Detail command activates exactly one optional local MAC diagnostic"
	)
	near(
		controller.Coupling:GetDiagnostics().AllocatedSolvers,
		1,
		0,
		"Detail allocation is bounded to one solver"
	)
	check(
		controller.Field == seededField,
		"Enabling detail preserves authoritative world ownership"
	)
	controls:ExecuteText("detail off")
	check(not controller.Coupling.Enabled, "Detail can be disabled without resetting the world")
	local originalAdvance = controller.Coupling.Advance
	controller.Coupling.Advance = function()
		error("Deliberate optional MAC failure")
	end
	local beforeFailureTick, beforeFailureTime = controller.Tick, seededField.Time
	controller:Advance(0.25)
	near(
		controller.Tick,
		beforeFailureTick + 1,
		0,
		"Optional MAC failure cannot invalidate a coarse-world commit"
	)
	near(
		seededField.Time,
		beforeFailureTime + 0.25,
		0,
		"Optional MAC failure cannot stall authoritative physical time"
	)
	check(
		controller.DetailError ~= nil
			and string.find(controller.DetailError, "Deliberate optional MAC failure", 1, true)
				~= nil,
		"Optional detail failure is reported explicitly"
	)
	check(not controller.Coupling.Enabled, "Failing optional detail is disabled")
	controller.Coupling.Advance = originalAdvance
	local diagnostics = controls:ExecuteText("cloudmotion")
	near(
		diagnostics.Time,
		seededField.Time,
		0,
		"Cloud motion command reports actual simulation time"
	)
	near(
		diagnostics.WallTime,
		controller.WallTime,
		0,
		"Cloud motion command distinguishes wall time"
	)
	near(
		diagnostics.DroppedSteps,
		controller.DroppedSteps,
		0,
		"Cloud motion command reports dropped steps"
	)
	near(
		diagnostics.ActiveRegions,
		16,
		0,
		"World diagnostics keep all logical regions spatially authoritative"
	)
	check(
		diagnostics.Sources.WorldSeed == controller.Sources.Seed,
		"World diagnostics include canonical source seed"
	)
	local beforeExperiment = fieldBytes(seededField)
	local experimentTime = seededField.Time
	controls:ExecuteText("spawn Wide Fast 1.25")
	check(
		controller.Coupling.Mode == "LegacyExperiment",
		"Legacy spawn remains an explicitly isolated local experiment"
	)
	check(
		controller.Coupling.ExperimentConfig.BubbleShape == "Wide",
		"Legacy shape command selects the local source geometry"
	)
	near(
		controller.Coupling.ExperimentConfig.BubbleScale,
		1.25,
		0,
		"Legacy shape size remains configurable"
	)
	near(
		controller.Coupling.ExperimentConfig.BubbleRelativeHumidity,
		0.9999,
		0,
		"Fast condensation selects the existing local thermodynamic profile"
	)
	controls:ExecuteText("size 0.75")
	near(
		controller.Coupling.ExperimentConfig.BubbleScale,
		0.75,
		0,
		"Legacy size command preserves its working API"
	)
	check(
		controller.Coupling.ExperimentConfig.BubbleShape == "Wide",
		"Legacy size preserves the selected source shape"
	)
	controls:ExecuteText("condensation Normal")
	near(
		controller.Coupling.ExperimentConfig.BubbleRelativeHumidity,
		0.999,
		0,
		"Legacy condensation command preserves its working API"
	)
	near(
		seededField.Time,
		experimentTime,
		0,
		"Local experimental commands never reset world physical time"
	)
	sameFields(
		seededField,
		beforeExperiment,
		"Local experimental controls preserve every coarse field byte"
	)
	for _, command in
		{
			"spawn Wrong",
			"spawn Round Weird",
			"spawn Round Normal 0.49",
			"size 1.51",
			"size",
			"condensation",
			"condensation Weird",
		}
	do
		local experiment = controller.Coupling.Simulation
		local config = copyOptions(controller.Coupling.ExperimentConfig)
		rejects(function()
			controls:ExecuteText(command)
		end, "Legacy local controls reject invalid arguments: " .. command)
		check(
			controller.Coupling.Simulation == experiment,
			"Rejected local command preserves its existing solver"
		)
		sameOptions(
			controller.Coupling.ExperimentConfig,
			config,
			"Rejected local command preserves its configuration"
		)
		sameFields(
			seededField,
			beforeExperiment,
			"Rejected local control preserves authoritative world bytes"
		)
	end
	controls:ExecuteText("detail off")
	check(
		string.find(controls:ExecuteText("help"), "worldsize", 1, true) ~= nil,
		"Command help includes world controls"
	)
	for _, preset in { "Laptop", "Full" } do
		local testController = Controller.new(settings(preset))
		local expectedSize = if preset == "Full" then 48 else 32
		near(
			testController.Field.SizeX,
			expectedSize,
			0,
			"Both presets construct their validated world field"
		)
		near(
			testController.Field.SizeZ,
			expectedSize,
			0,
			"Both presets preserve bounded world resolution"
		)
		check(
			testController.Coupling.Simulation == nil,
			"Both presets leave local MAC detail unallocated by default"
		)
		near(testController:Advance(0.25), 1, 0, "Both presets execute a real fixed world step")
		near(testController.Field.Time, 0.25, 0, "Both presets preserve fixed physical dt")
		check(
			math.abs(testController:GetDiagnostics().WaterDriftFraction) < 1e-12,
			"Both presets keep water accounting meaningful"
		)
	end
	local segmented = Controller.new(settings())
	local whole = Controller.new(settings())
	for _ = 1, 4 do
		whole:Advance(0.25)
		segmented:Advance(0.125)
		segmented:Advance(0.125)
	end
	near(segmented.Tick, whole.Tick, 0, "Frame segmentation preserves fixed-step count")
	near(
		segmented.Field.Time,
		whole.Field.Time,
		0,
		"Frame segmentation preserves deterministic physical timeline"
	)
	sameFields(
		segmented.Field,
		fieldBytes(whole.Field),
		"Frame segmentation preserves all authoritative fields"
	)
	for _, value in { -1, math.huge, 0 / 0 } do
		rejects(function()
			segmented:Advance(value)
		end, "Invalid frame durations are reported rather than integrated")
	end
	-- Manufactured diagnostic samples, not a physical translation fixture. A
	-- sealed-domain centroid must never take a periodic shortcut through walls.
	local sealedOptions = settings()
	sealedOptions.Boundary, sealedOptions.BackgroundU, sealedOptions.BackgroundV = "Sealed", 0, 0
	local sealedController = Controller.new(sealedOptions)
	local sealedField = sealedController.Field
	sealedField.State:Set("qc", sealedField.Grid:Index(1, 3, 1), 0.001)
	local firstCentroid = sealedController:GetDiagnostics()
	sealedController:Advance(0.25)
	sealedField.State:Fill("qc", 0)
	sealedField.State:Set(
		"qc",
		sealedField.Grid:Index(sealedField.SizeX, 3, sealedField.SizeZ),
		0.001
	)
	local secondCentroid = sealedController:GetDiagnostics()
	local expectedX = sealedField.Coordinates.WidthMeters - sealedField.Dx
	local expectedZ = sealedField.Coordinates.DepthMeters - sealedField.Dz
	check(
		firstCentroid.CloudCentroidDefined and secondCentroid.CloudMotion.Defined,
		"Sealed centroid samples are defined"
	)
	near(
		secondCentroid.CloudMotion.XMeters,
		expectedX,
		1e-9,
		"Sealed centroid displacement uses direct X difference"
	)
	near(
		secondCentroid.CloudMotion.ZMeters,
		expectedZ,
		1e-9,
		"Sealed centroid displacement does not wrap through Z walls"
	)
	near(
		secondCentroid.CloudCentroidSampledPathMeters,
		math.sqrt(expectedX * expectedX + expectedZ * expectedZ),
		1e-9,
		"Sealed centroid path retains displacement greater than half the domain"
	)
	print(
		"World controls: server-only commands; exact coverage; nonreset sources; fixed timeline; optional detail isolation"
	)
end
