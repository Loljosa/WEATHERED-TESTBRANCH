--!strict

-- Production MAC + production world field; no alternate numerical scheme.
local createLoader = require("./RobloxModuleLoader")

return function(root: any, loadModule: any, check: any, near: any, rejects: any)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local Field = loadModule(root.World.WeatherField)
	local coordinate = Coordinates.new()
	local world = Field.new(coordinate, {
		SizeX = 4,
		SizeY = 3,
		SizeZ = 4,
		BackgroundU = 8,
		BackgroundV = 2,
		ShearU = 0.002,
		Microphysics = false,
	})
	-- Manufactured condensate is a transfer-accounting fixture, not a production
	-- cloud generator: even an already cloudy world must not copy qc into fine state.
	for offset = 0, world.Count * 8 - 8, 8 do
		buffer.writef64(world.State.Fields.qc, offset, 0.0006)
	end
	local serverRoot, loadServer = createLoader("src/server/Simulation", {
		game = {
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage", "Unexpected local coupling service")
				return { Shared = { Atmosphere = root } }
			end,
		},
	})
	local Coupling = loadServer(serverRoot.AtmosphericCoupling)
	local function snapshot(): { [string]: string }
		local saved = {}
		for name, value in world.State.Fields do
			saved[name] = buffer.tostring(value)
		end
		return saved
	end
	local function unchanged(saved: { [string]: string }, message: string)
		for name, value in saved do
			check(buffer.tostring(world.State.Fields[name]) == value, message .. ": " .. name)
		end
	end
	local function ticks(detail: any, count: number)
		for _ = 1, count do
			world:Step(0.25)
			local saved = snapshot()
			local time, waterInput = world.Time, world.ExternalWaterSum
			detail:Advance(world.Tick)
			unchanged(saved, "Fine evolution cannot mutate coarse fields")
			near(world.Time, time, 0, "Fine evolution cannot advance the world timeline")
			near(
				world.ExternalWaterSum,
				waterInput,
				0,
				"Fine exchange is excluded from global source accounting"
			)
		end
	end
	local detail = Coupling.new(world)
	local diagnostic = detail:GetDiagnostics()
	check(not diagnostic.Enabled, "World local detail is disabled by default")
	near(diagnostic.ActiveSolvers, 0, 0, "Disabled detail has no active MAC")
	near(diagnostic.AllocatedSolvers, 0, 0, "Default detail creates no MAC buffers")
	near(diagnostic.BufferBytes, 0, 0, "Default detail owns no large storage")
	near(diagnostic.SamplesTotal, 0, 0, "Default detail does not sample or regenerate sources")
	ticks(detail, 4)
	near(detail:GetDiagnostics().LocalSteps, 0, 0, "Disabled detail performs no physics")
	rejects(function()
		Coupling.new(world, { IntervalTicks = 1 })
	end, "Local detail cannot run every world tick")
	rejects(function()
		Coupling.new(world, { Preset = "Ultra" })
	end, "Local detail preserves only known performance presets")
	rejects(function()
		Coupling.new(world, { CpuBudgetMilliseconds = math.huge })
	end, "Local CPU budgets must be finite")
	rejects(function()
		Coupling.new(world, { ConditioningTimescaleSeconds = 0 })
	end, "Local conditioning time must be positive")
	rejects(function()
		detail:SetEnabled(true, 17)
	end, "Local region anchors are bounded")
	local before = snapshot()
	local worldTime = world.Time
	detail:SetEnabled(true, 6)
	unchanged(before, "Activating local detail cannot write coarse state")
	near(world.Time, worldTime, 0, "Activating detail does not reset the world")
	diagnostic = detail:GetDiagnostics()
	near(diagnostic.ActiveSolvers, 1, 0, "At most one region hosts local detail")
	near(diagnostic.AllocatedSolvers, 1, 0, "Exactly one MAC is allocated")
	near(diagnostic.DxMeters, 503.5 / 16, 0, "Laptop local X spacing fits one world region")
	near(diagnostic.DzMeters, 503.5 / 16, 0, "Laptop local Z spacing fits one world region")
	near(
		diagnostic.DyMeters,
		72 / 12,
		0,
		"Local vertical spacing uses the explicit world altitude dimension"
	)
	near(
		diagnostic.BoundaryCellCount,
		720,
		0,
		"Lateral conditioning ring is precomputed and bounded"
	)
	near(diagnostic.LocalTime, 0, 0, "Fresh shadow has its own explicit diagnostic clock")
	check(diagnostic.BufferBytes > 0, "Activated detail reports actual packed-buffer storage")
	check(diagnostic.BufferCount == 61, "One local MAC plus three reused coupling buffers")
	local simulation = detail.Simulation
	check(simulation ~= nil, "Enabled detail exposes the existing production MAC for diagnostics")
	local grid = simulation.State.Grid
	local bounds = coordinate.Bounds[6]
	for index = 1, grid.Count do
		near(
			simulation.State:Get("qc", index),
			0,
			0,
			"Coarse condensate is never painted into local qc"
		)
		near(
			simulation.State:Get("qr", index),
			0,
			0,
			"Coarse rain is never duplicated into local qr"
		)
		local x, y, z = grid:Coordinates(index)
		local px = bounds.MinXMeters + (x - 0.5) * grid.Dx
		local py = coordinate.BaseAltitudeMeters + (y - 0.5) * grid.Dy
		local pz = bounds.MinZMeters + (z - 0.5) * grid.Dz
		near(
			simulation.State:Get("pressure", index),
			world:SamplePhysical(px, py, pz, "pressure"),
			0.01,
			"Local thermodynamic pressure samples absolute world altitude"
		)
		near(
			simulation.State:Get("theta", index),
			world:SamplePhysical(px, py, pz, "theta"),
			0.00004,
			"Local potential temperature samples the selected physical region"
		)
	end
	local allocation, bytes = diagnostic.BufferCount, diagnostic.BufferBytes
	ticks(detail, 3)
	near(detail:GetDiagnostics().LocalSteps, 0, 0, "No early local catchup step occurs")
	ticks(detail, 1)
	diagnostic = detail:GetDiagnostics()
	near(diagnostic.LocalSteps, 1, 0, "Four world ticks execute one local step")
	near(
		diagnostic.LocalTime,
		0.25,
		0,
		"Local diagnostic clock is explicitly slower than world time"
	)
	check(
		diagnostic.ProjectionResidual < 1e-7,
		"Sample-conditioned local pressure projection remains stable"
	)
	check(diagnostic.MaxCourant <= 0.8, "Sample-conditioned local MAC retains its CFL protections")
	near(
		diagnostic.SamplesLastStep,
		720 * 2 + 12 * 9 * 4,
		0,
		"Ongoing source sampling is bounded by ring and reference profile"
	)
	near(
		diagnostic.BufferCount,
		allocation,
		0,
		"Local physics allocates no new large buffers per step"
	)
	near(diagnostic.BufferBytes, bytes, 0, "Local buffer ownership remains stable")
	local scheduled = detail.NextTick
	detail:SetEnabled(true, 6)
	near(
		detail.NextTick,
		scheduled,
		0,
		"Repeated enable requests cannot postpone scheduled local work"
	)
	check(
		not detail:Advance(world.Tick),
		"Repeated authoritative ticks do not advance the local clock"
	)
	near(detail:GetDiagnostics().LocalSteps, 1, 0, "Pausing preserves local time")

	-- Signed conditioning receipts distinguish environmental drying from drift.
	for offset = 0, world.Count * 8 - 8, 8 do
		buffer.writef64(
			world.State.Fields.qv,
			offset,
			buffer.readf64(world.State.Fields.qv, offset) + 0.001
		)
		buffer.writef64(
			world.State.Fields.theta,
			offset,
			buffer.readf64(world.State.Fields.theta, offset) + 0.5
		)
	end
	ticks(detail, 4)
	diagnostic = detail:GetDiagnostics()
	check(
		diagnostic.WaterExchangeSum > 0,
		"Positive coarse moisture conditioning has an explicit local receipt"
	)
	check(
		diagnostic.ThetaExchangeSum > 0,
		"Coarse thermal conditioning has an explicit local receipt"
	)
	check(diagnostic.EnthalpyExchangeSum > 0, "Signed enthalpy proxy is recorded separately")
	check(
		math.abs(diagnostic.LocalWaterErrorFraction) < 2e-6,
		"Local conservation error excludes measured conditioning input"
	)
	local waterExchange = diagnostic.WaterExchangeSum
	for offset = 0, world.Count * 8 - 8, 8 do
		buffer.writef64(
			world.State.Fields.qv,
			offset,
			buffer.readf64(world.State.Fields.qv, offset) - 0.004
		)
	end
	ticks(detail, 4)
	check(
		detail:GetDiagnostics().WaterExchangeSum < waterExchange,
		"Dry coarse air permits negative measured local vapor exchange"
	)
	local localTime = detail:GetDiagnostics().LocalTime
	detail:SetEnabled(false)
	ticks(detail, 8)
	near(
		detail:GetDiagnostics().LocalTime,
		localTime,
		0,
		"Disabled detail preserves retained local clouds and time"
	)
	near(detail:GetDiagnostics().ActiveSolvers, 0, 0, "Disabled detail consumes no solver steps")
	near(detail:GetDiagnostics().AllocatedSolvers, 1, 0, "Disabling retains one reusable shadow")
	detail:SetEnabled(true)
	check(detail.Simulation == simulation, "Re-enabling the same region preserves the local solver")
	ticks(detail, 4)
	near(
		detail:GetDiagnostics().LocalTime,
		localTime + 0.25,
		0,
		"Re-enabling resumes without replaying skipped world time"
	)
	for _ = 1, 12 do
		world:Step(0.25)
	end
	check(detail:Advance(world.Tick), "A missed local interval performs at most one step")
	near(
		detail:GetDiagnostics().SkippedLocalSteps,
		2,
		0,
		"Missed intervals are explicitly reported rather than caught up"
	)
	rejects(function()
		detail:Advance(world.Tick + 1)
	end, "Uncommitted world ticks cannot drive local physics")
	before = snapshot()
	detail:SetEnabled(true, 16)
	unchanged(before, "Changing one detail anchor never regenerates global weather")
	near(
		detail:GetDiagnostics().RegionId,
		16,
		0,
		"Stable integer region coordinates select the new anchor"
	)
	near(
		detail:GetDiagnostics().ActiveSolvers,
		1,
		0,
		"Changing anchors never retains a second active solver"
	)
	near(
		detail:GetDiagnostics().Initializations,
		2,
		0,
		"Administrative local reinitialization is separately counted"
	)

	-- Construction failure is transactional; runtime failure isolates the optional
	-- shadow and cannot prevent continued authoritative coarse transport.
	local originalSample = world.SamplePhysical
	world.SamplePhysical = function(
		self: any,
		x: number,
		y: number,
		z: number,
		name: string
	): number
		return if name == "qv" then 0 / 0 else originalSample(self, x, y, z, name)
	end
	local retained = detail.Simulation
	local retainedAnchor = detail.RegionId
	before = snapshot()
	rejects(function()
		detail:SetEnabled(true, 1)
	end, "Invalid coarse input rejects optional initialization")
	check(
		detail.Simulation == retained and detail.RegionId == retainedAnchor,
		"Rejected construction preserves the previous valid shadow"
	)
	unchanged(before, "Rejected coupling construction cannot mutate the world")
	for _ = 1, 4 do
		world:Step(0.25)
	end
	before = snapshot()
	check(not detail:Advance(world.Tick), "Invalid optional detail step is reported safely")
	unchanged(before, "Failed optional detail cannot roll back or corrupt coarse weather")
	diagnostic = detail:GetDiagnostics()
	check(
		not diagnostic.Enabled and diagnostic.LastFailure ~= nil,
		"A failed shadow disables itself with an explicit error"
	)
	near(diagnostic.AllocatedSolvers, 0, 0, "Failed partially conditioned state is discarded")
	world.SamplePhysical = originalSample
	world:Step(0.25)
	check(world.Time > worldTime, "Coarse weather continues after a local solver failure")

	-- Legacy source controls retain their original mathematical implementation,
	-- explicitly isolated from world geometry and cloud-water accounting.
	before = snapshot()
	local message = detail:StartExperiment("spawn", "Wide", "Fast", "1.25")
	check(
		string.find(message, "Diagnostic only", 1, true) ~= nil,
		"Legacy source command states its diagnostic-only scope"
	)
	unchanged(before, "Legacy cloud experiments never reset the world")
	near(detail.ExperimentConfig.BubbleScale, 1.25, 0, "Legacy source size is cached")
	near(
		detail.ExperimentConfig.BubbleTemperaturePerturbation,
		8,
		0,
		"Fast retains the legacy thermal perturbation"
	)
	near(
		detail.ExperimentConfig.BubbleRelativeHumidity,
		0.9999,
		0,
		"Fast retains the legacy humidity setting"
	)
	check(detail.ExperimentConfig.BubbleShape == "Wide", "Legacy cloud shape is cached")
	check(
		detail:GetDiagnostics().Mode == "LegacyExperiment",
		"Legacy pressure/geometry cannot be confused with world conditioning"
	)
	ticks(detail, 4)
	near(
		detail:GetDiagnostics().LocalTime,
		0.25,
		0,
		"Legacy production MAC experiment actually steps"
	)
	near(
		detail:GetDiagnostics().SamplesLastStep,
		0,
		0,
		"Isolated legacy experiment performs no world source sampling"
	)
	detail:StartExperiment("size", 0.75)
	check(
		detail.ExperimentConfig.BubbleShape == "Wide",
		"Changing legacy size preserves the previous shape"
	)
	near(
		detail.ExperimentConfig.BubbleScale,
		0.75,
		0,
		"Legacy size command uses its validated range"
	)
	detail:StartExperiment("condensation", "Normal")
	near(
		detail.ExperimentConfig.BubbleTemperaturePerturbation,
		6,
		0,
		"Normal source configuration is restored"
	)
	local oldExperiment = detail.Simulation
	for _, invalid in
		{
			function()
				detail:StartExperiment("size", 0.49)
			end,
			function()
				detail:StartExperiment("size", math.huge)
			end,
			function()
				detail:StartExperiment("spawn", "Cube")
			end,
			function()
				detail:StartExperiment("condensation", "Instant")
			end,
			function()
				detail:StartExperiment("spawn", "Round", "Fast", 1, "extra")
			end,
		}
	do
		rejects(invalid, "Invalid legacy command leaves a valid local shadow intact")
		check(
			detail.Simulation == oldExperiment,
			"Rejected legacy arguments do not reinitialize detail"
		)
	end
	detail:SetEnabled(true, 6)
	check(
		detail:GetDiagnostics().Mode == "WorldConditioned",
		"Explicit detail anchor returns from the legacy experiment"
	)
	-- Liquid appears through production WarmCloud, even though no fine qc was
	-- transferred. Deliberately supersaturated vapor supplies a clear phase test;
	-- geographically seeded world growth is covered by the world formation tests.
	local Saturation = loadModule(root.Thermodynamics.Saturation)
	local Thermodynamics = loadModule(root.Thermodynamics.Thermodynamics)
	for offset = 0, world.Count * 8 - 8, 8 do
		local theta = buffer.readf64(world.State.Fields.theta, offset)
		local pressure = buffer.readf64(world.State.Fields.pressure, offset)
		buffer.writef64(
			world.State.Fields.qv,
			offset,
			1.02 * Saturation.MixingRatio(Thermodynamics.Temperature(theta, pressure), pressure)
		)
	end
	detail:SetEnabled(true, 2)
	near(
		detail.Simulation:GetDiagnostics().QcSum,
		0,
		0,
		"Fresh humid fine state starts with zero condensate"
	)
	ticks(detail, 16)
	check(
		detail:GetDiagnostics().LastFailure == nil,
		"Humid conditioned MAC remains numerically stable"
	)
	check(
		detail.Simulation:GetDiagnostics().QcSum > 0,
		"Fine cloud water emerges from production saturation adjustment"
	)
	check(
		math.abs(detail:GetDiagnostics().LocalWaterErrorFraction) < 2e-6,
		"Fine latent heating and repeated conditioning preserve measured water accounting"
	)
	local full = Coupling.new(world, { Preset = "Full", Enabled = true, RegionId = 1 })
	local fullDiagnostic = full:GetDiagnostics()
	near(
		full.Simulation.State.Grid.Count,
		24 * 12 * 24,
		0,
		"Full detail preserves existing preset resolution"
	)
	near(fullDiagnostic.DxMeters, 503.5 / 24, 0, "Full fine spacing still fits one world region")
	near(fullDiagnostic.BufferCount, 61, 0, "Full detail ownership is bounded identically")
	ticks(full, 4)
	check(full:GetDiagnostics().LastFailure == nil, "Full preset sampled MAC is operational")
	near(full:GetDiagnostics().LocalSteps, 1, 0, "Full preset executes the same bounded scheduling")
	print(
		string.format(
			"Local coupling: Laptop %d bytes/%d buffers, Full %d bytes/%d buffers; last Full step %.3f ms, soft budget %.3f ms (Lune host, not Studio FPS)",
			bytes,
			allocation,
			full:GetDiagnostics().BufferBytes,
			full:GetDiagnostics().BufferCount,
			full:GetDiagnostics().StepMilliseconds,
			full:GetDiagnostics().CpuBudgetMilliseconds
		)
	)
end
