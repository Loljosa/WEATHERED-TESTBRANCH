--!strict

local createLoader = require("./RobloxModuleLoader")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

-- Exercise production server controls and fixed-step source scheduling. The
-- mocked service lookup supplies real atmosphere modules; no physics is cloned.
return function(root: any, _loadModule: any, check: any, near: any, rejects: any)
	local configuration = { BackgroundU = 2, BackgroundV = 1 }
	local generation = {
		Seed = 0,
		SeedSource = "TestCanonical",
		InitialSourceCount = 2,
		MaxInitialSources = 4,
		AutoClouds = false,
		BuildSamplesPerStep = 128,
	}
	local function setup(): (any, any)
		local serverRoot, loadServer = createLoader("src/server/Simulation", {
			game = {
				GetService = function(_self: any, name: string): any
					assert(name == "ReplicatedStorage")
					return { Shared = { Atmosphere = root } }
				end,
			},
			print = function() end,
			warn = function() end,
		})
		local controller = loadServer(serverRoot.SimulationController)
		controller.Initialize(configuration, {
			SizeX = 16,
			SizeY = 12,
			SizeZ = 16,
			Dx = 150,
			Dy = 100,
			Dz = 150,
		}, { MaxCatchUpSteps = 1 }, generation)
		local Controls = loadServer(serverRoot.CloudControls)
		return controller, Controls.new(configuration, function() end, function() end, generation)
	end
	local controller, controls = setup()
	local initial = controller.GetState()
	local captured = {}
	for name, field in initial.Fields do
		captured[name] = buffer.tostring(field)
	end
	local activeStatus = controls:ExecuteText("seedstatus")
	check(activeStatus.SeededGeneration, "Explicit generation options activate the source manager")
	near(activeStatus.WorldSeed, 0, 0, "Zero seed remains valid through server controls")
	near(activeStatus.InitialSourceCount, 2, 0, "Laptop test owns two independent initial sources")
	for index = 1, initial.Grid.Count do
		near(initial:Get("qc", index), 0, 0, "Seeded startup begins clear, never painted qc")
	end
	controls:ExecuteText("seed -2147483648")
	controls:ExecuteText("cloudcount 4")
	local nextStatus = controls:ExecuteText("seedstatus")
	near(nextStatus.WorldSeed, 0, 0, "Selecting the next seed leaves the active seed unchanged")
	near(
		nextStatus.NextWorldSeed,
		-2147483648,
		0,
		"Signed minimum seed is accepted for regeneration"
	)
	near(
		nextStatus.NextInitialSourceCount,
		4,
		0,
		"Preset source cap is accepted for next initialization"
	)
	check(
		controller.GetState() == initial,
		"Seed/count selections preserve authoritative state ownership"
	)
	for name, field in initial.Fields do
		check(
			buffer.tostring(field) == captured[name],
			"Seed/count selections preserve all field bytes"
		)
	end
	for _, command in
		{
			"seed",
			"seed 1.5",
			"seed 2147483648",
			"seed -2147483649",
			"seed nan",
			"seed 1 2",
			"cloudcount 0",
			"cloudcount 5",
			"cloudcount 1.1",
			"cloudcount",
			"autoclouds true",
			"autoclouds",
			"autoclouds on extra",
			"spawnseeded extra",
			"regenerate extra",
			"seedstatus extra",
		}
	do
		local before = serde.encode("json", controls.Generation)
		local status = serde.encode("json", controller.GetSeedStatus())
		rejects(function()
			controls:ExecuteText(command)
		end, "Seeded commands reject malformed input: " .. command)
		check(controller.GetState() == initial, "Rejected seeded command does not reset fields")
		check(
			serde.encode("json", controls.Generation) == before,
			"Rejected command preserves next-generation settings"
		)
		check(
			serde.encode("json", controller.GetSeedStatus()) == status,
			"Rejected command preserves the scheduler"
		)
	end
	controls:ExecuteText("autoclouds on")
	check(controller.GetSeedStatus().AutoClouds, "Autoclouds on changes the running scheduler")
	controls:ExecuteText("autoclouds off")
	check(not controller.GetSeedStatus().AutoClouds, "Autoclouds off prevents new scheduled events")
	controls:ExecuteText("spawnseeded")
	check(controller.GetState() == initial, "Nonreset spawn retains state ownership")
	near(controller.GetTime(), 0, 0, "Nonreset spawn retains physical time")
	for name, field in initial.Fields do
		check(
			buffer.tostring(field) == captured[name],
			"Queued source does not synchronously alter fields"
		)
	end
	near(controller.GetSeedStatus().ManualSources, 1, 0, "Queued manual source is diagnosed")
	local firstId = controller.GetSeedStatus().LastSourceId
	local other, otherControls = setup()
	otherControls:ExecuteText("spawnseeded")
	check(
		other.GetSeedStatus().LastSourceId == firstId,
		"Same seed and manual event index produce the same source identifier"
	)
	for _ = 1, 25 do
		controller.Advance(0.25)
		other.Advance(0.125)
		other.Advance(0.125)
	end
	near(
		controller.GetTime(),
		6.25,
		0,
		"Cloud building/injection progresses using executed fixed steps"
	)
	for name, field in controller.GetState().Fields do
		check(
			buffer.tostring(field) == buffer.tostring(other.GetState().Fields[name]),
			"Frame segmentation leaves deterministic source evolution unchanged"
		)
	end
	local d = controller.GetDiagnostics()
	check(
		d.SourceSamplesLastStep <= 128,
		"Source compilation respects its per-step sampling budget"
	)
	check(
		d.ExternalWaterSum > 0 and d.ExternalThetaSum > 0,
		"Completed source compilation supplies accounted vapor and heat"
	)
	check(
		math.abs(d.WaterDriftFraction) < 1e-6,
		"External forcing leaves numerical water drift meaningfully corrected"
	)
	check(d.ProjectionConverged, "Seeded source forcing preserves pressure solver convergence")
	near(d.SourceTick, 25, 0, "Source scheduler counts only committed physics steps")
	local repeated = controller.GetDiagnostics()
	near(
		repeated.CloudCentroidDeltaXMeters,
		d.CloudCentroidDeltaXMeters,
		0,
		"Repeated diagnostics do not fabricate a new centroid interval"
	)
	near(
		repeated.CloudCentroidDeltaSeconds,
		d.CloudCentroidDeltaSeconds,
		0,
		"Repeated diagnostic interval timing is stable"
	)
	controls:ExecuteText("wind 8 -2")
	near(controller.GetTime(), 6.25, 0, "Existing live wind command remains nonreset")
	controls:ExecuteText("pause")
	controller.Advance(2)
	near(controller.GetTime(), 6.25, 0, "Pause also pauses deterministic source scheduling")
	near(controller.GetSeedStatus().SourceTick, 25, 0, "Paused source tick does not advance")
	controls:ExecuteText("resume")
	controls:ExecuteText("regenerate")
	check(controller.GetState() ~= initial, "Regenerate intentionally replaces the atmosphere")
	near(controller.GetTime(), 0, 0, "Regenerate explicitly resets physical time")
	near(
		controller.GetSeedStatus().WorldSeed,
		-2147483648,
		0,
		"Regenerate applies the selected next seed"
	)
	near(
		controller.GetSeedStatus().InitialSourceCount,
		4,
		0,
		"Regenerate applies the selected next cloud count"
	)
	near(
		controller.GetDiagnostics().ExternalWaterSum,
		0,
		0,
		"Initial perturbations establish a new baseline, not ongoing forcing"
	)
	controls:ExecuteText("spawn Wide Fast")
	check(
		not controller.GetSeedStatus().SeededGeneration,
		"Legacy primitive spawn remains available as a comparison reset"
	)
	rejects(function()
		controls:ExecuteText("spawnseeded")
	end, "Nonreset seeded spawn reports inactive generation after a legacy reset")
	controls:ExecuteText("regenerate")
	check(
		controller.GetSeedStatus().SeededGeneration,
		"Regenerate restores procedural generation after legacy reset"
	)

	-- A diagnostic-only fixture checks the periodic minimum-image displacement
	-- and meter-to-display conversion. Production source generation never paints qc.
	controller.Advance(0.25)
	local fixtureState = controller.GetState()
	buffer.fill(fixtureState.Fields.qc, 0, 0)
	fixtureState:Set("qc", fixtureState.Grid:Index(1, 4, 8), 0.001)
	controller.GetDiagnostics()
	controller.Advance(0.25)
	fixtureState = controller.GetState()
	buffer.fill(fixtureState.Fields.qc, 0, 0)
	fixtureState:Set("qc", fixtureState.Grid:Index(16, 4, 8), 0.001)
	local moved = controller.GetDiagnostics()
	check(
		moved.CloudMovementDefined,
		"Two defined qc centroid samples define an interval displacement"
	)
	near(
		moved.CloudCentroidDeltaXMeters,
		-150,
		1e-9,
		"Centroid seam crossing uses the minimum-image displacement"
	)
	near(
		moved.CloudCentroidDeltaXStuds,
		-12,
		1e-9,
		"Centroid movement converts physical meters to display studs"
	)
	near(
		moved.CloudCentroidDeltaSeconds,
		0.25,
		0,
		"Movement interval uses physical simulation time"
	)

	-- Execute the real server bootstrap with a canonical terrain-seed adapter.
	-- The existing bootstrap suite separately tests its attribute signal plumbing.
	local function bootstrap(
		canonicalSeed: any,
		developmentSeed: any?,
		sourceIntensity: number?
	): any
		local attributes =
			serde.decode("json", fs.readFile("src/server/WeatherServer.meta.json")).attributes
		attributes.CloudSourceCount = 1
		if developmentSeed ~= nil then
			attributes.WorldSeed = developmentSeed
		end
		if sourceIntensity ~= nil then
			attributes.SourceIntensity = sourceIntensity
		end
		local signal = {
			Connect = function()
				return { Disconnect = function() end }
			end,
		}
		local services = {
			ReplicatedStorage = { Shared = { Atmosphere = root } },
			RunService = { Heartbeat = signal },
			Workspace = {
				GetAttribute = function(_self: any, name: string): any
					assert(name == "WorldSeed")
					return canonicalSeed
				end,
			},
		}
		local game = {
			GetService = function(_self: any, name: string): any
				assert(services[name] ~= nil, "Unexpected bootstrap service")
				return services[name]
			end,
		}
		local serverRoot, loadServer = createLoader("src/server", {
			game = game,
			print = function() end,
			warn = function() end,
		})
		local fakeScript = { Parent = serverRoot }
		function fakeScript:GetAttribute(name: string): any
			return attributes[name]
		end
		function fakeScript:SetAttribute(name: string, value: any)
			attributes[name] = value
		end
		function fakeScript:GetAttributeChangedSignal(): any
			return signal
		end
		function fakeScript:FindFirstChild(): any
			return nil
		end
		local requireModule = function(node: any): any
			if node == serverRoot.Debug.VoxelDebugRenderer then
				return {
					Render = function()
						return 0
					end,
				}
			end
			return loadServer(node)
		end
		local endpoint: any = nil
		local instance = {
			new = function(class: string): any
				check(
					class == "BindableFunction",
					"Seeded bootstrap creates no public administrative remote"
				)
				endpoint = {}
				return endpoint
			end,
		}
		local execute = luau.load(
			"return function(script, game, require, Instance, print, warn)\n"
				.. fs.readFile("src/server/WeatherServer.server.lua")
				.. "\nend",
			{ codegenEnabled = true }
		)()
		execute(fakeScript, game, requireModule, instance, function() end, function() end)
		return endpoint.OnInvoke("seedstatus")
	end
	for _, canonical in { 0, -84219, 2147483647 } do
		local status = bootstrap(canonical)
		near(
			status.WorldSeed,
			canonical,
			0,
			"Canonical terrain seed takes precedence over the development attribute"
		)
		check(status.SeedSource == "canonical world seed", "Canonical seed provenance is explicit")
	end
	near(
		bootstrap(nil).WorldSeed,
		84219,
		0,
		"Missing terrain seed selects the documented development fallback"
	)
	near(
		bootstrap(17, "unused").WorldSeed,
		17,
		0,
		"A valid canonical seed does not read an unused fallback attribute"
	)
	rejects(function()
		bootstrap(nil, "invalid")
	end, "An invalid development fallback fails when the terrain adapter is absent")
	near(
		bootstrap(17, nil, 0).SourceIntensity,
		0,
		0,
		"Startup source intensity can disable procedural forcing without changing the seed"
	)
	for _, invalidIntensity in { -0.1, 1.1, math.huge, 0 / 0 } do
		rejects(function()
			bootstrap(17, nil, invalidIntensity)
		end, "Invalid startup source intensity is rejected")
	end
	rejects(function()
		bootstrap(1.5)
	end, "Invalid canonical seed fails explicitly instead of using the fallback")
	print(
		"PASS: real seeded server commands, bounded nonreset injection, frame-independent scheduling, movement diagnostics, canonical seed bootstrap and legacy compatibility"
	)
end
