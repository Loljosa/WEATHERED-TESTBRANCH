--!strict

local createLoader = require("./RobloxModuleLoader")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

-- Exercise the production controller with deterministic clocks. The clock only
-- controls scheduling; every executed production physics step remains 0.25 s.
return function(root: any, loadModule: any, check: any, near: any, rejects: any, quick: boolean?)
	local startup =
		serde.decode("json", fs.readFile("src/server/WeatherServer.meta.json")).attributes
	local settingsRoot, loadSettings = createLoader("src/server/Simulation")
	local PerformanceSettings = loadSettings(settingsRoot.PerformanceSettings)
	local laptopSettings = PerformanceSettings.Resolve(startup.PerformancePreset)
	local fullSettings = PerformanceSettings.Resolve("Full")
	near(fullSettings.SizeX, 24, 0, "Full preset retains the previous horizontal resolution")
	near(fullSettings.SizeY, 12, 0, "Full preset retains the previous vertical resolution")
	near(fullSettings.SizeZ, 24, 0, "Full preset retains the previous depth resolution")
	near(fullSettings.SizeX * fullSettings.Dx, 2400, 0, "Full preset preserves the physical domain")
	near(
		laptopSettings.SizeX,
		16,
		0,
		"Laptop preset selects the tested cloud-preserving horizontal resolution"
	)
	near(laptopSettings.DebugRenderInterval, 1, 0, "Laptop debug rendering runs at one Hz")
	rejects(function()
		PerformanceSettings.Resolve("Typo")
	end, "Unknown performance presets fail explicitly")
	rejects(function()
		laptopSettings.SizeX = 100
	end, "Performance presets cannot be mutated through a shared reference")
	local function controller(): (any, () -> number)
		local warnings = 0
		local controllerRoot, loadController = createLoader("src/server/Simulation", {
			game = {
				GetService = function(_self: any, name: string): any
					assert(name == "ReplicatedStorage", "Unexpected laptop test service")
					return { Shared = { Atmosphere = root } }
				end,
			},
			print = function() end,
			warn = function()
				warnings += 1
			end,
		})
		return loadController(controllerRoot.SimulationController),
			function()
				return warnings
			end
	end

	local configuration = {
		BackgroundU = startup.BackgroundU,
		BackgroundV = startup.BackgroundV,
		ShearU = startup.ShearU,
		ShearV = startup.ShearV,
		BubbleRelativeHumidity = startup.BubbleRelativeHumidity,
		BubbleTemperaturePerturbation = startup.BubbleTemperaturePerturbation,
		BubbleShape = startup.CloudShape,
		BubbleScale = startup.CloudScale,
	}
	local laptop = controller()
	local state = laptop.Initialize(configuration, {
		CellSizeStuds = startup.CellSizeStuds,
		CloudBottomStuds = startup.CloudBottomStuds,
		SizeX = laptopSettings.SizeX,
		SizeY = laptopSettings.SizeY,
		SizeZ = laptopSettings.SizeZ,
		Dx = laptopSettings.Dx,
		Dy = laptopSettings.Dy,
		Dz = laptopSettings.Dz,
	}, {
		MaxCatchUpSteps = laptopSettings.MaxCatchUpSteps,
		FrameBudgetMilliseconds = laptopSettings.FrameBudgetMilliseconds,
	})
	local grid = laptop.GetGrid()
	near(grid.Count, 3072, 0, "Laptop geometry reduces the previous 6912-cell atmosphere")
	near(grid.CellSize, 12, 0, "Laptop geometry retains exact 12-stud diagnostic cubes")
	near(grid.Origin.X, -96, 0, "Laptop display remains centered along X")
	near(grid.Origin.Z, -96, 0, "Laptop display remains centered along Z")
	near(grid.Origin.Y, 424, 0, "Laptop display bottom clears terrain around Y=70 studs")
	near(grid.SizeX * grid.Dx, 2400, 0, "Laptop X extent retains the 2400-meter physical domain")
	near(grid.SizeY * grid.Dy, 1200, 0, "Laptop Y extent retains the 1200-meter physical domain")
	near(grid.SizeZ * grid.Dz, 2400, 0, "Laptop Z extent retains the 2400-meter physical domain")
	for index = 1, grid.Count do
		local x, y, z = grid:Coordinates(index)
		check(grid:Index(x, y, z) == index, "Laptop grid indexing round trips")
		local wx, wy, wz = grid:WorldToGrid(grid:GridToWorld(x, y, z))
		check(wx == x and wy == y and wz == z, "Laptop display coordinates round trip")
		near(state:Get("qc", index), 0, 0, "Laptop initialization never paints cloud water")
	end

	-- Test the public factory rather than duplicating the sounding equations.
	-- The scientific default remains the legacy 2 K bubble; the Studio preview
	-- independently selects a stronger 6 K perturbation through its attributes.
	local Atmosphere = loadModule(root)
	local Grid3D = loadModule(root.Core.Grid3D)
	local Thermodynamics = loadModule(root.Thermodynamics.Thermodynamics)
	local Saturation = loadModule(root.Thermodynamics.Saturation)
	local optionGrid = Grid3D.new(7, 5, 7, 12, grid.Origin)
	local defaultBubble = Atmosphere.new(optionGrid)
	local explicitDefault = Atmosphere.new(optionGrid, { BubbleTemperaturePerturbation = 2 })
	local warmerBubble = Atmosphere.new(optionGrid, { BubbleTemperaturePerturbation = 6 })
	for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
		check(
			buffer.tostring(defaultBubble.State.Fields[name])
				== buffer.tostring(explicitDefault.State.Fields[name]),
			"An explicit 2 K bubble exactly preserves the scientific initialization"
		)
	end
	local core = optionGrid:Index(4, 3, 4)
	near(
		warmerBubble.State:Get("theta", core) - defaultBubble.State:Get("theta", core),
		4,
		0,
		"The forwarded 6 K option raises the flat bubble core by another 4 K"
	)
	check(
		warmerBubble.State:Get("qv", core) > defaultBubble.State:Get("qv", core),
		"The warmer bubble recomputes vapor at the same relative humidity"
	)
	near(
		warmerBubble.State:Get("qv", core),
		0.98
			* Saturation.MixingRatio(
				Thermodynamics.Temperature(
					warmerBubble.State:Get("theta", core),
					warmerBubble.State:Get("pressure", core)
				),
				warmerBubble.State:Get("pressure", core)
			),
		1e-8, -- Initialization uses double precision before pressure/theta become float32.
		"Vapor follows saturation at the initialized temperature and default bubble humidity"
	)
	for index = 1, optionGrid.Count do
		near(defaultBubble.State:Get("qc", index), 0, 0, "The default bubble initializes clear")
		near(
			warmerBubble.State:Get("qc", index),
			0,
			0,
			"A stronger thermal bubble initializes clear"
		)
	end
	local zeroBubble = Atmosphere.new(optionGrid, { BubbleTemperaturePerturbation = 0 })
	near(
		zeroBubble.State:Get("theta", core),
		buffer.readf32(zeroBubble.Profile.Theta, 8),
		0,
		"Zero thermal perturbation is valid and matches the environmental theta"
	)
	for _, invalidTemperature in { -1, 0 / 0, math.huge, -math.huge } do
		rejects(function()
			Atmosphere.new(optionGrid, { BubbleTemperaturePerturbation = invalidTemperature })
		end, "Negative or nonfinite bubble temperature fails explicitly")
	end

	check(laptop.Advance(1.05, 2) == 1, "Laptop catch-up performs at most one fixed physics step")
	near(laptop.GetTime(), 0.25, 0, "Laptop catch-up preserves the physical timestep")
	near(laptop.GetDroppedTime(), 1.75, 1e-12, "Laptop reports discarded full-step backlog")
	check(laptop.Advance(0.075, 2) == 1, "Laptop catch-up retains the fractional time remainder")
	near(laptop.GetTime(), 0.5, 0, "Fractional remainder yields exactly one subsequent fixed step")
	local laptopDiagnostics = laptop.GetDiagnostics()
	near(laptopDiagnostics.MaxCatchUpSteps, 1, 0, "Diagnostics expose the laptop scheduling limit")
	near(
		laptopDiagnostics.FrameBudgetMilliseconds,
		8,
		0,
		"Diagnostics expose the requested frame budget"
	)

	local alternate = controller()
	alternate.Initialize(nil, {
		CellSizeStuds = 12,
		SizeX = 12,
		SizeY = 12,
		SizeZ = 12,
		Dx = 200,
		Dy = 100,
		Dz = 200,
	})
	local alternateGrid = alternate.GetGrid()
	near(alternateGrid.Count, 1728, 0, "Configured resolution is not hard-coded to laptop geometry")
	near(alternateGrid.Origin.X, -72, 0, "Configured display geometry remains centered")
	near(
		alternateGrid.Dx * alternateGrid.SizeX,
		2400,
		0,
		"Intermediate resolution preserves physical X extent"
	)
	near(
		alternateGrid.Dz * alternateGrid.SizeZ,
		2400,
		0,
		"Intermediate resolution preserves physical Z extent"
	)

	local elapsed = 0
	local budgeted, warningCount = controller()
	budgeted.Initialize(nil, { SizeX = 4, SizeY = 4, SizeZ = 4 }, {
		MaxCatchUpSteps = 8,
		FrameBudgetMilliseconds = 8,
		Clock = function(): number
			local current = elapsed
			elapsed += 0.02
			return current
		end,
	})
	check(budgeted.Advance(2) == 1, "An exceeded frame budget blocks additional catch-up steps")
	near(
		budgeted.GetTime(),
		0.25,
		0,
		"The frame budget never interrupts or enlarges a physical step"
	)
	near(budgeted.GetDroppedTime(), 1.75, 0, "Budget-limited backlog is explicitly accounted")
	local budgetDiagnostics = budgeted.GetDiagnostics()
	check(budgetDiagnostics.FrameBudgetReached, "Frame diagnostics report budget exhaustion")
	check(
		budgetDiagnostics.LastAdvanceMilliseconds >= 20,
		"Frame diagnostics report measured elapsed duration"
	)
	near(budgetDiagnostics.LastAdvanceSteps, 1, 0, "Frame diagnostics report actual executed steps")
	near(warningCount(), 1, 0, "Budget exhaustion produces one rate-limited warning")
	check(budgeted.Advance(0) == 0, "An empty accumulator performs no budget-driven physics work")
	near(budgeted.GetTime(), 0.25, 0, "Empty frames preserve simulation time")
	check(
		budgeted.Advance(2) == 1,
		"Repeated budget exhaustion still executes one indivisible step"
	)
	near(warningCount(), 1, 0, "Repeated budget warnings are limited by wall time")
	local unexpired = controller()
	unexpired.Initialize(nil, { SizeX = 4, SizeY = 4, SizeZ = 4 }, {
		MaxCatchUpSteps = 8,
		FrameBudgetMilliseconds = 8,
		Clock = function(): number
			return 0
		end,
	})
	check(unexpired.Advance(2) == 8, "An unexpired budget permits configured catch-up")
	near(unexpired.GetDroppedTime(), 0, 0, "An unexpired budget does not discard executed work")
	check(
		not unexpired.GetDiagnostics().FrameBudgetReached,
		"An unexpired budget is reported accurately"
	)
	for _, invalidTime in { math.huge, 0 / 0 } do
		local badClock = controller()
		badClock.Initialize(nil, { SizeX = 4, SizeY = 4, SizeZ = 4 }, {
			Clock = function(): number
				return invalidTime
			end,
		})
		rejects(function()
			badClock.Advance(0)
		end, "A nonfinite execution clock fails before physics")
		near(
			badClock.GetTime(),
			0,
			0,
			"Nonfinite clock failure does not advance the physical state"
		)
	end
	local decreasing = controller()
	local decreasingTime = 2
	decreasing.Initialize(nil, { SizeX = 4, SizeY = 4, SizeZ = 4 }, {
		Clock = function(): number
			local current = decreasingTime
			decreasingTime -= 1
			return current
		end,
	})
	rejects(function()
		decreasing.Advance(0)
	end, "A decreasing execution clock fails explicitly")
	near(
		decreasing.GetTime(),
		0,
		0,
		"Decreasing clock validation on an empty frame does not step physics"
	)

	for _, settings in
		{
			{ MaxCatchUpSteps = 0 },
			{ MaxCatchUpSteps = 1.5 },
			{ MaxCatchUpSteps = math.huge },
			{ FrameBudgetMilliseconds = 0 },
			{ FrameBudgetMilliseconds = -1 },
			{ FrameBudgetMilliseconds = 0 / 0 },
			{ Clock = 17 },
		}
	do
		rejects(function()
			local invalid = controller()
			invalid.Initialize(nil, { SizeX = 4, SizeY = 4, SizeZ = 4 }, settings)
		end, "Invalid laptop execution options fail explicitly")
	end
	for _, settings in
		{
			{ SizeX = 0 },
			{ SizeX = 4.5 },
			{ SizeY = 2 },
			{ SizeZ = math.huge },
			{ Dx = 0 },
			{ Dy = 0 / 0 },
			{ Dz = -1 },
		}
	do
		rejects(function()
			local invalid = controller()
			invalid.Initialize(nil, settings)
		end, "Invalid configured laptop geometry fails explicitly")
	end
	print(
		"PASS: laptop geometry, independent display/physical units, initial clear state and deterministic frame-budget/catch-up scheduling"
	)
	if quick then
		return
	end

	-- This complete 240-second production regression rejects resolutions that
	-- are fast but dissolve the bubble before it becomes a useful moving cloud.
	local simulation = Atmosphere.new(grid, configuration)
	local initial = simulation:GetDiagnostics()
	near(initial.MaxCloudWater, 0, 0, "Laptop cloud regression starts completely clear")
	local pressureSnapshot = buffer.tostring(simulation.State.Fields.pressure)
	local function ownedBuffers(value: any, seen: { [any]: boolean }?): (number, number)
		local visited = seen or {}
		if visited[value] then
			return 0, 0
		end
		if typeof(value) == "buffer" then
			visited[value] = true
			return 1, buffer.len(value)
		elseif type(value) == "table" then
			visited[value] = true
			local count, bytes = 0, 0
			for _, child in value do
				local childCount, childBytes = ownedBuffers(child, visited)
				count += childCount
				bytes += childBytes
			end
			return count, bytes
		end
		return 0, 0
	end
	local bufferCount, bufferBytes = ownedBuffers(simulation)
	local totalMilliseconds, maximumMilliseconds, maximumIterations, maximumCourant = 0, 0, 0, 0
	local maximumDivergence, peakCloud = 0, 0
	local firstCloud: number? = nil
	local firstVisible: number? = nil
	local firstCentroid: any = nil
	local lastCentroid: any = nil
	local snapshots = {}
	local started = os.clock()
	for step = 1, 960 do
		simulation:Step(Atmosphere.FixedDt)
		totalMilliseconds += simulation.StepMilliseconds
		maximumMilliseconds = math.max(maximumMilliseconds, simulation.StepMilliseconds)
		maximumIterations = math.max(maximumIterations, simulation.Projection.Last.Iterations)
		maximumCourant =
			math.max(maximumCourant, simulation.MomentumCourant, simulation.TransportCourant)
		if firstCloud == nil or firstVisible == nil then
			for offset = 0, grid.Count * 4 - 4, 4 do
				local qc = buffer.readf32(simulation.State.Fields.qc, offset)
				if qc > 0 then
					firstCloud = firstCloud or simulation.Time
				end
				if qc >= 0.00005 then
					firstVisible = firstVisible or simulation.Time
				end
			end
		end
		if step % 40 == 0 then
			local diagnostics = simulation:GetDiagnostics()
			peakCloud = math.max(peakCloud, diagnostics.MaxCloudWater)
			local rms, maximum = simulation.Projection:Divergence(simulation.Faces)
			check(
				rms <= simulation.Projection.Last.PostTolerance
					and maximum <= simulation.Projection.Last.PostTolerance,
				"Laptop pressure projection satisfies the reported float32 divergence tolerance"
			)
			check(
				diagnostics.ProjectionResidual <= diagnostics.ProjectionTolerance
					and diagnostics.ProjectionResidualMax <= diagnostics.ProjectionTolerance
					and diagnostics.ProjectionConverged,
				"Laptop pressure solver satisfies both true residual criteria"
			)
			maximumDivergence = math.max(maximumDivergence, maximum)
			for _, name in { "qv", "qc", "qr", "theta", "u", "v", "w", "pressure" } do
				for offset = 0, grid.Count * 4 - 4, 4 do
					local value = buffer.readf32(simulation.State.Fields[name], offset)
					check(
						value == value and math.abs(value) < math.huge,
						"Laptop 240-second production fields remain finite"
					)
					if name == "qv" or name == "qc" or name == "qr" then
						check(value >= 0, "Laptop 240-second moisture remains nonnegative")
					end
				end
			end
			if diagnostics.CloudCells > 0 and diagnostics.CloudCentroidDefined then
				firstCentroid = firstCentroid or diagnostics
				lastCentroid = diagnostics
			end
			if step % 240 == 0 then
				table.insert(snapshots, diagnostics)
				print(
					string.format(
						"laptop16 t=%.0fs cloud=%d qc=%.7g drift=%+.8f%% PCG=%d div=%.3g centroid=(%.2f,%.2f,%.2f)m",
						simulation.Time,
						diagnostics.CloudCells,
						diagnostics.MaxCloudWater,
						diagnostics.WaterDriftFraction * 100,
						diagnostics.ProjectionIterations,
						maximum,
						diagnostics.CloudCentroidX,
						diagnostics.CloudCentroidY,
						diagnostics.CloudCentroidZ
					)
				)
			end
		end
	end
	local final = simulation:GetDiagnostics()
	local finalBufferCount, finalBufferBytes = ownedBuffers(simulation)
	near(finalBufferCount, bufferCount, 0, "Laptop simulation does not grow its owned buffer count")
	near(finalBufferBytes, bufferBytes, 0, "Laptop simulation reuses fixed buffer storage")
	near(simulation.Time, 240, 0, "Laptop scenario executes 240 physical seconds")
	check(
		buffer.tostring(simulation.State.Fields.pressure) == pressureSnapshot,
		"Laptop projection preserves absolute thermodynamic pressure"
	)
	check(
		math.abs(final.WaterDriftFraction * 100) < 0.0001,
		"Laptop unweighted total-water drift remains below 0.0001 percent"
	)
	check(
		firstVisible ~= nil and firstVisible < 30,
		"The current startup preview produces a visible cloud within 30 simulated seconds"
	)
	check(final.CloudCells > 0, "Laptop cloud survives the full 240-second wind scenario")
	check(
		firstCentroid ~= nil and lastCentroid ~= nil,
		"Laptop cloud has measurable visible centroids"
	)
	local lengthX, lengthZ = grid.SizeX * grid.Dx, grid.SizeZ * grid.Dz
	local displacement = {
		X = (lastCentroid.CloudCentroidX - firstCentroid.CloudCentroidX + lengthX * 0.5) % lengthX
			- lengthX * 0.5,
		Y = lastCentroid.CloudCentroidY - firstCentroid.CloudCentroidY,
		Z = (lastCentroid.CloudCentroidZ - firstCentroid.CloudCentroidZ + lengthZ * 0.5) % lengthZ
			- lengthZ * 0.5,
		Seconds = lastCentroid.Time - firstCentroid.Time,
	}
	check(
		displacement.X > 5 and displacement.Z > 5 and displacement.Seconds >= 20,
		"Laptop visible cloud moves in both configured horizontal wind directions"
	)
	fs.writeDir("build")
	fs.writeFile(
		"build/laptop-validation.json",
		serde.encode("json", {
			SourceRevision = string.gsub(
				process.exec("git", { "rev-parse", "HEAD" }).stdout,
				"%s+$",
				""
			),
			WorkingTreeChanged = process.exec("git", { "status", "--porcelain" }).stdout ~= "",
			AtmosphereVersion = Atmosphere.GetVersion(),
			Preset = laptopSettings,
			Configuration = configuration,
			FixedDt = Atmosphere.FixedDt,
			SimulationSeconds = simulation.Time,
			Initial = initial,
			Final = final,
			Snapshots = snapshots,
			FirstCloudWaterSecondsExact = firstCloud,
			FirstVisibleCloudSecondsExact = firstVisible,
			PeakCloud = peakCloud,
			CentroidDisplacementMeters = displacement,
			MaximumIterations = maximumIterations,
			MaximumCourant = maximumCourant,
			SampledMaximumDivergence = maximumDivergence,
			MeanStepMilliseconds = totalMilliseconds / 960,
			MaximumStepMilliseconds = maximumMilliseconds,
			OwnedBufferCount = bufferCount,
			OwnedBufferBytes = bufferBytes,
			RuntimeSeconds = os.clock() - started,
		})
	)
	print(
		string.format(
			"PASS: laptop960steps/240s firstqc=%.2fs firstvisible=%.2fs finalcloud=%d drift=%+.8f%% visiblecentroiddelta=(%.2f,%.2f,%.2f)m meanstep=%.3fms buffers=%d/%dbytes",
			firstCloud or -1,
			firstVisible or -1,
			final.CloudCells,
			final.WaterDriftFraction * 100,
			displacement.X,
			displacement.Y,
			displacement.Z,
			totalMilliseconds / 960,
			bufferCount,
			bufferBytes
		)
	)
end
