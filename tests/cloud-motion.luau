--!strict

return function(root: any, loadModule: any, check: any, near: any, _rejects: any, quick: boolean?)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local Field = loadModule(root.World.WeatherField)
	local coordinates = Coordinates.new()
	local function experiment(u: number, v: number): any
		local field = Field.new(coordinates, {
			SizeX = 16,
			SizeY = 3,
			SizeZ = 16,
			BackgroundU = u,
			BackgroundV = v,
			ShearU = 0,
			ShearV = 0,
			StreamfunctionAmplitude = 0,
			Microphysics = false,
		})
		for y = 1, 3 do
			field.State:Set("qc", field.State.Grid:Index(3, y, 4), 0.002)
		end
		field:ResetWaterBaseline()
		local start = field:GetDiagnostics()
		local previousX, previousZ = start.CloudCentroidX, start.CloudCentroidZ
		local distanceX, distanceZ = 0, 0
		local snapshots = { start }
		local steps = if quick then 120 else 960
		for tick = 1, steps do
			field:Step(0.25)
			if tick % 120 == 0 then
				local diagnostics = field:GetDiagnostics()
				check(
					diagnostics.CloudCentroidDefined,
					"Advected liquid retains a defined circular centroid"
				)
				distanceX += (diagnostics.CloudCentroidX - previousX + coordinates.WidthMeters / 2) % coordinates.WidthMeters - coordinates.WidthMeters / 2
				distanceZ += (diagnostics.CloudCentroidZ - previousZ + coordinates.DepthMeters / 2) % coordinates.DepthMeters - coordinates.DepthMeters / 2
				previousX, previousZ = diagnostics.CloudCentroidX, diagnostics.CloudCentroidZ
				table.insert(snapshots, diagnostics)
			end
		end
		local finish = field:GetDiagnostics()
		-- The first-order stencil has a known Fourier phase speed. Verify its
		-- actual field displacement, separately from debug interpolation.
		local function expected(speed: number, spacing: number, count: number): number
			local c = speed * 0.25 / spacing
			local angle = 2 * math.pi / count
			local phase = math.atan2(c * math.sin(angle), 1 - math.abs(c) * (1 - math.cos(angle)))
			return steps * phase / angle * spacing
		end
		near(
			distanceX,
			expected(u, field.Dx, field.SizeX),
			2e-9,
			"Measured X centroid follows actual upwind flux phase"
		)
		near(
			distanceZ,
			expected(v, field.Dz, field.SizeZ),
			2e-9,
			"Measured Z centroid follows actual upwind flux phase"
		)
		near(
			finish.QcSum,
			start.QcSum,
			3e-16,
			"Moving cloud fixture retains its total liquid water"
		)
		near(
			distanceX * coordinates.StudsPerMeter,
			distanceX * 2,
			0,
			"Travel meters and studs use one explicit scale"
		)
		check(
			(u == 0 or distanceX * u > 0) and (v == 0 or distanceZ * v > 0),
			"Cloud transport direction agrees with prescribed wind"
		)
		if not quick and u ~= 0 then
			check(
				math.abs(distanceX) > coordinates.WidthMeters / 4 * 3,
				"Cloud distribution travels across multiple full-world regions"
			)
		end
		return {
			WindU = u,
			WindV = v,
			SimulatedSeconds = field.Time,
			TravelXMeters = distanceX,
			TravelZMeters = distanceZ,
			TravelXStuds = distanceX * 2,
			TravelZStuds = distanceZ * 2,
			ExpectedWindXMeters = u * field.Time,
			ExpectedWindZMeters = v * field.Time,
			Snapshots = snapshots,
		}
	end
	local positive = experiment(8, 2)
	local negative = experiment(-8, -2)
	local zOnly = experiment(0, 8)
	near(
		positive.TravelXMeters,
		-negative.TravelXMeters,
		2e-9,
		"Changing wind reverses actual world-field movement"
	)
	near(positive.TravelZMeters, -negative.TravelZMeters, 2e-9, "Z wind reversal is symmetric")
	near(zOnly.TravelXMeters, 0, 2e-9, "Z-only wind does not script an X displacement")
	-- End-to-end production formation: no initial liquid is painted. Numerical
	-- liquid flux, rather than interpolated Parts, verifies regional movement.
	local Sources = loadModule(root.World.WorldCloudSources)
	local scenario = Sources.GetCoverage("Scattered")
	local natural = Field.new(coordinates, {
		SizeX = 32,
		SizeY = 6,
		SizeZ = 32,
		BackgroundU = 8,
		BackgroundV = 2,
		BackgroundRelativeHumidity = scenario.EnvironmentalRH,
	})
	local sourceManager =
		Sources.new(natural, { Seed = 84219, Coverage = "Scattered", AutoClouds = true })
	sourceManager:InitializeSources()
	for index = 1, natural.Count do
		near(
			natural.State:Get("qc", index),
			0,
			0,
			"Seeded world initialization does not paint cloud water"
		)
	end
	local productionSnapshots: { any } = {}
	local firstVisible: number? = nil
	local maximumCloud, maximumCourant, maximumDrift = 0, 0, 0
	local productionSteps = if quick then 16 else 960
	local initialBytes = natural:GetStorageBytes()
	for tick = 1, productionSteps do
		if tick == 480 then
			local timeBefore, liquidBefore = natural.Time, buffer.tostring(natural.Fields.qc)
			sourceManager:QueueSource()
			near(natural.Time, timeBefore, 0, "New world source does not reset physical time")
			check(
				buffer.tostring(natural.Fields.qc) == liquidBefore,
				"Existing clouds survive adding a new world source"
			)
		end
		local forcing = sourceManager:PrepareStep(tick, 0.25)
		natural:Step(0.25, forcing)
		sourceManager:CommitStep(tick)
		maximumCourant = math.max(maximumCourant, natural.MaxCourant)
		check(
			sourceManager.SamplesLastStep <= sourceManager.BuildSamplesPerStep,
			"World procedural build samples remain bounded per committed step"
		)
		if tick % 4 == 0 then
			local diagnostics = natural:GetDiagnostics()
			maximumCloud = math.max(maximumCloud, diagnostics.MaxCloudWater)
			maximumDrift = math.max(maximumDrift, math.abs(diagnostics.WaterDriftFraction))
			if firstVisible == nil and diagnostics.CloudCells > 0 then
				firstVisible = natural.Time
			end
			if tick % 120 == 0 or tick == productionSteps then
				table.insert(
					productionSnapshots,
					{ Field = diagnostics, Sources = sourceManager:GetDiagnostics() }
				)
			end
		end
	end
	local final = natural:GetDiagnostics()
	near(
		natural:GetStorageBytes(),
		initialBytes,
		0,
		"World field storage stays bounded during source evolution"
	)
	check(maximumDrift < 1e-10, "Natural world water drift subtracts measured external inputs")
	check(
		final.DivergenceMax < 1e-14,
		"Natural world retains compatible divergence-free face velocities"
	)
	if not quick then
		check(
			firstVisible ~= nil and maximumCloud > 1e-5,
			"Seeded subsaturated conditions naturally produce visible cloud water"
		)
		check(
			final.RegionCrossingQcSum > 1e-5,
			"Naturally condensed liquid crosses region interfaces through numerical flux"
		)
		check(
			final.InternalRegionCrossingQcSum > 1e-5,
			"Natural cloud water crosses internal boundaries rather than only the outer periodic seam"
		)
		check(
			final.ExternalWaterSum > 0,
			"Persistent formation tracks external vapor forcing separately"
		)
		local regionsWithLiquidFlux = 0
		for offset = 0, 15 * 8, 8 do
			if buffer.readf64(natural.RegionQcFlux, offset) > 1e-7 then
				regionsWithLiquidFlux += 1
			end
		end
		check(
			regionsWithLiquidFlux >= 4,
			"Naturally condensed cloud transport reaches several weather regions"
		)
	end
	return {
		Scenario = "field-verified-cloud-motion",
		Positive = positive,
		Negative = negative,
		ZOnly = zOnly,
		Natural = {
			Preset = "Laptop",
			SimulatedSeconds = natural.Time,
			FirstVisibleSeconds = firstVisible,
			MaxCloudWater = maximumCloud,
			MaxCourant = maximumCourant,
			MaxCorrectedWaterDriftFraction = maximumDrift,
			Final = final,
			SourceDiagnostics = sourceManager:GetDiagnostics(),
			Snapshots = productionSnapshots,
		},
	}
end
