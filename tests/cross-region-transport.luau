--!strict

-- Manufactured liquid is used ONLY in these transport fixtures. Production
-- initialization never paints qc; the generation tests verify that separately.
return function(root: any, loadModule: any, check: any, near: any, rejects: any, quick: boolean?)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local Field = loadModule(root.World.WeatherField)
	local c = Coordinates.new()
	local function make(extra: any?): any
		local options = {
			SizeX = 8,
			SizeY = 3,
			SizeZ = 8,
			BackgroundU = 0,
			BackgroundV = 0,
			ShearU = 0,
			ShearV = 0,
			StreamfunctionAmplitude = 0,
			Microphysics = false,
		}
		for key, value in extra or {} do
			options[key] = value
		end
		return Field.new(c, options)
	end
	local stationary = make()
	local before: { [string]: string } = {}
	for _, name in { "theta", "qv", "qc", "qr", "pressure" } do
		before[name] = buffer.tostring(stationary.Fields[name])
	end
	stationary:Step(0.25)
	for name, bytes in before do
		check(
			buffer.tostring(stationary.Fields[name]) == bytes,
			"Zero wind preserves every scalar exactly"
		)
	end
	near(stationary.Time, 0.25, 0, "Fixed world step advances physical time")
	rejects(function()
		stationary:Step(0.2)
	end, "World field rejects variable physical timestep")
	rejects(function()
		stationary:ResetWaterBaseline()
	end, "Live world water baseline cannot hide drift")
	rejects(function()
		make({ Boundary = "Open" })
	end, "Unimplemented open boundaries are rejected explicitly")
	rejects(function()
		make({ SizeX = 10 })
	end, "Coarse cells align exactly with four logical regions")

	local constant = make({ BackgroundU = 8, BackgroundV = -2, StreamfunctionAmplitude = 100 })
	for _, name in { "theta", "qv", "qc", "qr" } do
		constant.State:Fill(name, if name == "theta" then 300 else 0.001)
	end
	constant:ResetWaterBaseline()
	for _ = 1, 24 do
		constant:Step(0.25)
	end
	for _, name in { "theta", "qv", "qc", "qr" } do
		for index = 1, constant.Count do
			near(
				constant.State:Get(name, index),
				if name == "theta" then 300 else 0.001,
				2e-12,
				"Divergence-free 3D transport preserves a constant field"
			)
		end
	end
	check(
		constant.DivergenceMax < 1e-14,
		"Shared streamfunction differences preserve discrete incompressibility"
	)
	local sealed = make({ Boundary = "Sealed", StreamfunctionAmplitude = 100 })
	sealed.State:Fill("qc", 0.001)
	sealed:ResetWaterBaseline()
	for _ = 1, 8 do
		sealed:Step(0.25)
	end
	near(
		sealed:GetDiagnostics().WaterDriftFraction,
		0,
		2e-13,
		"Sealed world circulation preserves water"
	)
	rejects(function()
		sealed:SetWind(8, 2)
	end, "Sealed walls explicitly reject incompatible horizontal wind")
	local sealedCentroid = make({ Boundary = "Sealed" })
	sealedCentroid.State:Set("qc", sealedCentroid.Grid:Index(1, 2, 1), 0.001)
	sealedCentroid.State:Set("qc", sealedCentroid.Grid:Index(8, 2, 8), 0.001)
	local sealedDiagnostic = sealedCentroid:GetDiagnostics()
	check(
		sealedDiagnostic.CloudCentroidDefined,
		"Equal clouds near opposite sealed walls have a defined centroid"
	)
	near(
		sealedDiagnostic.CloudCentroidX,
		0,
		1e-12,
		"Sealed X centroid is an arithmetic water-weighted mean"
	)
	near(
		sealedDiagnostic.CloudCentroidZ,
		0,
		1e-12,
		"Sealed Z centroid does not join opposite walls"
	)
	near(
		sealedDiagnostic.CloudCentroidStudX,
		0,
		1e-12,
		"Sealed centroid uses the same physical/world scale"
	)

	local translating = make({ BackgroundU = 8, BackgroundV = 2 })
	local repeated = make({ BackgroundU = 8, BackgroundV = 2 })
	for _, simulation in { translating, repeated } do
		for y = 1, 3 do
			simulation.State:Set("qc", simulation.State.Grid:Index(2, y, 2), 0.001)
			simulation.State:Set("qr", simulation.State.Grid:Index(2, y, 2), 0.0003)
		end
		simulation:ResetWaterBaseline()
	end
	local first = translating:GetDiagnostics()
	local steps = if quick then 128 else 960
	for _ = 1, steps do
		translating:Step(0.25)
		repeated:Step(0.25)
	end
	local last = translating:GetDiagnostics()
	for _, name in { "theta", "qv", "qc", "qr" } do
		check(
			buffer.tostring(translating.Fields[name]) == buffer.tostring(repeated.Fields[name]),
			"Same velocities and steps reproduce exact world transport bytes"
		)
	end
	near(last.QcSum, first.QcSum, 2e-16, "Cloud water is not duplicated or lost across region IDs")
	near(last.QrSum, first.QrSum, 2e-16, "Rain scalar remains conservatively transported")
	near(
		last.WaterDriftFraction,
		0,
		2e-12,
		"Water ledger remains conserved under global periodic transport"
	)
	near(last.RegionWaterNetSum, 0, 2e-14, "Shared region fluxes cancel globally")
	check(last.RegionCrossingQcSum > 0, "Liquid physically crosses shared region faces")
	check(
		last.InternalRegionCrossingQcSum > 0,
		"Internal region crossings are distinguished from full-world periodic seams"
	)
	near(
		last.RegionCrossingQcSum,
		last.InternalRegionCrossingQcSum + last.OuterPeriodicQcTransferSum,
		2e-14,
		"Internal and outer periodic liquid interface ledgers reconcile"
	)
	local positiveRegions = 0
	for regionIndex = 0, 15 do
		if buffer.readf64(translating.RegionQcFlux, regionIndex * 8) > 1e-8 then
			positiveRegions += 1
		end
	end
	check(
		positiveRegions >= (if quick then 4 else 12),
		"Cloud flux reaches multiple neighboring regions without regional resets"
	)
	for index = 1, translating.Count do
		check(
			translating.State:Get("qv", index) >= 0
				and translating.State:Get("qc", index) >= 0
				and translating.State:Get("qr", index) >= 0,
			"Conservative upwind transport preserves nonnegative moisture without clamps"
		)
	end

	-- A deliberately coarser physical scale reaches the substep path using a
	-- physically finite wind. Scaling is explicit through WorldCoordinates.
	local smallMeters = Coordinates.new({ StudsPerMeter = 100 })
	local fast = Field.new(smallMeters, {
		SizeX = 32,
		SizeY = 3,
		SizeZ = 32,
		BackgroundU = 8,
		BackgroundV = 2,
		ShearU = 0,
		ShearV = 0,
		StreamfunctionAmplitude = 0,
		Microphysics = false,
	})
	fast:Step(0.25)
	check(
		fast.Substeps >= 3 and fast.MaxCourant > 1,
		"Multidimensional CFL selects conservative transport substeps"
	)
	-- A valid alternate scale can make an otherwise valid live wind exceed the
	-- bounded CFL work. Rejection must leave the running Full-sized field usable.
	local rejectedWind = Field.new(smallMeters, {
		SizeX = 48,
		SizeY = 6,
		SizeZ = 48,
		BackgroundU = 8,
		BackgroundV = 2,
		ShearU = 0,
		ShearV = 0,
		StreamfunctionAmplitude = 200,
		Microphysics = false,
	})
	local preserved = {
		FacesU = rejectedWind.FacesU,
		FacesV = rejectedWind.FacesV,
		FacesW = rejectedWind.FacesW,
		ProfileU = rejectedWind.Profile.U,
		ProfileV = rejectedWind.Profile.V,
		Streamfunction = rejectedWind.Streamfunction,
	}
	for name, value in rejectedWind.Fields do
		preserved[name] = value
	end
	local originalBytes = {}
	for name, value in preserved do
		originalBytes[name] = buffer.tostring(value)
	end
	rejects(function()
		rejectedWind:SetWind(100, 100)
	end, "Live wind rejects a valid numeric value whose multidimensional CFL exceeds the work cap")
	for name, value in preserved do
		check(
			buffer.tostring(value) == originalBytes[name],
			"Rejected live wind preserves authoritative buffer " .. name
		)
	end
	near(rejectedWind.BackgroundU, 8, 0, "Rejected live wind preserves background U")
	near(rejectedWind.BackgroundV, 2, 0, "Rejected live wind preserves background V")
	near(rejectedWind.Time, 0, 0, "Rejected live wind preserves physical time")
	near(rejectedWind.ExternalWaterSum, 0, 0, "Rejected live wind preserves source accounting")
	rejectedWind:Step(0.25)
	near(rejectedWind.Time, 0.25, 0, "The original field still advances after rejected live wind")
	check(rejectedWind.Substeps <= 32, "Rejected live wind does not corrupt subsequent CFL work")
	local failed = make({ MaxSubsteps = 1 })
	for offset = 0, buffer.len(failed.FacesU) - 8, 8 do
		buffer.writef64(failed.FacesU, offset, 2000)
	end
	local savedTheta, savedLiquid =
		buffer.tostring(failed.Fields.theta), buffer.tostring(failed.Fields.qc)
	rejects(function()
		failed:Step(0.25)
	end, "Excessive CFL reports a numerical failure instead of clipping wind")
	near(failed.Time, 0, 0, "Rejected CFL step preserves simulation timeline")
	check(
		buffer.tostring(failed.Fields.theta) == savedTheta
			and buffer.tostring(failed.Fields.qc) == savedLiquid,
		"Rejected CFL step preserves authoritative buffers"
	)
	near(failed.ExternalWaterSum, 0, 0, "Rejected step does not commit source accounting")
	local divergent = make()
	buffer.writef64(divergent.FacesU, 8, 1)
	rejects(
		function()
			divergent:Step(0.25)
		end,
		"Divergent prescribed velocity is rejected rather than misreported as mixing-ratio conservation"
	)

	local forcing = {
		ThetaTarget = buffer.create(stationary.Count * 8),
		WaterTarget = buffer.create(stationary.Count * 8),
		Weights = buffer.create(stationary.Count * 8),
		Fraction = 1,
		MaxWaterSum = 0.01,
		MaxThetaSum = 1,
	}
	for index = 1, stationary.Count do
		local offset = (index - 1) * 8
		buffer.writef64(forcing.ThetaTarget, offset, stationary.State:Get("theta", index) + 1)
		buffer.writef64(forcing.WaterTarget, offset, stationary.State:Get("qv", index) + 0.001)
		buffer.writef64(forcing.Weights, offset, if index == 2 then 1 else 0)
	end
	local originalLiquid = buffer.tostring(stationary.Fields.qc)
	local receipt = stationary:InjectSource(forcing)
	near(
		receipt.WaterSum,
		0.001,
		1e-17,
		"External vapor source ledger uses represented float64 additions"
	)
	near(receipt.ThetaSum, 1, 1e-12, "External thermal source ledger is separate")
	check(
		buffer.tostring(stationary.Fields.qc) == originalLiquid,
		"Source forcing never directly paints cloud water"
	)
	local baselineTime = stationary.Time
	buffer.writef64(forcing.ThetaTarget, stationary.Count * 8 - 8, 0 / 0)
	local originalVapor = buffer.tostring(stationary.Fields.qv)
	rejects(function()
		stationary:Step(0.25, forcing)
	end, "Invalid late source target rejects the whole step")
	check(
		buffer.tostring(stationary.Fields.qv) == originalVapor,
		"Transactional source staging preserves earlier cells on failure"
	)
	near(stationary.Time, baselineTime, 0, "Rejected source keeps physical time")
	near(
		stationary.ExternalWaterSum,
		0.001,
		1e-17,
		"Rejected source preserves the previous external-input ledger"
	)
	return {
		Scenario = "manufactured-cross-region",
		SimulatedSeconds = translating.Time,
		Diagnostics = last,
		RegionsWithQcFlux = positiveRegions,
	}
end
