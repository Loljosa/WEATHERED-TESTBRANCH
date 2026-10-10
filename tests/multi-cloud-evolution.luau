--!strict

-- Integration checks use the production generator, source manager, MAC solver,
-- transport and microphysics. None of their equations are copied here.
local createLoader = require("./RobloxModuleLoader")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Vector3 = require("@lune/roblox").Vector3

local function sourceFingerprint(directories: { string }): string
	local paths = {}
	local function collect(directory: string)
		for _, name in fs.readDir(directory) do
			local path = directory .. "/" .. name
			if fs.isDir(path) then
				collect(path)
			else
				table.insert(paths, path)
			end
		end
	end
	for _, directory in directories do
		collect(directory)
	end
	table.sort(paths)
	local contents = {}
	for _, path in paths do
		table.insert(contents, path .. "\0" .. fs.readFile(path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local function stateChecksum(simulation: any): string
	local contents = {}
	for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
		table.insert(
			contents,
			name .. "\0" .. buffer.tostring(simulation.State.Fields[name]) .. "\0"
		)
	end
	for _, name in { "U", "V", "W" } do
		table.insert(contents, name .. "\0" .. buffer.tostring(simulation.Faces[name]) .. "\0")
	end
	table.insert(contents, "Correction\0" .. buffer.tostring(simulation.Projection.Correction))
	return serde.hash("sha256", table.concat(contents))
end

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

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function periodicDisplacement(final: number, initial: number, length: number): number
	return (final - initial + length * 0.5) % length - length * 0.5
end

return function(root: any, loadModule: any, check: any, near: any, rejects: any, quick: boolean)
	local productionFingerprint = sourceFingerprint({ "src" })
	local testFingerprint = sourceFingerprint({ "scripts", "tests" })
	local sourceRevision =
		string.gsub(process.exec("git", { "rev-parse", "HEAD" }).stdout, "%s+$", "")
	local workingTreeChanged = process.exec("git", { "status", "--porcelain" }).stdout ~= ""
	local Atmosphere = loadModule(root)
	local Grid3D = loadModule(root.Core.Grid3D)
	local WarmCloud = loadModule(root.Microphysics.WarmCloud)
	local Constants = loadModule(root.Core.Constants)
	local Thermodynamics = loadModule(root.Thermodynamics.Thermodynamics)
	local Validation = loadModule(root.Utilities.Validation)
	local serverRoot, loadServer = createLoader("src/server/Simulation", {
		game = {
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage", "Unexpected source-manager service lookup")
				return { Shared = { Atmosphere = root } }
			end,
		},
		print = function() end,
		warn = function() end,
	})
	local Manager = loadServer(serverRoot.CloudSourceManager)
	local PerformanceSettings = loadServer(serverRoot.PerformanceSettings)
	local compact = Grid3D.new(8, 12, 8, 12, Vector3.new(-48, 424, -48), {
		Dx = 300,
		Dy = 100,
		Dz = 300,
	})

	local function configuration(): any
		return { DisableBubble = true, BackgroundU = 8, BackgroundV = 2 }
	end
	local function fixture(grid: any, seed: number, settings: any?): (any, any)
		local simulation = Atmosphere.new(grid, configuration())
		local options = if settings then table.clone(settings) else {}
		options.Seed = seed
		options.InitialSourceCount = options.InitialSourceCount or 2
		options.AutoClouds = options.AutoClouds == true
		local manager = Manager.new(simulation, options)
		manager:InitializeSources()
		return simulation, manager
	end
	local function physicsSnapshot(simulation: any): any
		local snapshot = {
			Time = simulation.Time,
			State = simulation.State,
			Fields = simulation.State.Fields,
			Faces = simulation.Faces,
			InitialWaterSum = simulation.InitialWaterSum,
			ExternalWaterSum = simulation.ExternalWaterSum,
			ExternalThetaSum = simulation.ExternalThetaSum,
			ExternalEnthalpySum = simulation.ExternalEnthalpySum,
			LastSourceInput = table.clone(simulation.LastSourceInput),
			Diagnostics = simulation:GetDiagnostics(),
			Buffers = {},
		}
		for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
			local field = simulation.State.Fields[name]
			snapshot.Buffers[name] = { Object = field, Bytes = buffer.tostring(field) }
		end
		for _, name in { "U", "V", "W" } do
			local field = simulation.Faces[name]
			snapshot.Buffers[name] = { Object = field, Bytes = buffer.tostring(field) }
		end
		snapshot.Correction = buffer.tostring(simulation.Projection.Correction)
		return snapshot
	end
	local function unchanged(simulation: any, before: any, message: string)
		for _, name in
			{
				"Time",
				"State",
				"Fields",
				"Faces",
				"InitialWaterSum",
				"ExternalWaterSum",
				"ExternalThetaSum",
				"ExternalEnthalpySum",
			}
		do
			local actual = if name == "Fields" then simulation.State.Fields else simulation[name]
			check(
				actual == before[name],
				message .. ": committed ownership, time and source ledgers"
			)
		end
		for name, saved in before.Buffers do
			local field = if name == "U"
					or name == "V"
					or name == "W"
				then simulation.Faces[name]
				else simulation.State.Fields[name]
			check(
				field == saved.Object and buffer.tostring(field) == saved.Bytes,
				message .. ": public physical buffers"
			)
		end
		check(
			buffer.tostring(simulation.Projection.Correction) == before.Correction,
			message .. ": projection cache"
		)
		for name, value in before.LastSourceInput do
			near(simulation.LastSourceInput[name], value, 0, message .. ": source receipt")
		end
		local diagnostics = simulation:GetDiagnostics()
		for name, value in before.Diagnostics do
			check(diagnostics[name] == value, message .. ": public diagnostics")
		end
	end
	local function samePhysics(actual: any, expected: any, message: string)
		near(actual.Time, expected.Time, 0, message .. ": physical clock")
		for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
			check(
				buffer.tostring(actual.State.Fields[name])
					== buffer.tostring(expected.State.Fields[name]),
				message .. ": exact float32 state"
			)
		end
		for _, name in { "U", "V", "W" } do
			check(
				buffer.tostring(actual.Faces[name]) == buffer.tostring(expected.Faces[name]),
				message .. ": exact MAC faces"
			)
		end
		check(
			buffer.tostring(actual.Projection.Correction)
				== buffer.tostring(expected.Projection.Correction),
			message .. ": exact projection warm start"
		)
		for _, name in { "ExternalWaterSum", "ExternalThetaSum", "ExternalEnthalpySum" } do
			near(actual[name], expected[name], 0, message .. ": exact source ledger")
		end
	end
	local function advance(simulation: any, manager: any, tick: number)
		local forcing = manager:PrepareStep(tick, Atmosphere.FixedDt)
		simulation:Step(Atmosphere.FixedDt, forcing)
		manager:CommitStep(tick)
	end

	local clear = Atmosphere.new(compact, configuration())
	for index = 1, compact.Count do
		local _, y = compact:Coordinates(index)
		near(
			clear.State:Get("theta", index),
			buffer.readf32(clear.Profile.Theta, (y - 1) * 4),
			0,
			"Clear sounding has no old centered bubble"
		)
		near(
			clear.State:Get("qc", index),
			0,
			0,
			"Clear sounding begins without painted cloud water"
		)
	end
	local first, firstManager = fixture(compact, 84219)
	local repeatSimulation, repeatManager = fixture(compact, 84219)
	local otherSeed = fixture(compact, -84219)
	local zeroSeed, zeroManager = fixture(compact, 0)
	samePhysics(first, repeatSimulation, "Same seed reproduces initial conditions")
	check(
		buffer.tostring(first.State.Fields.theta) ~= buffer.tostring(otherSeed.State.Fields.theta),
		"Different signed seeds produce distinct atmospheric sources"
	)
	near(zeroManager:GetDiagnostics().WorldSeed, 0, 0, "Zero is a valid world seed")
	Validation.CheckState(zeroSeed.State)
	near(
		firstManager:GetDiagnostics().InitialSourceCount,
		2,
		0,
		"Multiple independent initial source descriptions are supported"
	)
	near(first.ExternalWaterSum, 0, 0, "Initial source water belongs to the initial baseline")
	near(first.ExternalThetaSum, 0, 0, "Initial source heating is separate from ongoing forcing")
	for index = 1, compact.Count do
		near(first.State:Get("qc", index), 0, 0, "Seeded source geometry never paints qc")
	end
	local firstPressure = buffer.tostring(first.State.Fields.pressure)
	for tick = 1, 16 do
		advance(first, firstManager, tick)
		advance(repeatSimulation, repeatManager, tick)
	end
	samePhysics(
		first,
		repeatSimulation,
		"Same source seed and fixed ticks reproduce complete evolution"
	)
	check(
		first:GetDiagnostics().MaxW > 0,
		"Seeded thermal sources produce buoyancy-driven vertical motion"
	)
	local beforeQueue = physicsSnapshot(first)
	local firstId = firstManager:QueueSource()
	local repeatId = repeatManager:QueueSource()
	check(
		firstId == repeatId and type(firstId) == "string",
		"Manual source identifiers are deterministic"
	)
	unchanged(first, beforeQueue, "Queueing a source does not reset or mutate the atmosphere")
	for tick = 17, 32 do
		advance(first, firstManager, tick)
		advance(repeatSimulation, repeatManager, tick)
	end
	samePhysics(
		first,
		repeatSimulation,
		"Manual source compilation and forcing remain deterministic"
	)
	near(first.Time, 8, 0, "Adding a source preserves and advances existing physical time")
	check(
		buffer.tostring(first.State.Fields.pressure) == firstPressure,
		"Source forcing does not replace hydrostatic pressure"
	)
	check(
		first.ExternalWaterSum > 0 and first.ExternalThetaSum > 0,
		"Ongoing source water and heating inputs are tracked"
	)
	check(
		first.ExternalEnthalpySum > 0,
		"Source heating and vapor addition expose an approximate enthalpy-input sum"
	)
	near(
		first:GetDiagnostics().WaterDriftFraction,
		(first:GetDiagnostics().WaterSum - first.InitialWaterSum - first.ExternalWaterSum)
			/ first.InitialWaterSum,
		1e-15,
		"Water drift subtracts measured external vapor input"
	)
	rejects(function()
		first:ResetWaterBaseline()
	end, "An evolved atmosphere cannot silently redefine its conservation baseline")

	local function localizedForcing(simulation: any): any
		local thetaTarget = buffer.create(compact.Count * 4)
		buffer.copy(thetaTarget, 0, simulation.State.Fields.theta)
		local waterTarget = buffer.create(compact.Count * 4)
		for offset = 0, compact.Count * 4 - 4, 4 do
			buffer.writef32(
				waterTarget,
				offset,
				buffer.readf32(simulation.State.Fields.qv, offset)
					+ buffer.readf32(simulation.State.Fields.qc, offset)
					+ buffer.readf32(simulation.State.Fields.qr, offset)
			)
		end
		local offset = (compact:Index(4, 3, 4) - 1) * 4
		buffer.writef32(thetaTarget, offset, buffer.readf32(thetaTarget, offset) + 3)
		buffer.writef32(waterTarget, offset, buffer.readf32(waterTarget, offset) + 0.003)
		return {
			ThetaTarget = thetaTarget,
			WaterTarget = waterTarget,
			Fraction = 0.5,
			MaxWaterSum = 0.0001,
			MaxThetaSum = 0.25,
		}
	end
	local sourceOnly = Atmosphere.new(compact, configuration())
	local receiptForcing = localizedForcing(sourceOnly)
	local old = physicsSnapshot(sourceOnly)
	local oldWater = sourceOnly:GetDiagnostics().WaterSum
	local oldTheta = sourceOnly.State:GetCell("theta", 4, 3, 4)
	local receipt = table.clone(sourceOnly:InjectSource(receiptForcing))
	near(
		sourceOnly:GetDiagnostics().WaterSum - oldWater,
		receipt.WaterSum,
		1e-12,
		"Source receipt records represented float32 water increments"
	)
	near(
		sourceOnly.State:GetCell("theta", 4, 3, 4) - oldTheta,
		receipt.ThetaSum,
		0,
		"Source receipt records represented potential-temperature increments"
	)
	check(
		receipt.WaterSum <= receiptForcing.MaxWaterSum
			and receipt.ThetaSum <= receiptForcing.MaxThetaSum,
		"Float32 source injection cannot overspend explicit budgets"
	)
	local pressure = sourceOnly.State:GetCell("pressure", 4, 3, 4)
	near(
		receipt.EnthalpySum,
		Constants.SpecificHeatDryAir * Thermodynamics.Exner(pressure) * receipt.ThetaSum
			+ Constants.LatentHeatVaporization * receipt.WaterSum,
		1e-8,
		"Source approximate enthalpy receipt uses actual represented heat and vapor inputs"
	)
	for _, name in { "u", "v", "w", "qc", "qr", "pressure" } do
		check(
			buffer.tostring(sourceOnly.State.Fields[name]) == old.Buffers[name].Bytes,
			"Source-only injection preserves clouds, rain, momentum and pressure"
		)
	end
	near(sourceOnly.Time, 0, 0, "Source-only injection does not advance time")
	-- A tight budget must scale equal requests rather than privileging the first
	-- cell in traversal order. Compare actual represented float32 increments.
	local symmetric = Atmosphere.new(compact, configuration())
	local symmetricForcing = localizedForcing(symmetric)
	local coordinates = { { 2, 3, 2 }, { 6, 3, 2 }, { 2, 3, 6 }, { 6, 3, 6 } }
	buffer.copy(symmetricForcing.ThetaTarget, 0, symmetric.State.Fields.theta)
	buffer.copy(symmetricForcing.WaterTarget, 0, symmetric.State.Fields.qv)
	local beforeSymmetry = physicsSnapshot(symmetric)
	for _, cell in coordinates do
		local offset = (compact:Index(cell[1], cell[2], cell[3]) - 1) * 4
		buffer.writef32(
			symmetricForcing.ThetaTarget,
			offset,
			buffer.readf32(symmetricForcing.ThetaTarget, offset) + 3
		)
		buffer.writef32(
			symmetricForcing.WaterTarget,
			offset,
			buffer.readf32(symmetricForcing.WaterTarget, offset) + 0.003
		)
	end
	symmetricForcing.Fraction = 1
	symmetricForcing.MaxThetaSum = 6
	symmetricForcing.MaxWaterSum = 0.006
	local symmetricReceipt = table.clone(symmetric:InjectSource(symmetricForcing))
	local firstCell = coordinates[1]
	local vaporIncrement = symmetric.State:GetCell("qv", firstCell[1], firstCell[2], firstCell[3])
		- buffer.readf32(symmetric.Profile.Qv, 8)
	local thermalIncrement = symmetric.State:GetCell(
		"theta",
		firstCell[1],
		firstCell[2],
		firstCell[3]
	) - buffer.readf32(symmetric.Profile.Theta, 8)
	for _, cell in coordinates do
		local index = compact:Index(cell[1], cell[2], cell[3])
		near(
			symmetric.State:Get("qv", index) - buffer.readf32(symmetric.Profile.Qv, 8),
			vaporIncrement,
			2e-9,
			"Budget-limited equal vapor requests receive symmetric float32 increments"
		)
		near(
			symmetric.State:Get("theta", index) - buffer.readf32(symmetric.Profile.Theta, 8),
			thermalIncrement,
			0,
			"Budget-limited equal thermal requests receive equal represented increments"
		)
	end
	check(
		symmetricReceipt.WaterSum > 0 and symmetricReceipt.WaterSum <= symmetricForcing.MaxWaterSum,
		"Globally scaled vapor forcing respects the aggregate budget"
	)
	check(
		symmetricReceipt.ThetaSum > 0 and symmetricReceipt.ThetaSum <= symmetricForcing.MaxThetaSum,
		"Globally scaled heating respects the aggregate budget"
	)
	for _, name in { "u", "v", "w", "qc", "qr", "pressure" } do
		check(
			buffer.tostring(symmetric.State.Fields[name]) == beforeSymmetry.Buffers[name].Bytes,
			"Symmetric source forcing preserves clouds, rain, pressure and momentum"
		)
	end
	near(symmetric.Time, 0, 0, "Symmetric budgeted source forcing preserves time")
	-- A 0.1 K request rounds upward at this background temperature. Even when
	-- the aggregate budget equals (or slightly exceeds) the continuous requests,
	-- that rounding must not spend a later cell's share or suppress its forcing.
	local fractionalCoordinates = { coordinates[1], coordinates[2] }
	for _, budgetFactor in { 1, 1 + 1e-8 } do
		local fractional = Atmosphere.new(compact, configuration())
		local fractionalForcing = localizedForcing(fractional)
		buffer.copy(fractionalForcing.ThetaTarget, 0, fractional.State.Fields.theta)
		buffer.copy(fractionalForcing.WaterTarget, 0, fractional.State.Fields.qv)
		fractionalForcing.Fraction = 0.1
		local thetaRequested, vaporRequested = 0, 0
		for _, cell in fractionalCoordinates do
			local index = compact:Index(cell[1], cell[2], cell[3])
			local offset = (index - 1) * 4
			local oldThetaValue = fractional.State:Get("theta", index)
			local oldVaporValue = fractional.State:Get("qv", index)
			buffer.writef32(fractionalForcing.ThetaTarget, offset, oldThetaValue + 1)
			buffer.writef32(fractionalForcing.WaterTarget, offset, oldVaporValue + 0.001)
			thetaRequested += (buffer.readf32(fractionalForcing.ThetaTarget, offset) - oldThetaValue) * 0.1
			vaporRequested += (buffer.readf32(fractionalForcing.WaterTarget, offset) - oldVaporValue) * 0.1
		end
		fractionalForcing.MaxThetaSum = thetaRequested * budgetFactor
		fractionalForcing.MaxWaterSum = vaporRequested * budgetFactor
		local fractionalBefore = physicsSnapshot(fractional)
		local fractionalReceipt = table.clone(fractional:InjectSource(fractionalForcing))
		local thetaDelta = fractional.State:GetCell("theta", 2, 3, 2)
			- buffer.readf32(fractional.Profile.Theta, 8)
		local vaporDelta = fractional.State:GetCell("qv", 2, 3, 2)
			- buffer.readf32(fractional.Profile.Qv, 8)
		check(
			thetaDelta > 0 and thetaDelta <= 0.1,
			"Fractional heating never rounds above the individual request"
		)
		check(
			vaporDelta > 0 and vaporDelta <= vaporRequested / #fractionalCoordinates,
			"Fractional vapor input never rounds above the individual request"
		)
		for _, cell in fractionalCoordinates do
			near(
				fractional.State:GetCell("theta", cell[1], cell[2], cell[3])
					- buffer.readf32(fractional.Profile.Theta, 8),
				thetaDelta,
				0,
				"Equal fractional heating requests remain symmetric at the aggregate budget boundary"
			)
			near(
				fractional.State:GetCell("qv", cell[1], cell[2], cell[3])
					- buffer.readf32(fractional.Profile.Qv, 8),
				vaporDelta,
				0,
				"Equal fractional vapor requests remain symmetric at the aggregate budget boundary"
			)
		end
		check(
			fractionalReceipt.ThetaSum <= fractionalForcing.MaxThetaSum
				and fractionalReceipt.WaterSum <= fractionalForcing.MaxWaterSum,
			"Budget-boundary fractional forcing cannot overspend"
		)
		for _, name in { "u", "v", "w", "qc", "qr", "pressure" } do
			check(
				buffer.tostring(fractional.State.Fields[name])
					== fractionalBefore.Buffers[name].Bytes,
				"Fractional source rounding preserves all unrelated physical fields"
			)
		end
		near(fractional.Time, 0, 0, "Fractional source rounding preserves physical time")
		near(
			fractional.ExternalWaterSum,
			fractionalReceipt.WaterSum,
			0,
			"Fractional source vapor ledger records the represented input exactly"
		)
		near(
			fractional.ExternalThetaSum,
			fractionalReceipt.ThetaSum,
			0,
			"Fractional source thermal ledger records the represented input exactly"
		)
	end
	local invalid = localizedForcing(sourceOnly)
	buffer.writef32(invalid.ThetaTarget, compact.Count * 4 - 4, 0 / 0)
	local beforeInvalid = physicsSnapshot(sourceOnly)
	rejects(function()
		sourceOnly:InjectSource(invalid)
	end, "Late invalid source target fails atomically")
	unchanged(sourceOnly, beforeInvalid, "Rejected direct source injection")
	rejects(function()
		sourceOnly:Step(Atmosphere.FixedDt, invalid)
	end, "Invalid source forcing fails the entire physical timestep")
	unchanged(sourceOnly, beforeInvalid, "Rejected source timestep")
	local failed = Atmosphere.new(compact, {
		DisableBubble = true,
		BackgroundU = 8,
		BackgroundV = 2,
		ProjectionOptions = { MaxIterations = 1 },
	})
	local fresh = Atmosphere.new(compact, configuration())
	local forcing = localizedForcing(failed)
	local beforeFailed = physicsSnapshot(failed)
	rejects(function()
		failed:Step(Atmosphere.FixedDt, forcing)
	end, "Pressure iteration exhaustion after forcing rolls back source inputs")
	unchanged(failed, beforeFailed, "Failed projected source timestep")
	failed.Projection.MaxIterations = fresh.Projection.MaxIterations
	failed:Step(Atmosphere.FixedDt, forcing)
	fresh:Step(Atmosphere.FixedDt, forcing)
	samePhysics(failed, fresh, "A forced-step retry matches a fresh successful step")

	local quiet, quietManager = fixture(
		compact,
		84219,
		{ InitialSourceCount = 1, FormationIntervalTicks = 8, AutoClouds = false }
	)
	for tick = 1, 24 do
		advance(quiet, quietManager, tick)
		clear:Step(Atmosphere.FixedDt)
	end
	near(
		quietManager:GetDiagnostics().ScheduledSources,
		0,
		0,
		"Disabling auto-clouds suppresses scheduled source additions"
	)
	near(quiet.ExternalWaterSum, 0, 0, "Quiet periods introduce no external vapor")
	near(quiet.ExternalThetaSum, 0, 0, "Quiet periods introduce no external heating")
	near(clear:GetDiagnostics().QcSum, 0, 0, "Clear unsaturated air remains clear without forcing")

	local scenarios = {}
	for _, preset in if quick then { "Laptop" } else { "Laptop", "Full" } do
		local settings = PerformanceSettings.Resolve(preset)
		local grid = if quick
			then compact
			else Grid3D.new(
				settings.SizeX,
				settings.SizeY,
				settings.SizeZ,
				12,
				Vector3.new(-settings.SizeX * 6, 424, -settings.SizeZ * 6),
				{ Dx = settings.Dx, Dy = settings.Dy, Dz = settings.Dz }
			)
		local sampleBudget = settings.SourceBuildSamplesPerStep
		local simulation, manager = fixture(grid, 84219, {
			InitialSourceCount = settings.InitialSourceCount,
			MaxInitialSources = settings.MaxInitialSources,
			BuildSamplesPerStep = sampleBudget,
			AutoClouds = true,
			FormationIntervalTicks = 180,
		})
		local initial = simulation:GetDiagnostics()
		local initialBufferCount, initialBufferBytes = ownedBuffers({ simulation, manager })
		local seconds = if quick then 16 else if preset == "Laptop" then 240 else 40
		local steps = math.floor(seconds / Atmosphere.FixedDt)
		local manualTick = if quick then 32 else if preset == "Laptop" then 480 else 80
		local snapshots = {}
		local firstWater, firstVisible = nil, nil
		local maxResidual, maxDivergence, maxCourant, maxIterations = 0, 0, 0, 0
		local maxSourceSamples = 0
		local totalCoreMilliseconds, maximumCoreMilliseconds = 0, 0
		local runtimeStart = os.clock()
		for tick = 1, steps do
			if tick == manualTick then
				local before = physicsSnapshot(simulation)
				manager:QueueSource()
				unchanged(
					simulation,
					before,
					"Late manual source preserves existing clouds and physical time"
				)
			end
			advance(simulation, manager, tick)
			totalCoreMilliseconds += simulation.StepMilliseconds
			maximumCoreMilliseconds = math.max(maximumCoreMilliseconds, simulation.StepMilliseconds)
			local p = simulation.Projection.Last
			check(
				p.Converged and finite(p.Residual),
				"Seeded weather projection converges with finite residual"
			)
			check(
				p.AfterMax <= p.PostTolerance,
				"Seeded weather obeys projection divergence acceptance tolerance"
			)
			maxResidual = math.max(maxResidual, p.Residual)
			maxDivergence = math.max(maxDivergence, p.AfterMax)
			maxCourant =
				math.max(maxCourant, simulation.MomentumCourant, simulation.TransportCourant)
			maxIterations = math.max(maxIterations, p.Iterations)
			local sourceDiagnostics = manager:GetDiagnostics()
			maxSourceSamples = math.max(maxSourceSamples, sourceDiagnostics.SourceSamplesLastStep)
			check(
				sourceDiagnostics.SourceSamplesLastStep <= sampleBudget,
				"Procedural work is bounded by the source-sample budget"
			)
			check(
				sourceDiagnostics.PendingSources <= 2 and sourceDiagnostics.ActiveSources <= 2,
				"Pending and active source counts remain bounded"
			)
			local d = simulation:GetDiagnostics()
			if firstWater == nil and d.QcSum > 0 then
				firstWater = simulation.Time
			end
			if firstVisible == nil and d.CloudCells > 0 then
				firstVisible = simulation.Time
			end
			if tick % 120 == 0 or tick == steps or (quick and tick % 16 == 0) then
				d.Sources = sourceDiagnostics
				table.insert(snapshots, d)
			end
		end
		local elapsed = os.clock() - runtimeStart
		local final = simulation:GetDiagnostics()
		Validation.CheckState(simulation.State)
		simulation.Faces:CheckFinite()
		near(simulation.Time, seconds, 0, "Procedural weather commits every requested fixed step")
		check(
			math.abs(final.WaterDriftFraction) < 2e-5,
			"External-input-corrected water drift remains small"
		)
		local sourceFinal = manager:GetDiagnostics()
		check(
			final.ExternalWaterSum <= sourceFinal.SourceWaterBudget,
			"Ongoing vapor input remains within its lifetime domain budget"
		)
		check(
			final.ExternalThetaSum <= sourceFinal.SourceThetaBudget,
			"Ongoing thermal input remains within its lifetime domain budget"
		)
		check(
			maxCourant <= 0.8,
			"Seeded weather stays within the momentum/transport stability limit"
		)
		local finalBufferCount, finalBufferBytes = ownedBuffers({ simulation, manager })
		check(
			finalBufferCount == initialBufferCount and finalBufferBytes == initialBufferBytes,
			"Scheduler and simulation reuse bounded packed-buffer storage"
		)
		if not quick then
			check(firstWater ~= nil, "Warm/moist procedural sources naturally condense cloud water")
			check(
				firstVisible ~= nil,
				"Procedural clouds become visible through the actual qc threshold"
			)
		end
		local displacement = nil
		local firstCentroid = nil
		for _, snapshot in snapshots do
			if snapshot.CloudCentroidDefined then
				firstCentroid = snapshot
				break
			end
		end
		if firstCentroid and final.CloudCentroidDefined then
			displacement = {
				Seconds = final.Time - firstCentroid.Time,
				X = periodicDisplacement(
					final.CloudCentroidX,
					firstCentroid.CloudCentroidX,
					grid.SizeX * grid.Dx
				),
				Y = final.CloudCentroidY - firstCentroid.CloudCentroidY,
				Z = periodicDisplacement(
					final.CloudCentroidZ,
					firstCentroid.CloudCentroidZ,
					grid.SizeZ * grid.Dz
				),
				IncludesFormationAndDissipation = true,
			}
		end
		if not quick and preset == "Laptop" then
			check(
				displacement ~= nil
					and math.abs(displacement.X) + math.abs(displacement.Z) > grid.Dx * 0.1,
				"Cloud-water distribution moves under configured horizontal wind"
			)
			check(
				manager:GetDiagnostics().ScheduledOpportunities > 0,
				"Long-running atmosphere processes deterministic source opportunities"
			)
		end
		local evaporatedParcels, dryWaterLoss = 0, 0
		for index = 1, grid.Count do
			local qc = simulation.State:Get("qc", index)
			if qc > 0 then
				local _, vapor, cloud = WarmCloud.Adjust(
					simulation.State:Get("theta", index),
					0,
					qc,
					simulation.State:Get("pressure", index)
				)
				check(
					cloud >= 0 and cloud < qc,
					"Cloud generated by the solver evaporates in unfavorable dry air"
				)
				near(
					vapor + cloud,
					qc,
					1e-11,
					"Dissipation fixture conserves parcel water while evaporating naturally formed qc"
				)
				evaporatedParcels += 1
				dryWaterLoss += qc - cloud
			end
		end
		if not quick then
			check(
				evaporatedParcels > 0 and dryWaterLoss > 0,
				"Naturally formed cloud water can dissipate through real microphysics"
			)
		end
		table.insert(scenarios, {
			Preset = if quick then "CompactSmoke" else preset,
			Seed = 84219,
			Grid = {
				SizeX = grid.SizeX,
				SizeY = grid.SizeY,
				SizeZ = grid.SizeZ,
				Cells = grid.Count,
			},
			PhysicalSpacingMeters = { Dx = grid.Dx, Dy = grid.Dy, Dz = grid.Dz },
			SimulationSeconds = seconds,
			FirstCloudWaterSeconds = firstWater,
			FirstVisibleCloudSeconds = firstVisible,
			NativeRuntimeSeconds = elapsed,
			MeanNativeIntegrationTestMillisecondsPerStep = elapsed * 1000 / steps,
			MeanCoreStepMilliseconds = totalCoreMilliseconds / steps,
			MaximumCoreStepMilliseconds = maximumCoreMilliseconds,
			MaximumProjectionResidualRms = maxResidual,
			MaximumDivergenceAfter = maxDivergence,
			MaximumCourant = maxCourant,
			MaximumProjectionIterations = maxIterations,
			MaximumSourceSamplesPerStep = maxSourceSamples,
			OwnedBufferCount = finalBufferCount,
			OwnedBufferBytes = finalBufferBytes,
			FinalPhysicalStateSHA256 = stateChecksum(simulation),
			Initial = initial,
			Final = final,
			SourceDiagnostics = manager:GetDiagnostics(),
			CloudCentroidDisplacementMeters = displacement,
			DryParcelEvaporation = {
				Cells = evaporatedParcels,
				EvaporatedCloudMixingRatioSum = dryWaterLoss,
				ArtificialDryingTestOnly = true,
			},
			Snapshots = snapshots,
		})
		print(
			string.format(
				"PASS: %s seeded evolution %.2f s, first qc %s s, first visible %s s, corrected water drift %.9g%%, external vapor %.9g, residual %.9g s^-1",
				preset,
				seconds,
				tostring(firstWater),
				tostring(firstVisible),
				final.WaterDriftFraction * 100,
				final.ExternalWaterSum,
				maxResidual
			)
		)
	end
	fs.writeDir("build")
	fs.writeFile(
		if quick then "build/phase25-evolution-quick.json" else "build/phase25-evolution.json",
		serde.encode("json", {
			Mode = if quick then "Quick" else "Full",
			SourceRevision = sourceRevision,
			WorkingTreeChanged = workingTreeChanged,
			ProductionSourceSHA256 = productionFingerprint,
			TestSourceSHA256 = testFingerprint,
			FingerprintScope = {
				Production = "All files below src",
				Tests = "All files below scripts and tests",
			},
			Environment = "Native-host Lune with production modules; not Roblox Studio FPS",
			FixedDt = Atmosphere.FixedDt,
			WaterAccounting = "Unweighted mixing-ratio sums under the solver's constant-density approximation; external vapor additions subtracted from drift",
			EnthalpyAccounting = "External input summed in J/kg dry air; no claim of coupled-model enthalpy conservation",
			Scenarios = scenarios,
		}, true)
	)
	print(
		"PASS: multiple seeded sources, reproducible evolution, incremental injection, source budgets/rollback and cloud microphysics"
	)
end
