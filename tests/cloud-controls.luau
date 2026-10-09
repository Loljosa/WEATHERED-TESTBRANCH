--!strict

local createLoader = require("./RobloxModuleLoader")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Vector3 = require("@lune/roblox").Vector3

return function(root: any, loadModule: any, check: any, near: any, rejects: any, quick: boolean)
	local Atmosphere = loadModule(root)
	local Grid3D = loadModule(root.Core.Grid3D)
	local grid =
		Grid3D.new(16, 12, 16, 12, Vector3.new(-96, 424, -96), { Dx = 150, Dy = 100, Dz = 150 })
	local base = {
		BackgroundU = 2,
		BackgroundV = 1,
		BubbleRelativeHumidity = 0.999,
		BubbleTemperaturePerturbation = 6,
	}
	local implicitRound = Atmosphere.new(grid, base)
	local roundOptions = table.clone(base)
	roundOptions.BubbleShape = "Round"
	local explicitRound = Atmosphere.new(grid, roundOptions)
	for name, field in implicitRound.State.Fields do
		check(
			buffer.tostring(field) == buffer.tostring(explicitRound.State.Fields[name]),
			"Default Round exactly preserves the old initial fields"
		)
	end
	local shapes = {}
	for _, selected in { "Round", "Wide", "Tower" } do
		local options = table.clone(base)
		options.BubbleShape = selected
		local simulation = Atmosphere.new(grid, options)
		local warmCells, extentY = 0, 0
		for index = 1, grid.Count do
			local _, y = grid:Coordinates(index)
			near(
				simulation.State:Get("qc", index),
				0,
				0,
				"Every shape starts with zero cloud water"
			)
			if
				simulation.State:Get("theta", index)
				> buffer.readf32(simulation.Profile.Theta, (y - 1) * 4)
			then
				warmCells += 1
				extentY = math.max(extentY, y)
			end
		end
		shapes[selected] = { Cells = warmCells, Top = extentY }
	end
	check(shapes.Wide.Cells > shapes.Round.Cells, "Wide supplies a larger warm/moist source")
	check(shapes.Tower.Top > shapes.Round.Top, "Tower supplies a taller warm/moist source")
	local small = Atmosphere.new(grid, { BubbleShape = "Wide", BubbleScale = 0.5 })
	local large = Atmosphere.new(grid, { BubbleShape = "Wide", BubbleScale = 1.5 })
	local smallWarm, largeWarm = 0, 0
	for index = 1, grid.Count do
		local _, y = grid:Coordinates(index)
		local reference = buffer.readf32(small.Profile.Theta, (y - 1) * 4)
		if small.State:Get("theta", index) > reference then
			smallWarm += 1
		end
		if large.State:Get("theta", index) > reference then
			largeWarm += 1
		end
		near(large.State:Get("qc", index), 0, 0, "Large shape never paints qc")
	end
	check(largeWarm > smallWarm, "Size changes the warm/moist source volume")
	for _, bad in { 0, 0.49, 1.51, math.huge, 0 / 0 } do
		rejects(function()
			Atmosphere.new(grid, { BubbleScale = bad })
		end, "Invalid cloud scale fails before starting")
	end
	local live =
		Atmosphere.new(grid, { BackgroundU = 2, BackgroundV = 1, ShearU = 0.002, ShearV = -0.001 })
	live:Step(0.25)
	local waterBytes = {
		qv = buffer.tostring(live.State.Fields.qv),
		qc = buffer.tostring(live.State.Fields.qc),
		qr = buffer.tostring(live.State.Fields.qr),
	}
	local oldW = buffer.tostring(live.Faces.W)
	local oldTheta = buffer.tostring(live.State.Fields.theta)
	local oldPressure = buffer.tostring(live.State.Fields.pressure)
	live:SetWind(8, -3)
	for name, bytes in waterBytes do
		check(
			buffer.tostring(live.State.Fields[name]) == bytes,
			"Live wind preserves water fields exactly"
		)
	end
	check(buffer.tostring(live.Faces.W) == oldW, "Live wind preserves vertical faces")
	check(
		buffer.tostring(live.State.Fields.theta) == oldTheta,
		"Live wind preserves thermal structure"
	)
	check(
		buffer.tostring(live.State.Fields.pressure) == oldPressure,
		"Live wind preserves absolute pressure"
	)
	near(live.Time, 0.25, 0, "Live wind does not reset time")
	for y = 0, grid.SizeY - 1 do
		local height = (y + 0.5) * grid.Dy
		near(
			buffer.readf32(live.Profile.U, y * 4),
			8 + 0.002 * height,
			1e-6,
			"Live X wind preserves shear target"
		)
		near(
			buffer.readf32(live.Profile.V, y * 4),
			-3 - 0.001 * height,
			1e-6,
			"Live Z wind preserves shear target"
		)
	end
	local publicU, profileU = buffer.tostring(live.Faces.U), buffer.tostring(live.Profile.U)
	for _, bad in { -31, 31, math.huge, 0 / 0 } do
		rejects(function()
			live:SetWind(bad, 0)
		end, "Unsupported live wind fails")
		check(
			buffer.tostring(live.Faces.U) == publicU and buffer.tostring(live.Profile.U) == profileU,
			"Rejected wind preserves committed faces and targets"
		)
	end
	local tiny = Atmosphere.new(Grid3D.new(3, 4, 3, 12, Vector3.zero, { Dx = 1, Dy = 100, Dz = 1 }))
	local tinyU = buffer.tostring(tiny.Faces.U)
	rejects(function()
		tiny:SetWind(30, 30)
	end, "Live wind fails if physical spacing violates CFL")
	check(buffer.tostring(tiny.Faces.U) == tinyU, "CFL wind rejection does not commit staged faces")
	live:Step(0.25)
	check(live:GetDiagnostics().ProjectionConverged, "Live wind remains compatible with projection")

	local speed = 1
	local settingsChanges = 0
	local controllerRoot, loadController = createLoader("src/server/Simulation", {
		game = {
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage")
				return { Shared = { Atmosphere = root } }
			end,
		},
		print = function() end,
		warn = function() end,
	})
	local controller = loadController(controllerRoot.SimulationController)
	controller.Initialize(
		base,
		{ SizeX = 16, SizeY = 12, SizeZ = 16, Dx = 150, Dy = 100, Dz = 150 },
		{ MaxCatchUpSteps = 1, FrameBudgetMilliseconds = 8 }
	)
	local Controls = loadController(controllerRoot.CloudControls)
	local controls = Controls.new(base, function(value: number)
		speed = value
	end, function()
		settingsChanges += 1
	end)
	controls:ExecuteText("speed 0.5")
	near(speed, 0.5, 0, "Text speed command calls validated playback setter")
	local oldState = controller.GetState()
	controls:ExecuteText("wind 8 -2")
	check(controller.GetState() == oldState, "Wind command preserves simulation ownership")
	near(controls.Config.BackgroundU, 8, 0, "Wind command becomes the reset background")
	near(settingsChanges, 1, 0, "Successful wind synchronizes settings once")
	controls:ExecuteText("pause")
	controller.Advance(100, speed)
	near(controller.GetTime(), 0, 0, "Pause advances neither time nor backlog")
	near(controller.GetDroppedTime(), 0, 0, "Pause does not fabricate dropped simulation time")
	controls:ExecuteText("form 1")
	check(not controller.GetDiagnostics().Paused, "Form resumes a paused simulation")
	check(
		controller.Advance(10, speed) == 1,
		"Formation retains the one-step laptop cap on a stalled frame"
	)
	near(controller.GetTime(), 0.25, 0, "Formation executes real fixed steps")
	near(
		controller.GetDiagnostics().FormationRemainingSeconds,
		0.75,
		0,
		"Dropped backlog is not counted as completed formation"
	)
	near(
		controller.GetDiagnostics().SimulationSpeed,
		2,
		0,
		"Formation requests at least 2x playback"
	)
	for _ = 1, 3 do
		controller.Advance(0.125, speed)
	end
	near(
		controller.GetDiagnostics().FormationRemainingSeconds,
		0,
		0,
		"Formation finishes exactly its queued time"
	)
	controller.Advance(0, speed)
	near(
		controller.GetDiagnostics().SimulationSpeed,
		0.5,
		0,
		"Requested playback is restored when formation ends"
	)
	controls:ExecuteText("spawn Wide Fast")
	check(
		controller.GetState() ~= oldState,
		"Spawn replaces the atmosphere after successful construction"
	)
	near(controller.GetTime(), 0, 0, "Spawn restarts physical time")
	near(controller.GetDroppedTime(), 0, 0, "Spawn resets backlog accounting")
	near(
		controls.Config.BubbleTemperaturePerturbation,
		8,
		0,
		"Fast formation uses its documented warm bubble"
	)
	near(
		controls.Config.BubbleRelativeHumidity,
		0.9999,
		0,
		"Fast formation uses its documented moisture"
	)
	check(controls.Config.BubbleShape == "Wide", "Spawn chooses Wide thermodynamic geometry")
	controls:ExecuteText("size 1.25")
	near(controls.Config.BubbleScale, 1.25, 0, "Size command sets the radius multiplier")
	controls:ExecuteText("spawn Wide Fast 1")
	near(controls.Config.BubbleScale, 1, 0, "Spawn can set shape, formation and size together")
	for index = 1, grid.Count do
		near(controller.GetState():Get("qc", index), 0, 0, "Fast spawn still paints no qc")
	end
	for _, command in
		{
			"spawn Wrong Fast",
			"spawn Wide Wrong",
			"wind 31 0",
			"wind nan 0",
			"wind 8",
			"wind 2 3 4",
			"speed 0",
			"form 241",
			"form 0.3",
			"size 2",
			"size",
			"spawn Wide Fast 0.4",
			"pause extra",
			"reset extra",
			"unknown",
			"",
			string.rep("a", 129),
		}
	do
		local current = controller.GetState()
		local config = serde.encode("json", controls.Config)
		local remaining = controller.GetDiagnostics().FormationRemainingSeconds
		rejects(function()
			controls:ExecuteText(command)
		end, "Malformed command is rejected: " .. command)
		check(controller.GetState() == current, "Rejected command does not reset the atmosphere")
		check(
			serde.encode("json", controls.Config) == config,
			"Rejected command does not change reset settings"
		)
		near(
			controller.GetDiagnostics().FormationRemainingSeconds,
			remaining,
			0,
			"Rejected command preserves formation queue"
		)
	end
	check(
		string.find(controls:Execute("help"), "wind", 1, true) ~= nil,
		"Help describes wind control"
	)
	check(type(controls:Execute("status")) == "table", "Status returns production diagnostics")
	local stateBeforeFailure = controller.GetState()
	local timeBeforeFailure = controller.GetTime()
	local thetaBeforeFailure = buffer.tostring(stateBeforeFailure.Fields.theta)
	rejects(function()
		controller.Restart({ MomentumOptions = { Viscosity = -1 } })
	end, "Late reset-constructor failure is reported")
	check(
		controller.GetState() == stateBeforeFailure,
		"Failed reset retains authoritative state ownership"
	)
	near(controller.GetTime(), timeBeforeFailure, 0, "Failed reset retains time")
	check(
		buffer.tostring(controller.GetState().Fields.theta) == thetaBeforeFailure,
		"Failed reset retains committed field bytes"
	)
	controls:ExecuteText("condensation Normal")
	near(
		controls.Config.BubbleTemperaturePerturbation,
		6,
		0,
		"Normal formation restores validated preview warmth"
	)
	near(
		controls.Config.BubbleRelativeHumidity,
		0.999,
		0,
		"Normal formation restores validated preview moisture"
	)
	controls:ExecuteText("pause")
	controls:ExecuteText("resume")
	check(not controller.GetDiagnostics().Paused, "Resume unpauses weather")
	print(
		"PASS: cloud shapes, live MAC wind, command validation, atomic reset, pause, bounded formation and speed restoration"
	)
	if quick then
		return
	end

	-- Actual controls drive a 240-second wind/reversal case. No cloned math.
	-- Compare presets with identical shape/size/wind; a wider source can rise
	-- differently from Round, so comparing to the old Round onset is misleading.
	controls:ExecuteText("spawn Wide Normal 1")
	controls:ExecuteText("wind 8 2")
	local normalFirstVisible: number? = nil
	for _ = 1, 160 do
		controller.Advance(0.25, 1)
		local d = controller.GetDiagnostics()
		if normalFirstVisible == nil and d.CloudCells > 0 then
			normalFirstVisible = d.Time
		end
	end
	controls:ExecuteText("spawn Wide Fast 1")
	controls:ExecuteText("wind 8 2")
	local initialWater = controller.GetDiagnostics().WaterSum
	local pressure = buffer.tostring(controller.GetState().Fields.pressure)
	local firstQc, firstVisible: number? = nil, nil
	local snapshots = {}
	local maxIterations, maxCourant, maxResidual = 0, 0, 0
	for step = 1, 960 do
		if step == 481 then
			local before = buffer.tostring(controller.GetState().Fields.qc)
			controls:ExecuteText("wind -8 -2")
			check(
				buffer.tostring(controller.GetState().Fields.qc) == before,
				"Wind reversal preserves naturally formed qc"
			)
		end
		controller.Advance(0.25, 1)
		local d = controller.GetDiagnostics()
		check(d.ProjectionConverged, "Command-driven moving cloud projection converges")
		check(
			d.ProjectionResidual <= d.ProjectionTolerance
				and d.ProjectionResidualMax <= d.ProjectionTolerance,
			"Command-driven moving cloud meets true residual criteria"
		)
		check(
			math.abs((d.WaterSum - initialWater) / initialWater) < 1e-6,
			"Command-driven cloud retains water within float32 precision"
		)
		if firstQc == nil and d.MaxCloudWater > 0 then
			firstQc = d.Time
		end
		if firstVisible == nil and d.CloudCells > 0 then
			firstVisible = d.Time
		end
		maxIterations = math.max(maxIterations, d.ProjectionIterations)
		maxCourant = math.max(maxCourant, d.MaxCourant)
		maxResidual = math.max(maxResidual, d.ProjectionResidualMax)
		if step % 120 == 0 then
			table.insert(snapshots, d)
		end
	end
	check(
		firstVisible ~= nil and normalFirstVisible ~= nil and firstVisible < normalFirstVisible,
		"Fast produces visible cloud sooner than Normal at identical Wide shape/size/wind"
	)
	check(
		controller.GetDiagnostics().CloudCells > 0,
		"Command-driven clouds survive the 240-second wind reversal"
	)
	local outwardX = (snapshots[4].CloudCentroidX - snapshots[1].CloudCentroidX + 1200) % 2400
		- 1200
	local returnX = (snapshots[8].CloudCentroidX - snapshots[4].CloudCentroidX + 1200) % 2400 - 1200
	check(
		outwardX > 500,
		"Positive live wind visibly translates the qc centroid over 30..120 seconds"
	)
	check(
		returnX < -500,
		"Live wind reversal changes cloud translation direction over 120..240 seconds"
	)
	check(
		buffer.tostring(controller.GetState().Fields.pressure) == pressure,
		"Controls preserve absolute thermodynamic pressure over long evolution"
	)
	local report = {
		Seconds = 240,
		Shape = "Wide",
		Formation = "Fast",
		Scale = 1,
		FirstQcSeconds = firstQc,
		FirstVisibleSeconds = firstVisible,
		NormalMatchedFirstVisibleSeconds = normalFirstVisible,
		OutwardCentroidXMeters30To120 = outwardX,
		ReturnCentroidXMeters120To240 = returnX,
		WindBefore = { U = 8, V = 2 },
		WindAfter120Seconds = { U = -8, V = -2 },
		MaximumIterations = maxIterations,
		MaximumCourant = maxCourant,
		MaximumResidualMax = maxResidual,
		FinalWaterDriftPercent = (controller.GetDiagnostics().WaterSum - initialWater)
			/ initialWater
			* 100,
		Snapshots = snapshots,
	}
	fs.writeFile("build/cloud-controls-validation.json", serde.encode("json", report))
	print(
		string.format(
			"PASS: 240s Wide/Fast live wind and reversal, visible at %.2fs; final cloud=%d water drift=%+.9f%% max PCG=%d CFL=%.6f",
			firstVisible,
			controller.GetDiagnostics().CloudCells,
			report.FinalWaterDriftPercent,
			maxIterations,
			maxCourant
		)
	)
end
