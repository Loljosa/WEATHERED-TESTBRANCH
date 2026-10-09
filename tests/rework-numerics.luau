--!strict

local Vector3 = require("@lune/roblox").Vector3

return function(root: any, loadModule: any, check: any, near: any, rejects: any)
	local Grid3D = loadModule(root.Core.Grid3D)
	local Geometry = loadModule(root.Core.Geometry)
	local State = loadModule(root.Core.AtmosphereState)
	local Faces = loadModule(root.Core.FaceVelocity)
	local Transport = loadModule(root.Dynamics.Transport)
	local Projection = loadModule(root.Dynamics.Projection)
	local Momentum = loadModule(root.Dynamics.Momentum)
	local Sounding = loadModule(root.Thermodynamics.Sounding)
	local WarmCloud = loadModule(root.Microphysics.WarmCloud)
	local Saturation = loadModule(root.Thermodynamics.Saturation)
	local Thermodynamics = loadModule(root.Thermodynamics.Thermodynamics)
	local Constants = loadModule(root.Core.Constants)
	local rounding = buffer.create(4)
	local function f32(value: number): number
		buffer.writef32(rounding, 0, value)
		return buffer.readf32(rounding, 0)
	end

	local theta, vapor, cloud = 285, f32(Saturation.MixingRatio(285, 100000)), 0
	local initialWater = vapor
	for _ = 1, 10000 do
		theta, vapor, cloud = WarmCloud.AdjustFloat32(theta, vapor, cloud, 100000, rounding)
	end
	near(vapor + cloud, initialWater, 0, "Stationary rounded saturation does not accumulate water")
	near(cloud, 0, 0, "Sub-ULP vapor transfer cannot repeatedly create liquid")
	for _, initial in { { 293.15, 0.02, 0 }, { 293.15, 0.002, 0.002 }, { 293.15, 0.0147, 0.005 } } do
		local parcelTheta, parcelVapor, parcelCloud =
			f32(initial[1]), f32(initial[2]), f32(initial[3])
		local water = parcelVapor + parcelCloud
		local enthalpy = Constants.SpecificHeatDryAir
				* Thermodynamics.Temperature(parcelTheta, 100000)
			+ Constants.LatentHeatVaporization * parcelVapor
		for _ = 1, 200 do
			parcelTheta, parcelVapor, parcelCloud =
				WarmCloud.AdjustFloat32(parcelTheta, parcelVapor, parcelCloud, 100000, rounding)
			check(
				parcelVapor >= 0 and parcelCloud >= 0,
				"Rounded phase adjustment preserves nonnegative water"
			)
			check(
				parcelTheta == f32(parcelTheta)
					and parcelVapor == f32(parcelVapor)
					and parcelCloud == f32(parcelCloud),
				"Rounded phase outputs are representable float32 values"
			)
		end
		near(
			parcelVapor + parcelCloud,
			water,
			3e-10,
			"Repeated rounded phase conversion conserves water to liquid float32 precision"
		)
		local newEnthalpy = Constants.SpecificHeatDryAir
				* Thermodynamics.Temperature(parcelTheta, 100000)
			+ Constants.LatentHeatVaporization * parcelVapor
		near(
			newEnthalpy,
			enthalpy,
			0.2,
			"Rounded latent heating preserves moist enthalpy within temperature quantization"
		)
	end
	rejects(function()
		WarmCloud.AdjustFloat32(300, 0.01, 0, 100000, buffer.create(0))
	end, "Phase adjustment rejects undersized caller-owned rounding scratch")
	print(
		"PASS: 10000 stationary rounded phase cycles and condensation/evaporation float32 conservation"
	)

	-- This horizontal rotational flow is exactly divergence-free: U varies only
	-- with z, V only with x, and every vertical face is sealed. It exercises two
	-- dimensions together near the outgoing CFL limit without a pressure solve.
	local grid =
		Grid3D.new(12, 5, 10, 12, Vector3.new(-72, 24, -60), { Dx = 40, Dy = 80, Dz = 100 })
	local geometry = Geometry.new(grid)
	for _, axis in { "X", "Y", "Z" } do
		for _, sign in { -1, 1 } do
			local state = State.new(grid)
			state:Fill("qv", 0)
			state:SetCell("qv", 6, 3, 5, 0.01)
			state:SetCell("qc", 6, 3, 5, 0.003)
			state:SetCell("qr", 6, 3, 5, 0.001)
			local faces = Faces.new(geometry)
			if axis == "Y" then
				local face = grid:Index(6, if sign > 0 then 4 else 3, 5) - 1
				buffer.writef32(faces.W, face * 4, sign * 5)
			else
				for offset = 0, grid.Count * 4 - 4, 4 do
					buffer.writef32(if axis == "X" then faces.U else faces.V, offset, sign * 5)
				end
			end
			faces:Seal()
			local water, weightedPosition = 0, 0
			for index = 1, grid.Count do
				water += state:Get("qv", index) + state:Get("qc", index) + state:Get("qr", index)
			end
			Transport.new(geometry):Advance(state, faces, 0.25)
			local newWater = 0
			for index = 1, grid.Count do
				local x, y, z = grid:Coordinates(index)
				local mass = state:Get("qv", index)
					+ state:Get("qc", index)
					+ state:Get("qr", index)
				local coordinate = if axis == "X"
					then (x - 0.5) * grid.Dx
					elseif axis == "Y" then (y - 0.5) * grid.Dy
					else (z - 0.5) * grid.Dz
				newWater += mass
				weightedPosition += mass * coordinate
				check(
					state:Get("qv", index) >= 0
						and state:Get("qc", index) >= 0
						and state:Get("qr", index) >= 0,
					"FCT pulse remains nonnegative in every transport direction"
				)
			end
			near(
				newWater,
				water,
				0.50001 * 1.1920928955078125e-7 * water,
				"FCT conserves a pulse within the float32 commit rounding bound in every signed direction"
			)
			local initialCoordinate = if axis == "X"
				then 5.5 * grid.Dx
				elseif axis == "Y" then 2.5 * grid.Dy
				else 4.5 * grid.Dz
			check(
				sign * (weightedPosition / newWater - initialCoordinate) > 0,
				"FCT pulse centroid moves with the signed face velocity"
			)
		end
	end
	for _, scheme in { "FCT", "Upwind" } do
		local state = State.new(grid)
		local faces = Faces.new(geometry)
		local minimum, maximum, totals = {}, {}, {}
		for _, field in { "theta", "qv", "qc", "qr" } do
			minimum[field], maximum[field], totals[field] = math.huge, -math.huge, 0
		end
		for index = 1, grid.Count do
			local x, y, z = grid:Coordinates(index)
			local smooth = 0.5
				+ 0.5
					* math.sin(2 * math.pi * (x - 0.5) / grid.SizeX)
					* math.cos(2 * math.pi * (z - 0.5) / grid.SizeZ)
			local sharp = if (x + 2 * z + y) % 5 < 2 then 1 else 0
			state:Set("theta", index, 290 + 20 * smooth)
			state:Set("qv", index, 0.005 + 0.01 * smooth)
			state:Set("qc", index, 0.002 * sharp)
			state:Set("qr", index, 0.001 * (1 - sharp))
			buffer.writef32(
				faces.U,
				(index - 1) * 4,
				24 * math.cos(2 * math.pi * (z - 0.5) / grid.SizeZ)
			)
			buffer.writef32(
				faces.V,
				(index - 1) * 4,
				14 * math.sin(2 * math.pi * (x - 0.5) / grid.SizeX)
			)
			for field in totals do
				local value = state:Get(field, index)
				minimum[field] = math.min(minimum[field], value)
				maximum[field] = math.max(maximum[field], value)
				totals[field] += value
			end
		end
		faces:Seal()
		near(
			Projection.new(geometry):Divergence(faces),
			0,
			0,
			"Bounds test flow is exactly divergence-free"
		)
		local dt = 0.79 / (24 / grid.Dx + 14 / grid.Dz)
		local transport = Transport.new(geometry, { Scheme = scheme })
		local limitedFaces = 0
		for step = 1, 60 do
			transport:Advance(state, faces, dt)
			limitedFaces += transport.Last.LimitedFaces
			if step % 10 == 0 then
				for index = 1, grid.Count do
					for field in totals do
						local value = state:Get(field, index)
						local tolerance = 2e-7 * math.max(1e-3, maximum[field])
						check(
							value >= minimum[field] - tolerance
								and value <= maximum[field] + tolerance,
							"Multidimensional transport respects initial smooth/sharp scalar bounds"
						)
					end
				end
			end
		end
		for field, total in totals do
			local finalTotal = 0
			for index = 1, grid.Count do
				finalTotal += state:Get(field, index)
			end
			near(
				finalTotal,
				total,
				2e-6 * math.max(1e-3, total),
				"Multistep transport independently conserves every scalar species"
			)
		end
		if scheme == "FCT" then
			check(limitedFaces > 0, "Discontinuous fields activate shared face limiting")
		end
	end

	local zeroFaces = Faces.new(geometry)
	local relativeOnly =
		Projection.new(geometry, { AbsoluteTolerance = 0, RelativeTolerance = 1e-7 })
	local zeroResult = relativeOnly:Project(zeroFaces, 0.25)
	check(
		zeroResult.Converged and zeroResult.TargetTolerance == 0,
		"Relative-only projection accepts an exactly solenoidal zero field"
	)
	near(zeroResult.ResidualMax, 0, 0, "Zero projection reports zero maximum equation residual")
	local zeroU = buffer.tostring(zeroFaces.U)
	rejects(function()
		relativeOnly:Project(zeroFaces, 0 / 0)
	end, "Projection rejects nonfinite dt after a successful solve")
	check(
		not relativeOnly.Last.Converged,
		"Early projection failure cannot retain a stale convergence flag"
	)
	check(
		buffer.tostring(zeroFaces.U) == zeroU,
		"Early projection failure leaves input velocities unchanged"
	)
	local aliasFaces = Faces.new(geometry)
	aliasFaces.V = aliasFaces.U
	rejects(function()
		Projection.new(geometry):Project(aliasFaces, 0.25)
	end, "Projection rejects aliased authoritative velocity components")
	for _, dimensions in { { 1, 4, 1 }, { 1, 4, 5 }, { 5, 4, 1 } } do
		local reducedGrid =
			Grid3D.new(dimensions[1], dimensions[2], dimensions[3], 12, Vector3.zero)
		local reducedGeometry = Geometry.new(reducedGrid)
		local reducedFaces = Faces.new(reducedGeometry)
		for index = 0, reducedGeometry.Count - 1 do
			local x, y, z = reducedGrid:Coordinates(index + 1)
			if y > 1 then
				buffer.writef32(
					reducedFaces.W,
					index * 4,
					math.sin(math.pi * (y - 1) / reducedGrid.SizeY)
				)
			end
			buffer.writef32(
				reducedFaces.U,
				index * 4,
				math.sin(2 * math.pi * (x - 1) / reducedGrid.SizeX)
			)
			buffer.writef32(
				reducedFaces.V,
				index * 4,
				math.cos(2 * math.pi * (z - 1) / reducedGrid.SizeZ)
			)
		end
		reducedFaces:Seal()
		local result = Projection.new(reducedGeometry):Project(reducedFaces, 0.25)
		check(
			result.Converged and result.AfterMax <= result.PostTolerance,
			"Pressure projection handles singleton periodic axes"
		)
		check(
			result.Residual <= result.TargetTolerance
				and result.ResidualMax <= result.TargetTolerance,
			"Pressure solver certifies true RMS and maximum residual"
		)
	end
	local function magnitudeProjection(background: number): any
		local faces = Faces.new(geometry)
		local function potential(x: number, y: number, z: number): number
			return 500
				* math.sin(2 * math.pi * (x - 0.5) / grid.SizeX)
				* math.cos(2 * math.pi * (z - 0.5) / grid.SizeZ)
				* math.cos(math.pi * (y - 0.5) / grid.SizeY)
		end
		for index = 0, geometry.Count - 1 do
			local x, y, z = grid:Coordinates(index + 1)
			buffer.writef32(
				faces.U,
				index * 4,
				background
					+ (potential(x, y, z) - potential((x - 2) % grid.SizeX + 1, y, z)) / grid.Dx
			)
			buffer.writef32(
				faces.V,
				index * 4,
				-2 + (potential(x, y, z) - potential(x, y, (z - 2) % grid.SizeZ + 1)) / grid.Dz
			)
			if y > 1 then
				buffer.writef32(
					faces.W,
					index * 4,
					(potential(x, y, z) - potential(x, y - 1, z)) / grid.Dy
				)
			end
		end
		faces:Seal()
		return Projection.new(geometry):Project(faces, 0.25)
	end
	local small = magnitudeProjection(3)
	local large = magnitudeProjection(1000000)
	check(
		large.QuantizationFloor > small.QuantizationFloor * 100000,
		"Pressure float32 quantization bound scales with velocity magnitude"
	)
	check(
		large.AfterMax <= large.PostTolerance and large.ResidualMax <= large.TargetTolerance,
		"Large background wind obeys separately reported solver and rounding bounds"
	)
	near(
		large.PostTolerance,
		large.TargetTolerance
			+ large.QuantizationFloor
			+ large.F64RoundingFloor
			+ math.abs(large.CompatibilityMean),
		1e-15,
		"Pressure postcondition accounts explicitly for both floating-point precisions"
	)
	print(
		string.format(
			"PASS: zero/relative-only projection, failure flags, degenerate axes, and magnitude-dependent float32 rounding floors %.3g -> %.3g s^-1",
			small.QuantizationFloor,
			large.QuantizationFloor
		)
	)
	local roughProjection = Projection.new(geometry)
	local roughFaces = Faces.new(geometry)
	for _, phase in { 1, -0.7 } do
		for index = 0, grid.Count - 1 do
			local x, y, z = grid:Coordinates(index + 1)
			buffer.writef32(roughFaces.U, index * 4, phase * ((x + 2 * z + y) % 4 - 1.5))
			buffer.writef32(roughFaces.V, index * 4, phase * math.cos(2.4 * x + 1.7 * z))
			buffer.writef32(
				roughFaces.W,
				index * 4,
				if y > 1 then phase * math.sin(1.2 * x + 2.8 * y + 0.9 * z) else 0
			)
		end
		roughFaces:Seal()
		local result = roughProjection:Project(roughFaces, 0.25)
		check(
			result.Converged
				and result.Residual <= result.TargetTolerance
				and result.ResidualMax <= result.TargetTolerance,
			"Rough changed forcing verifies the pressure warm start against the true equation"
		)
		check(
			result.AfterRms < result.BeforeRms * 1e-5 and result.AfterMax <= result.PostTolerance,
			"Pressure correction removes high-frequency divergence after forcing reversal"
		)
	end

	-- Exercise all horizontal momentum donor signs and both transverse channels.
	-- With viscosity disabled and balanced thermodynamics, the one-step result
	-- is the analytically known upwind fraction followed by exact linear drag.
	local momentumGrid = Grid3D.new(8, 6, 7, 12, Vector3.zero, { Dx = 40, Dy = 80, Dz = 100 })
	local momentumGeometry = Geometry.new(momentumGrid)
	for _, test in
		{
			{ Component = "V", Axis = "X", Speed = -8 },
			{ Component = "U", Axis = "Z", Speed = 6 },
			{ Component = "U", Axis = "Z", Speed = -6 },
			{ Component = "W", Axis = "X", Speed = -8 },
		}
	do
		local state = State.new(momentumGrid)
		local profile = Sounding.Initialize(state, momentumGrid.Dy)
		for index = 1, momentumGrid.Count do
			local x, y, z = momentumGrid:Coordinates(index)
			state:Set("theta", index, buffer.readf32(profile.Theta, (y - 1) * 4))
			state:Set("qv", index, buffer.readf32(profile.Qv, (y - 1) * 4))
			if test.Axis == "X" then
				buffer.writef32(profile.U, (y - 1) * 4, test.Speed)
			else
				buffer.writef32(profile.V, (y - 1) * 4, test.Speed)
			end
		end
		local faces = Faces.new(momentumGeometry)
		for index = 0, momentumGrid.Count - 1 do
			local x, _, z = momentumGrid:Coordinates(index + 1)
			local coordinate = if test.Axis == "X" then x else z
			local count = if test.Axis == "X" then momentumGrid.SizeX else momentumGrid.SizeZ
			buffer.writef32(
				faces[test.Component],
				index * 4,
				math.sin(2 * math.pi * (coordinate - 1) / count)
			)
			buffer.writef32(if test.Axis == "X" then faces.U else faces.V, index * 4, test.Speed)
		end
		faces:Seal()
		local original = buffer.fromstring(buffer.tostring(faces[test.Component]))
		Momentum.new(momentumGeometry, { Viscosity = 0 }):Predict(state, profile, faces, 0.25)
		for index = 0, momentumGrid.Count - 1 do
			local _, y = momentumGrid:Coordinates(index + 1)
			if test.Component ~= "W" or (y >= 3 and y <= momentumGrid.SizeY - 1) then
				local field = if test.Axis == "X"
					then (if test.Speed >= 0 then momentumGeometry.Xm else momentumGeometry.Xp)
					else (if test.Speed >= 0 then momentumGeometry.Zm else momentumGeometry.Zp)
				local donor = buffer.readu32(field, index * 4)
				local value = buffer.readf32(original, index * 4)
				local donorValue = buffer.readf32(original, donor * 4)
				local spacing = if test.Axis == "X" then momentumGrid.Dx else momentumGrid.Dz
				local expected = (
					value + math.abs(test.Speed) * 0.25 / spacing * (donorValue - value)
				) * math.exp(-0.25 / 30)
				near(
					buffer.readf32(faces[test.Component], index * 4),
					expected,
					1e-7,
					"Momentum transverse advection selects the correct axis and signed donor"
				)
			end
		end
	end
	local viscosityState = State.new(momentumGrid)
	local viscosityProfile = Sounding.Initialize(viscosityState, momentumGrid.Dy)
	local viscosityFaces = Faces.new(momentumGeometry)
	for index = 1, momentumGrid.Count do
		local _, y, z = momentumGrid:Coordinates(index)
		viscosityState:Set("theta", index, buffer.readf32(viscosityProfile.Theta, (y - 1) * 4))
		viscosityState:Set("qv", index, buffer.readf32(viscosityProfile.Qv, (y - 1) * 4))
		buffer.writef32(
			viscosityFaces.U,
			(index - 1) * 4,
			math.sin(2 * math.pi * (z - 1) / momentumGrid.SizeZ)
		)
	end
	viscosityFaces:Seal()
	local initialMode = buffer.fromstring(buffer.tostring(viscosityFaces.U))
	Momentum.new(momentumGeometry, { Viscosity = 10 })
		:Predict(viscosityState, viscosityProfile, viscosityFaces, 0.25)
	local discreteDecay = (
		1
		+ 10 * 0.25 * (2 * math.cos(2 * math.pi / momentumGrid.SizeZ) - 2) / momentumGrid.Dz ^ 2
	) * math.exp(-0.25 / 30)
	for index = 0, momentumGrid.Count - 1 do
		near(
			buffer.readf32(viscosityFaces.U, index * 4),
			buffer.readf32(initialMode, index * 4) * discreteDecay,
			1e-7,
			"Momentum viscosity follows the discrete sinusoidal diffusion eigenmode"
		)
	end
	print(
		"PASS: 60-step two-axis near-CFL smooth/sharp bounds, scalar species conservation, signed transverse momentum and viscosity mode"
	)
end
