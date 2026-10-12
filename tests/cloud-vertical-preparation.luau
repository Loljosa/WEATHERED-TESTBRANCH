--!strict

-- Stage H is a production-field investigation, not a change to release defaults.
-- Increasing physical depth also increases displayed depth through 2 studs/m;
-- these tests never stretch a shallow field or claim resolved convection.
return function(root: any, loadModule: any, check: any, near: any, _rejects: any, quick: boolean?)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local Field = loadModule(root.World.WeatherField)
	local Sources = loadModule(root.World.WorldCloudSources)
	local Thermodynamics = loadModule(root.Thermodynamics.Thermodynamics)
	local Saturation = loadModule(root.Thermodynamics.Saturation)
	local Constants = loadModule(root.Core.Constants)
	local coverage = Sources.GetCoverage("Scattered")
	local results = {}
	for _, scenario in
		{
			{ Name = "Release shallow baseline", Layers = 6, HeightMeters = 72 },
			{ Name = "Eight-level deeper candidate", Layers = 8, HeightMeters = 240 },
			{ Name = "Twelve-level deeper candidate", Layers = 12, HeightMeters = 480 },
		}
	do
		local coordinates = Coordinates.new({ HeightMeters = scenario.HeightMeters })
		local field = Field.new(coordinates, {
			SizeX = 32,
			SizeY = scenario.Layers,
			SizeZ = 32,
			BackgroundU = 8,
			BackgroundV = 2,
			BackgroundRelativeHumidity = coverage.EnvironmentalRH,
		})
		local sourceManager = Sources.new(field, {
			Seed = 84219,
			Coverage = "Scattered",
			AutoClouds = false,
		})
		local initialized = os.clock()
		sourceManager:InitializeSources()
		local initializationMilliseconds = (os.clock() - initialized) * 1000
		near(
			field.Dy,
			scenario.HeightMeters / scenario.Layers,
			0,
			"Physical vertical cell spacing matches extent"
		)
		near(
			coordinates.TopStuds - coordinates.BottomStuds,
			scenario.HeightMeters * 2,
			0,
			"Displayed depth has no independent artistic stretching"
		)
		near(
			coordinates.BaseAltitudeMeters,
			1000,
			0,
			"Deeper candidate preserves absolute cloud-base altitude"
		)
		local previousPressure: number? = nil
		local previousTheta: number? = nil
		local previousExner: number? = nil
		for y = 0, scenario.Layers - 1 do
			local altitude = coordinates.BaseAltitudeMeters + (y + 0.5) * field.Dy
			local theta = buffer.readf64(field.Profile.Theta, y * 8)
			local pressure = buffer.readf64(field.PressureLayers, y * 8)
			local exner = Thermodynamics.Exner(pressure)
			near(
				theta,
				300 + 0.003 * altitude,
				1e-12,
				"Potential-temperature sounding retains physical-altitude definition"
			)
			check(
				pressure > 0 and pressure < Constants.ReferencePressure,
				"Hydrostatic pressure is positive absolute Pa"
			)
			local temperature = Thermodynamics.Temperature(theta, pressure)
			check(
				temperature >= Constants.SaturationMinimumTemperature
					and temperature <= Constants.SaturationMaximumTemperature,
				"Deeper sounding stays in supported warm-cloud saturation range"
			)
			local qsat = Saturation.MixingRatio(temperature, pressure)
			near(
				buffer.readf64(field.Profile.Qv, y * 8) / qsat,
				coverage.EnvironmentalRH,
				1e-14,
				"Environmental humidity is defined using each level's thermodynamic pressure"
			)
			if previousPressure and previousTheta and previousExner then
				check(
					pressure < previousPressure,
					"Absolute hydrostatic pressure decreases with altitude"
				)
				near(
					exner - previousExner,
					-Constants.Gravity
						/ (Constants.SpecificHeatDryAir * 0.003)
						* math.log(theta / previousTheta),
					3e-15,
					"Discrete layer Exner difference agrees with hydrostatic profile integral"
				)
			end
			previousPressure, previousTheta, previousExner = pressure, theta, exner
		end
		for _, source in sourceManager.InitialSources do
			check(
				source.BaseAltitude >= coordinates.BaseAltitudeMeters + field.Dy,
				"Sources remain above sealed lower boundary"
			)
			check(
				source.TopAltitude <= coordinates.TopAltitudeMeters - field.Dy + 1e-10,
				"Sources remain below sealed upper boundary"
			)
			check(
				source.TopAltitude - source.BaseAltitude >= 3 * field.Dy - 1e-10,
				"Sources retain a resolved vertical envelope"
			)
		end
		for index = 1, field.Count do
			near(
				field.State:Get("qc", index),
				0,
				0,
				"Candidate initialization never paints cloud water"
			)
			local theta, vapor, pressure =
				field.State:Get("theta", index),
				field.State:Get("qv", index),
				field.State:Get("pressure", index)
			local qsat =
				Saturation.MixingRatio(Thermodynamics.Temperature(theta, pressure), pressure)
			check(
				vapor <= qsat * (1 + 1e-12),
				"Seeded thermal/moisture perturbations start subsaturated"
			)
		end
		local steps = if quick then 16 else 240
		local firstLiquid: number? = nil
		local firstVisible: number? = nil
		local maxDrift, maxCourant, maxDivergence, maxCloud, stepMilliseconds = 0, 0, 0, 0, 0
		for tick = 1, steps do
			-- Queue one ongoing source; construction and forcing use the exact
			-- same bounded production scheduler and source-accounting ledger.
			if tick == 80 then
				local timeBefore = field.Time
				sourceManager:QueueSource()
				near(
					field.Time,
					timeBefore,
					0,
					"Source addition preserves deeper candidate timeline"
				)
			end
			local forcing = sourceManager:PrepareStep(tick, Field.FixedDt)
			local started = os.clock()
			field:Step(Field.FixedDt, forcing)
			stepMilliseconds += (os.clock() - started) * 1000
			sourceManager:CommitStep(tick)
			check(
				sourceManager.SamplesLastStep <= sourceManager.BuildSamplesPerStep,
				"Deeper source construction obeys the same bounded noise-sampling work"
			)
			maxCourant = math.max(maxCourant, field.MaxCourant)
			maxDivergence = math.max(maxDivergence, field.DivergenceMax)
			if tick % 4 == 0 then
				local diagnostics = field:GetDiagnostics()
				maxDrift = math.max(maxDrift, math.abs(diagnostics.WaterDriftFraction))
				maxCloud = math.max(maxCloud, diagnostics.MaxCloudWater)
				if firstLiquid == nil and diagnostics.QcSum > 1e-12 then
					firstLiquid = field.Time
				end
				if firstVisible == nil and diagnostics.CloudCells > 0 then
					firstVisible = field.Time
				end
				check(
					diagnostics.ExternalWaterSum >= 0 and diagnostics.ExternalThetaSum >= 0,
					"Candidate ongoing source ledgers are explicit and nonnegative"
				)
			end
		end
		check(
			maxDrift < 1e-11,
			"Deeper candidate conserves source-corrected unweighted water within double-precision tolerance"
		)
		check(
			maxDivergence < 1e-10,
			"Deeper candidate retains compatible divergence-free prescribed velocities"
		)
		check(
			maxCourant <= field.Advection.CourantLimit,
			"Deeper candidate remains within one-substep multidimensional CFL limit"
		)
		if not quick then
			check(
				firstLiquid ~= nil,
				"Production microphysics naturally forms liquid in each tested depth"
			)
		end
		for _, name in { "theta", "qv", "qc", "qr", "pressure", "u", "v", "w" } do
			for index = 1, field.Count do
				local value = field.State:Get(name, index)
				check(
					value == value and math.abs(value) < math.huge,
					"Deeper production field remains finite"
				)
				if name == "qv" or name == "qc" or name == "qr" then
					check(
						value >= 0,
						"Deeper candidate moisture stays nonnegative without clipping"
					)
				end
			end
		end
		local final = field:GetDiagnostics()
		table.insert(results, {
			Name = scenario.Name,
			Layers = scenario.Layers,
			HeightMeters = scenario.HeightMeters,
			VerticalSpacingMeters = field.Dy,
			BottomStuds = coordinates.BottomStuds,
			TopStuds = coordinates.TopStuds,
			CellCount = field.Count,
			FieldBufferBytes = field:GetStorageBytes(),
			SourceBufferBytes = field.Count * 8 * 9,
			SimulatedSeconds = field.Time,
			FirstLiquidSeconds = firstLiquid,
			FirstVisibleSeconds = firstVisible,
			MaximumCloudWater = maxCloud,
			FinalCloudCells = final.CloudCells,
			MaximumCorrectedWaterDriftFraction = maxDrift,
			MaximumCourant = maxCourant,
			MaximumDivergencePerSecond = maxDivergence,
			ExternalWaterSum = final.ExternalWaterSum,
			ExternalThetaSum = final.ExternalThetaSum,
			NativeProbeMeanStepMilliseconds = stepMilliseconds / steps,
			NativeProbeSourceInitializationMilliseconds = initializationMilliseconds,
		})
	end
	return {
		Experiments = results,
		TimingScope = "Native Lune exploratory production-field probe; not isolated hardware/Studio FPS benchmark",
		Decision = "Retain the six-level 72 m release default; deeper fields need full preset, source, coupling and rendering validation before enablement",
		PhysicsLimit = "All candidates retain prescribed streamfunction circulation; no world-scale dynamic buoyancy or resolved deep convection",
	}
end
