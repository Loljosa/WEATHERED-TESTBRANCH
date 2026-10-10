--!strict

local roblox = require("@lune/roblox")
local createLoader = require("./RobloxModuleLoader")

return function(root: any, loadModule: any, check: any, near: any, rejects: any)
	local Atmosphere = loadModule(root)
	local Grid3D = loadModule(root.Core.Grid3D)
	local Saturation = loadModule(root.Thermodynamics.Saturation)
	local Thermodynamics = loadModule(root.Thermodynamics.Thermodynamics)
	local service = { Shared = { Atmosphere = root } }
	local serverRoot, loadServer = createLoader("src/server/Simulation", {
		game = {
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage", "Unexpected seeded manager service")
				return service
			end,
		},
	})
	local Scheduler = loadServer(serverRoot.CloudFormationScheduler)
	local Manager = loadServer(serverRoot.CloudSourceManager)
	local scheduleA = Scheduler.new(-84219, { IntervalTicks = 3 })
	local scheduleB = Scheduler.new(-84219, { IntervalTicks = 3 })
	local events, quiet = 0, 0
	for tick = 1, 360 do
		local first, opportunity = scheduleA:Prepare(tick)
		local repeated, repeatedOpportunity = scheduleA:Prepare(tick)
		local second, secondOpportunity = scheduleB:Prepare(tick)
		check(
			first == repeated and opportunity == repeatedOpportunity,
			"Uncommitted schedule preparation is idempotent"
		)
		check(
			first == second and opportunity == secondOpportunity,
			"Same seed and committed tick reproduce the schedule"
		)
		near(scheduleA.Tick, tick - 1, 0, "Preparation does not advance the scheduler clock")
		if opportunity > 0 then
			if first then
				events += 1
			else
				quiet += 1
			end
		end
		scheduleA:Commit(tick)
		scheduleB:Commit(tick)
	end
	check(events > 0 and quiet > 0, "Seeded scheduling includes formation and quiet intervals")
	near(scheduleA.Opportunities, 120, 0, "Every opportunity is bounded by the configured interval")
	local disabled =
		Scheduler.new(0, { IntervalTicks = 1, Enabled = false, FormationProbability = 1 })
	for tick = 1, 4 do
		check(not disabled:Prepare(tick), "Disabled scheduling does not generate new events")
		disabled:Commit(tick)
	end
	disabled:SetEnabled(true)
	check(disabled:Prepare(5), "Re-enabled schedule resumes at the current physical tick")
	rejects(function()
		disabled:SetEnabled(false)
	end, "Uncommitted schedule settings cannot change")
	disabled:Commit(5)
	rejects(function()
		disabled:Prepare(7)
	end, "Scheduler rejects skipped physical ticks")
	rejects(function()
		Scheduler.new(0, { IntervalTicks = 0 })
	end, "Scheduler rejects invalid intervals")
	rejects(function()
		Scheduler.new(0, { FormationProbability = 2 })
	end, "Scheduler rejects invalid probability")

	local grid =
		Grid3D.new(7, 6, 7, 12, roblox.Vector3.new(-42, 424, -42), { Dx = 150, Dy = 100, Dz = 150 })
	local function fixture(settings: any?): (any, any)
		local simulation =
			Atmosphere.new(grid, { DisableBubble = true, BackgroundU = 2, BackgroundV = 1 })
		local options = settings or { Seed = 84219, InitialSourceCount = 2, AutoClouds = false }
		local manager = Manager.new(simulation, options)
		manager:InitializeSources()
		return simulation, manager
	end
	local simulation, manager = fixture()
	local repeatedSimulation, repeatedManager = fixture()
	for _, name in { "theta", "qv", "qc", "qr", "u", "v", "w", "pressure" } do
		check(
			buffer.tostring(simulation.State.Fields[name])
				== buffer.tostring(repeatedSimulation.State.Fields[name]),
			"Same world seed reproduces initialized packed fields"
		)
	end
	for index = 1, grid.Count do
		near(
			simulation.State:Get("qc", index),
			0,
			0,
			"Procedural initialization never paints cloud water"
		)
		near(
			simulation.State:Get("qr", index),
			0,
			0,
			"Procedural initialization never paints rain water"
		)
		local pressure = simulation.State:Get("pressure", index)
		local temperature =
			Thermodynamics.Temperature(simulation.State:Get("theta", index), pressure)
		check(
			simulation.State:Get("qv", index)
				<= Saturation.MixingRatio(temperature, pressure) + 1e-9,
			"Initial seeded source remains unsaturated"
		)
	end
	near(simulation.ExternalWaterSum, 0, 0, "Initial sources establish the water baseline")
	near(simulation.ExternalThetaSum, 0, 0, "Initial sources establish the thermal baseline")
	near(
		manager:GetDiagnostics().InitialSourceSamples,
		grid.Count * 2,
		0,
		"Initial source compilation is explicitly counted"
	)
	near(
		manager:GetDiagnostics().SourceSamplesTotal,
		0,
		0,
		"Initial compilation is separate from ongoing work"
	)
	rejects(function()
		manager:InitializeSources()
	end, "Seeded initialization cannot reset an existing atmosphere")
	local bytes: { [string]: string } = {}
	for _, name in { "theta", "qv", "qc", "qr", "u", "v", "w", "pressure" } do
		bytes[name] = buffer.tostring(simulation.State.Fields[name])
	end
	local firstId, secondId = manager:QueueSource(), manager:QueueSource()
	check(firstId ~= secondId, "Simultaneous queued sources have unique deterministic identifiers")
	check(
		firstId == repeatedManager:QueueSource() and secondId == repeatedManager:QueueSource(),
		"Repeated seeded commands reproduce event identities"
	)
	for name, saved in bytes do
		check(
			buffer.tostring(simulation.State.Fields[name]) == saved,
			"Queuing another source preserves all atmospheric fields"
		)
	end
	near(simulation.Time, 0, 0, "Queuing sources preserves simulation time")
	rejects(function()
		manager:QueueSource()
	end, "Source queue has a bounded simultaneous capacity")
	local prepared = manager:PrepareStep(1)
	local samples = manager:GetDiagnostics().SourceSamplesTotal
	check(
		manager:PrepareStep(1) == prepared,
		"Preparing a source tick twice reuses the forcing object"
	)
	near(
		manager:GetDiagnostics().SourceSamplesTotal,
		samples,
		0,
		"Retrying a prepared tick does not repeat geometry work"
	)
	check(
		manager:GetDiagnostics().SourceSamplesLastStep <= 128,
		"Procedural build work is bounded per physical tick"
	)
	local maximumIterations = simulation.Projection.MaxIterations
	simulation.Projection.MaxIterations = 1
	local succeeded = pcall(function()
		simulation:Step(0.25, prepared)
	end)
	check(not succeeded, "Projection failure provides a rejected forced-step fixture")
	near(manager.Tick, 0, 0, "A rejected physics step does not advance source event ages")
	near(manager.Scheduler.Tick, 0, 0, "A rejected physics step does not advance scheduling")
	near(simulation.Time, 0, 0, "A rejected source tick preserves simulation time")
	near(
		simulation.ExternalWaterSum,
		0,
		0,
		"A rejected source tick preserves the moisture input ledger"
	)
	for name, saved in bytes do
		check(
			buffer.tostring(simulation.State.Fields[name]) == saved,
			"A rejected source tick preserves every physical field"
		)
	end
	simulation.Projection.MaxIterations = maximumIterations
	for tick = 1, 44 do
		local forcing = manager:PrepareStep(tick)
		local repeatedForcing = repeatedManager:PrepareStep(tick)
		if tick == 3 then
			check(forcing ~= nil, "A compiled source supplies real forcing to the failed-step test")
			local waterBefore, thetaBefore =
				simulation.ExternalWaterSum, simulation.ExternalThetaSum
			local ageBefore = manager.Slots[1].AgeSeconds
			local thetaBytes = buffer.tostring(simulation.State.Fields.theta)
			local vaporBytes = buffer.tostring(simulation.State.Fields.qv)
			simulation.Projection.MaxIterations = 1
			rejects(function()
				simulation:Step(0.25, forcing)
			end, "Forced projection failure rejects staged thermal and moisture inputs")
			near(simulation.Time, 0.5, 0, "A failed forced step preserves the committed clock")
			near(
				simulation.ExternalWaterSum,
				waterBefore,
				0,
				"A failed forced step preserves represented moisture accounting"
			)
			near(
				simulation.ExternalThetaSum,
				thetaBefore,
				0,
				"A failed forced step preserves represented thermal accounting"
			)
			near(
				manager.Slots[1].AgeSeconds,
				ageBefore,
				0,
				"A failed forced step preserves the source lifetime"
			)
			check(
				buffer.tostring(simulation.State.Fields.theta) == thetaBytes
					and buffer.tostring(simulation.State.Fields.qv) == vaporBytes,
				"Forced failure preserves both public scalar buffers"
			)
			check(
				manager:PrepareStep(tick) == forcing,
				"A forced retry uses the identical cached targets"
			)
			simulation.Projection.MaxIterations = maximumIterations
		end
		simulation:Step(0.25, forcing)
		repeatedSimulation:Step(0.25, repeatedForcing)
		manager:CommitStep(tick)
		repeatedManager:CommitStep(tick)
		check(
			manager:GetDiagnostics().SourceSamplesLastStep <= 128,
			"Ongoing noise compilation stays within its sample budget"
		)
	end
	for _, name in { "theta", "qv", "qc", "qr", "u", "v", "w", "pressure" } do
		check(
			buffer.tostring(simulation.State.Fields[name])
				== buffer.tostring(repeatedSimulation.State.Fields[name]),
			"Cached failed-step retry reproduces fresh seeded evolution"
		)
	end
	near(
		manager:GetDiagnostics().PendingSources,
		0,
		0,
		"Finite formation events release their reusable slots"
	)
	near(
		manager:GetDiagnostics().SourceSamplesTotal,
		grid.Count * 2,
		0,
		"Each queued source evaluates exactly one grid of geometry"
	)
	check(
		simulation.ExternalWaterSum > 0 and simulation.ExternalThetaSum > 0,
		"New sources track represented external moisture and heating"
	)
	check(
		math.abs(simulation:GetDiagnostics().WaterDriftFraction) < 1e-6,
		"External forcing is removed from numerical water drift"
	)
	check(
		simulation.ExternalWaterSum <= manager.WaterBudget
			and simulation.ExternalThetaSum <= manager.ThetaBudget,
		"Cumulative inputs stay within finite sealed-domain budgets"
	)

	local automaticSimulation, automaticManager = fixture({
		Seed = 0,
		InitialSourceCount = 1,
		FormationIntervalTicks = 1,
		FormationProbability = 1,
		FormationDurationSeconds = 0.25,
		BuildSamplesPerStep = 512,
	})
	for tick = 1, 3 do
		local forcing = automaticManager:PrepareStep(tick)
		automaticSimulation:Step(0.25, forcing)
		automaticManager:CommitStep(tick)
	end
	near(
		automaticManager:GetDiagnostics().ScheduledSources,
		3,
		0,
		"Deterministic ongoing events form without atmosphere resets"
	)
	near(
		automaticSimulation.Time,
		0.75,
		0,
		"Automatic events preserve a continuous simulation clock"
	)
	automaticManager:SetAutoClouds(false)
	local force = automaticManager:PrepareStep(4)
	automaticSimulation:Step(0.25, force)
	automaticManager:CommitStep(4)
	near(
		automaticManager:GetDiagnostics().ScheduledSources,
		3,
		0,
		"Disabling auto clouds suppresses new source events"
	)
	local supportedSimulation, supportedManager = fixture({
		Seed = 84219,
		InitialSourceCount = 1,
		AutoClouds = false,
		BuildSamplesPerStep = 512,
	})
	supportedManager:QueueSource()
	local supportedForcing = supportedManager:PrepareStep(1)
	check(
		supportedForcing ~= nil and supportedForcing.Weights ~= nil,
		"Compiled ongoing sources carry explicit local support"
	)
	local outsideIndex, insideIndex = 0, 0
	for index = 1, grid.Count do
		local weight = buffer.readf32(supportedForcing.Weights, (index - 1) * 4)
		if weight == 0 and outsideIndex == 0 then
			outsideIndex = index
		end
		if weight > 0 and insideIndex == 0 then
			insideIndex = index
		end
	end
	check(
		outsideIndex > 0 and insideIndex > 0,
		"Source support resolves clear outside cells and a nonzero interior"
	)
	local _, outsideY = grid:Coordinates(outsideIndex)
	local _, insideY = grid:Coordinates(insideIndex)
	supportedSimulation.State:Set(
		"theta",
		outsideIndex,
		buffer.readf32(supportedSimulation.Profile.Theta, (outsideY - 1) * 4) - 1
	)
	supportedSimulation.State:Set(
		"qv",
		outsideIndex,
		buffer.readf32(supportedSimulation.Profile.Qv, (outsideY - 1) * 4) * 0.5
	)
	supportedSimulation.State:Set(
		"theta",
		insideIndex,
		buffer.readf32(supportedSimulation.Profile.Theta, (insideY - 1) * 4) - 1
	)
	supportedSimulation.State:Set("qv", insideIndex, 0)
	local outsideTheta = supportedSimulation.State:Get("theta", outsideIndex)
	local outsideVapor = supportedSimulation.State:Get("qv", outsideIndex)
	local insideTheta = supportedSimulation.State:Get("theta", insideIndex)
	local input = supportedSimulation:InjectSource(supportedForcing)
	near(
		supportedSimulation.State:Get("theta", outsideIndex),
		outsideTheta,
		0,
		"Source forcing never restores advected cold air outside its geometry"
	)
	near(
		supportedSimulation.State:Get("qv", outsideIndex),
		outsideVapor,
		0,
		"Source forcing never restores advected dry air outside its geometry"
	)
	check(
		supportedSimulation.State:Get("theta", insideIndex) > insideTheta
			and supportedSimulation.State:Get("qv", insideIndex) > 0,
		"Supported source interiors receive real positive heating and vapor"
	)
	check(
		input.WaterSum > 0 and input.ThetaSum > 0,
		"Locally supported injection records its represented inputs"
	)
	local exhaustedSimulation, exhaustedManager = fixture({
		Seed = -1,
		InitialSourceCount = 1,
		AutoClouds = false,
		MaxExternalWaterFraction = 0,
		MaxExternalThetaPerCell = 0,
	})
	rejects(function()
		exhaustedManager:QueueSource()
	end, "Exhausted forcing budgets reject additional sources clearly")
	local noForce = exhaustedManager:PrepareStep(1)
	check(noForce == nil, "Exhausted source manager still permits ordinary unforced physics")
	exhaustedSimulation:Step(0.25, noForce)
	exhaustedManager:CommitStep(1)
	check(
		exhaustedManager:GetDiagnostics().SourceBudgetExhausted,
		"Diagnostics identify finite-budget exhaustion"
	)
	rejects(function()
		Manager.new(simulation, { Seed = 0, InitialSourceCount = 7 })
	end, "Initial source count obeys validated preset limits")
	rejects(function()
		Manager.new(simulation, { Seed = 0, BuildSamplesPerStep = 513 })
	end, "Procedural work limits reject unsupported batches")
	local zeroIntensitySimulation, zeroIntensityManager =
		fixture({ Seed = 0, InitialSourceCount = 1, SourceIntensity = 0, AutoClouds = false })
	for index = 1, grid.Count do
		local _, y = grid:Coordinates(index)
		near(
			zeroIntensitySimulation.State:Get("theta", index),
			buffer.readf32(zeroIntensitySimulation.Profile.Theta, (y - 1) * 4),
			0,
			"Zero source intensity leaves the environmental temperature intact"
		)
		near(
			zeroIntensitySimulation.State:Get("qv", index),
			buffer.readf32(zeroIntensitySimulation.Profile.Qv, (y - 1) * 4),
			0,
			"Zero source intensity leaves the environmental vapor intact"
		)
	end
	near(
		zeroIntensityManager:GetDiagnostics().SourceIntensity,
		0,
		0,
		"Seed diagnostics expose configurable source intensity"
	)
	rejects(function()
		Manager.new(simulation, { Seed = 0, SourceIntensity = 1.1 })
	end, "Source intensity rejects unsupported multipliers")
	print(
		"PASS: deterministic bounded source scheduling, cached geometry, initialization, atomic failed-step retry, external accounting and finite formation lifetimes"
	)
end
