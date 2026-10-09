--!strict

-- These checks run the production operators with independently constructed
-- periodic fields, known one-step displacements and physical invariants.
local Vector3 = require("@lune/roblox").Vector3

return function(
	root: any,
	loadModule: any,
	check: any,
	near: any,
	rejects: any,
	operatorsOnly: boolean?,
	quick: boolean?
)
	local Grid3D = loadModule(root.Core.Grid3D)
	local State = loadModule(root.Core.AtmosphereState)
	local Geometry = loadModule(root.Core.Geometry)
	local FaceVelocity = loadModule(root.Core.FaceVelocity)
	local Transport = loadModule(root.Dynamics.Transport)
	local Projection = loadModule(root.Dynamics.Projection)
	local Momentum = loadModule(root.Dynamics.Momentum)
	local Sounding = loadModule(root.Thermodynamics.Sounding)
	local Atmosphere = loadModule(root)

	local grid =
		Grid3D.new(8, 6, 7, 64, Vector3.new(-256, 128, -224), { Dx = 40, Dy = 80, Dz = 100 })
	local geometry = Geometry.new(grid)
	check(
		geometry.Count == grid.Count and geometry.Plane == grid.SizeX * grid.SizeZ,
		"Geometry has correct cell/plane counts"
	)
	near(geometry.Dx, 40, 0, "Geometry preserves physical x spacing")
	near(geometry.Dy, 80, 0, "Geometry preserves physical y spacing")
	near(geometry.Dz, 100, 0, "Geometry preserves physical z spacing")
	local physicalX, physicalY, physicalZ = grid:GridToPhysical(2, 3, 4)
	near(physicalX, 60, 0, "Physical cell center uses meters in x")
	near(physicalY, 200, 0, "Physical cell center uses meters in y")
	near(physicalZ, 350, 0, "Physical cell center uses meters in z")
	local world = grid:GridToWorld(2, 3, 4)
	near(world.X, -160, 0, "World coordinates preserve Roblox display spacing")
	near(world.Y, 288, 0, "World and physical y spacing remain independent")
	for _, spacing in
		{
			{ Dx = 0, Dy = 100, Dz = 100 },
			{ Dx = 100, Dy = 0 / 0, Dz = 100 },
			{ Dx = 100, Dy = 100, Dz = math.huge },
		}
	do
		rejects(function()
			Grid3D.new(3, 3, 3, 64, Vector3.zero, spacing)
		end, "Nonpositive/nonfinite physical spacing must fail")
	end
	for index = 0, grid.Count - 1 do
		local x, y, z = grid:Coordinates(index + 1)
		local function neighbor(field: any): number
			return buffer.readu32(field, index * 4)
		end
		local xp = grid:Index(x % grid.SizeX + 1, y, z) - 1
		local xm = grid:Index((x - 2) % grid.SizeX + 1, y, z) - 1
		local zp = grid:Index(x, y, z % grid.SizeZ + 1) - 1
		local zm = grid:Index(x, y, (z - 2) % grid.SizeZ + 1) - 1
		check(
			neighbor(geometry.Xp) == xp and neighbor(geometry.Xm) == xm,
			"X geometry wraps periodically"
		)
		check(
			neighbor(geometry.Zp) == zp and neighbor(geometry.Zm) == zm,
			"Z geometry wraps periodically"
		)
		check(
			neighbor(geometry.Yp) == grid:Index(x, math.min(y + 1, grid.SizeY), z) - 1,
			"Upper y neighbor seals wall"
		)
		check(
			neighbor(geometry.Ym) == grid:Index(x, math.max(y - 1, 1), z) - 1,
			"Lower y neighbor seals wall"
		)
	end

	local function makeState(): any
		local state = State.new(grid)
		state:Fill("theta", 300)
		state:Fill("qv", 0.01)
		state:Fill("qc", 0)
		state:Fill("qr", 0)
		return state
	end
	local function uniformFaces(u: number, v: number): any
		local faces = FaceVelocity.new(geometry)
		for offset = 0, geometry.Count * 4 - 4, 4 do
			buffer.writef32(faces.U, offset, u)
			buffer.writef32(faces.V, offset, v)
		end
		faces:Seal()
		return faces
	end
	local function totals(state: any): { [string]: number }
		local sums = { theta = 0, qv = 0, qc = 0, qr = 0 }
		for field in sums do
			for index = 1, grid.Count do
				sums[field] += state:Get(field, index)
			end
		end
		return sums
	end
	for _, wind in { { 0, 0 }, { 10, 5 }, { -10, -5 } } do
		local state = makeState()
		state:Fill("qc", 0.001)
		state:Fill("qr", 0.002)
		local before = totals(state)
		local faces = uniformFaces(wind[1], wind[2])
		local transport = Transport.new(geometry)
		for _ = 1, 20 do
			transport:Advance(state, faces, 0.25)
		end
		for field, total in before do
			near(
				totals(state)[field],
				total,
				1e-8 * math.max(1, total),
				"Uniform periodic scalar is preserved under transport"
			)
			local expected = if field == "theta"
				then 300
				elseif field == "qv" then state:Get("qv", 1)
				elseif field == "qc" then state:Get("qc", 1)
				else state:Get("qr", 1)
			for index = 1, grid.Count do
				near(
					state:Get(field, index),
					expected,
					1e-7,
					"Uniform scalar has no directional bias"
				)
			end
		end
	end

	-- An isolated scalar pulse must move left through the periodic x boundary
	-- and backward through z with the analytically known outgoing fractions.
	local pulse = makeState()
	pulse:Fill("qv", 0)
	pulse:SetCell("qc", 1, 3, 1, 0.01)
	pulse:SetCell("qv", 1, 3, 1, 0.02)
	pulse:SetCell("qr", 1, 3, 1, 0.003)
	local pulseBefore = totals(pulse)
	local negativeFaces = uniformFaces(-10, -5)
	local negativeTransport = Transport.new(geometry, { Scheme = "Upwind" })
	negativeTransport:Advance(pulse, negativeFaces, 1)
	for _, field in { "qv", "qc", "qr" } do
		local amount = pulseBefore[field]
		near(
			pulse:GetCell(field, 1, 3, 1),
			amount * 0.7,
			1e-9,
			"Pulse retains correct two-axis upwind fraction"
		)
		near(
			pulse:GetCell(field, grid.SizeX, 3, 1),
			amount * 0.25,
			1e-9,
			"Negative x wind wraps pulse through boundary"
		)
		near(
			pulse:GetCell(field, 1, 3, grid.SizeZ),
			amount * 0.05,
			1e-9,
			"Negative z wind wraps pulse through boundary"
		)
		near(
			totals(pulse)[field],
			amount,
			2e-9,
			"Shared periodic face flux conserves each water species"
		)
	end
	local positivePulse = makeState()
	positivePulse:SetCell("qc", grid.SizeX, 3, grid.SizeZ, 0.01)
	Transport.new(geometry, { Scheme = "Upwind" }):Advance(positivePulse, uniformFaces(10, 5), 1)
	near(
		positivePulse:GetCell("qc", grid.SizeX, 3, grid.SizeZ),
		0.007,
		1e-9,
		"Positive pulse retains correct outgoing fraction"
	)
	near(
		positivePulse:GetCell("qc", 1, 3, grid.SizeZ),
		0.0025,
		1e-9,
		"Positive x wind wraps to first x cell"
	)
	near(
		positivePulse:GetCell("qc", grid.SizeX, 3, 1),
		0.0005,
		1e-9,
		"Positive z wind wraps to first z cell"
	)
	near(totals(positivePulse).qc, 0.01, 2e-9, "Positive periodic shared flux conserves water")

	-- A single interior vertical face transfers water between exactly two cells;
	-- this isolated flux test intentionally does not require incompressible flow.
	local vertical = makeState()
	vertical:SetCell("qc", 4, 2, 4, 0.01)
	local verticalFaces = uniformFaces(0, 0)
	local lowerIndex = grid:Index(4, 3, 4) - 1
	buffer.writef32(verticalFaces.W, lowerIndex * 4, 16)
	Transport.new(geometry, { Scheme = "Upwind" }):Advance(vertical, verticalFaces, 1)
	near(
		vertical:GetCell("qc", 4, 2, 4),
		0.008,
		1e-9,
		"Interior upward flux depletes donor by Courant fraction"
	)
	near(
		vertical:GetCell("qc", 4, 3, 4),
		0.002,
		1e-9,
		"Interior upward flux reaches the adjacent layer"
	)
	near(totals(vertical).qc, 0.01, 2e-9, "Interior y face transfers conserve water")
	local downward = makeState()
	downward:SetCell("qc", 4, 3, 4, 0.006)
	local downwardFaces = uniformFaces(0, 0)
	buffer.writef32(downwardFaces.W, lowerIndex * 4, -16)
	Transport.new(geometry, { Scheme = "Upwind" }):Advance(downward, downwardFaces, 1)
	near(downward:GetCell("qc", 4, 3, 4), 0.0048, 1e-9, "Downward flux depletes upper donor")
	near(downward:GetCell("qc", 4, 2, 4), 0.0012, 1e-9, "Downward flux reaches the lower layer")
	near(totals(downward).qc, 0.006, 2e-9, "Interior downward flux conserves water")
	local varied = makeState()
	for index = 1, grid.Count do
		varied:Set("theta", index, 280 + (index * 17 % 29))
		varied:Set("qv", index, 0.003 + (index * 11 % 23) * 0.0003)
		varied:Set("qc", index, (index * 7 % 19) * 0.0001)
		varied:Set("qr", index, (index * 5 % 13) * 0.00002)
	end
	local variedBefore = totals(varied)
	local variedFaces = uniformFaces(24, 14)
	buffer.writef32(variedFaces.W, lowerIndex * 4, 10)
	local variedCourant =
		Transport.new(geometry, { Scheme = "Upwind" })
			:Advance(varied, variedFaces, 0.79 / (24 / grid.Dx + 14 / grid.Dz + 10 / grid.Dy))
	near(variedCourant, 0.79, 1e-12, "Multidimensional outgoing CFL is tested near its limit")
	for field, before in variedBefore do
		near(
			totals(varied)[field],
			before,
			1e-7 * math.max(1, before),
			"Arbitrary multicell field conserves shared flux near CFL limit"
		)
		for index = 1, grid.Count do
			check(
				varied:Get(field, index) >= 0,
				"Near-limit multidimensional flux remains nonnegative"
			)
		end
	end
	local function smoothAdvectionError(sizeX: number, scheme: string): number
		local domainLength = 1000
		local dx = domainLength / sizeX
		local convergenceGrid =
			Grid3D.new(sizeX, 3, 1, 64, Vector3.zero, { Dx = dx, Dy = 100, Dz = 100 })
		local convergenceGeometry = Geometry.new(convergenceGrid)
		local convergenceState = State.new(convergenceGrid)
		local convergenceFaces = FaceVelocity.new(convergenceGeometry)
		local initialMinimum, initialMaximum = math.huge, -math.huge
		for index = 1, convergenceGrid.Count do
			local x = convergenceGrid:Coordinates(index)
			local initial = 0.01 + 0.005 * math.sin(2 * math.pi * (x - 0.5) * dx / domainLength)
			convergenceState:Set("qv", index, initial)
			initialMinimum = math.min(initialMinimum, convergenceState:Get("qv", index))
			initialMaximum = math.max(initialMaximum, convergenceState:Get("qv", index))
			buffer.writef32(convergenceFaces.U, (index - 1) * 4, 4)
		end
		convergenceFaces:Seal()
		local transport = Transport.new(convergenceGeometry, { Scheme = scheme })
		local dt = 0.2 * dx / 4
		local steps = math.floor(50 / dt + 0.5)
		near(steps * dt, 50, 1e-12, "Convergence grids advance the same physical duration")
		for _ = 1, steps do
			transport:Advance(convergenceState, convergenceFaces, dt)
		end
		local squaredError = 0
		for index = 1, convergenceGrid.Count do
			local x = convergenceGrid:Coordinates(index)
			local exact = 0.01
				+ 0.005 * math.sin(2 * math.pi * ((x - 0.5) * dx - 4 * 50) / domainLength)
			local actual = convergenceState:Get("qv", index)
			check(
				actual >= initialMinimum - 1e-8 and actual <= initialMaximum + 1e-8,
				"Smooth periodic scalar remains within initial extrema"
			)
			squaredError += (actual - exact) ^ 2
		end
		return math.sqrt(squaredError / convergenceGrid.Count)
	end
	local fctErrors, upwindErrors = {}, {}
	for _, sizeX in { 16, 32, 64 } do
		local fct = smoothAdvectionError(sizeX, "FCT")
		local upwind = smoothAdvectionError(sizeX, "Upwind")
		table.insert(fctErrors, fct)
		table.insert(upwindErrors, upwind)
		check(
			fct < upwind * 0.5,
			"Bounded high-order transport is more accurate than donor-cell transport"
		)
	end
	for level = 2, 3 do
		check(
			fctErrors[level] < fctErrors[level - 1] * 0.45,
			"FCT converges faster than first order under grid refinement"
		)
		check(
			upwindErrors[level] < upwindErrors[level - 1] * 0.7,
			"Reference donor-cell transport converges under grid refinement"
		)
	end
	print(
		string.format(
			"PASS: smooth periodic transport NX16/32/64 FCT RMS=(%.9g,%.9g,%.9g), Upwind=(%.9g,%.9g,%.9g) kg/kg; FCT ratios %.4f/%.4f (U4m/s,50s,CFL.2)",
			fctErrors[1],
			fctErrors[2],
			fctErrors[3],
			upwindErrors[1],
			upwindErrors[2],
			upwindErrors[3],
			fctErrors[2] / fctErrors[1],
			fctErrors[3] / fctErrors[2]
		)
	)
	check(
		buffer.len(verticalFaces.W) == (geometry.Count + geometry.Plane) * 4,
		"W contains both sealed boundary planes"
	)
	for index = 0, geometry.Plane - 1 do
		near(buffer.readf32(verticalFaces.W, index * 4), 0, 0, "Bottom faces are sealed")
		near(
			buffer.readf32(verticalFaces.W, (geometry.Count + index) * 4),
			0,
			0,
			"Top faces are sealed"
		)
	end
	local unsafe = makeState()
	local snapshots: { [string]: string } = {}
	for _, field in { "theta", "qv", "qc", "qr" } do
		snapshots[field] = buffer.tostring(unsafe.Fields[field])
	end
	rejects(function()
		Transport.new(geometry):Advance(unsafe, uniformFaces(1000, 1000), 1)
	end, "Excessive summed advective Courant number must fail")
	for field, snapshot in snapshots do
		check(
			buffer.tostring(unsafe.Fields[field]) == snapshot,
			"Failed CFL check does not partially commit scalar state"
		)
	end

	-- A manufactured gradient flow plus uniform horizontal wind has an exact
	-- divergence-free component: the constant wind. Multiple potential modes
	-- prevent a one-iteration solve from accidentally satisfying the test.
	local function potential(x: number, y: number, z: number): number
		return 700
				* math.sin(2 * math.pi * (x - 0.5) / grid.SizeX)
				* math.cos(2 * math.pi * (z - 0.5) / grid.SizeZ)
				* math.cos(math.pi * (y - 0.5) / grid.SizeY)
			+ 300
				* math.cos(4 * math.pi * (x - 0.5) / grid.SizeX)
				* math.sin(2 * math.pi * (z - 0.5) / grid.SizeZ)
	end
	local function manufacturedFaces(): any
		local faces = uniformFaces(0, 0)
		for index = 1, grid.Count do
			local x, y, z = grid:Coordinates(index)
			local offset = (index - 1) * 4
			buffer.writef32(
				faces.U,
				offset,
				3 + (potential(x, y, z) - potential((x - 2) % grid.SizeX + 1, y, z)) / grid.Dx
			)
			buffer.writef32(
				faces.V,
				offset,
				-2 + (potential(x, y, z) - potential(x, y, (z - 2) % grid.SizeZ + 1)) / grid.Dz
			)
			if y > 1 then
				buffer.writef32(
					faces.W,
					offset,
					(potential(x, y, z) - potential(x, y - 1, z)) / grid.Dy
				)
			end
		end
		faces:Seal()
		return faces
	end
	local projectedFaces = manufacturedFaces()
	local projection = Projection.new(geometry)
	local beforeRms = projection:Divergence(projectedFaces)
	projection:Project(projectedFaces, 0.25)
	local afterRms, afterMax = projection:Divergence(projectedFaces)
	check(
		afterRms < beforeRms * 1e-5,
		"Projection reduces manufactured divergence by at least five orders"
	)
	check(afterMax < 1e-7, "Projected manufactured flow has small absolute divergence")
	local meanCorrection = 0
	for index = 0, grid.Count - 1 do
		meanCorrection += buffer.readf64(projection.Correction, index * 8)
		near(
			buffer.readf32(projectedFaces.U, index * 4),
			3,
			1e-5,
			"Projection retains uniform x wind"
		)
		near(
			buffer.readf32(projectedFaces.V, index * 4),
			-2,
			1e-5,
			"Projection retains uniform z wind"
		)
		near(
			buffer.readf32(projectedFaces.W, index * 4),
			0,
			1e-5,
			"Projection removes vertical gradient component"
		)
	end
	near(meanCorrection / grid.Count, 0, 1e-8, "Kinematic pressure correction has zero-mean gauge")
	local coarse = Projection.new(geometry, { AbsoluteTolerance = 1e-6, RelativeTolerance = 1e-3 })
	local coarseFaces = manufacturedFaces()
	coarse:Project(coarseFaces, 0.25)
	local coarseRms = coarse:Divergence(coarseFaces)
	check(
		afterRms < coarseRms * 0.1,
		"Tighter pressure solve tolerance reduces residual divergence"
	)
	local failedFaces = manufacturedFaces()
	local originalFaces: { [string]: any } = {}
	for _, field in { "U", "V", "W" } do
		originalFaces[field] =
			{ Buffer = failedFaces[field], Bytes = buffer.tostring(failedFaces[field]) }
	end
	rejects(function()
		Projection.new(geometry, { MaxIterations = 1 }):Project(failedFaces, 0.25)
	end, "Nonconverged pressure solve must fail explicitly")
	for field, snapshot in originalFaces do
		check(
			failedFaces[field] == snapshot.Buffer
				and buffer.tostring(failedFaces[field]) == snapshot.Bytes,
			"Failed pressure solve preserves all live face buffers"
		)
	end
	for _, options in
		{ { MaxIterations = 0 }, { AbsoluteTolerance = -1 }, { RelativeTolerance = 0 / 0 } }
	do
		rejects(function()
			Projection.new(geometry, options)
		end, "Invalid pressure solve configuration must fail")
	end
	local invalidFaces = manufacturedFaces()
	buffer.writef32(invalidFaces.U, 0, 0 / 0)
	rejects(function()
		Projection.new(geometry):Project(invalidFaces, 0.25)
	end, "NaN face velocity must stop projection")
	local neutralState = makeState()
	local neutralProfile = Sounding.Initialize(neutralState, grid.Dy)
	for index = 1, grid.Count do
		local _, y = grid:Coordinates(index)
		neutralState:Set("theta", index, buffer.readf32(neutralProfile.Theta, (y - 1) * 4))
		neutralState:Set("qv", index, buffer.readf32(neutralProfile.Qv, (y - 1) * 4))
	end
	local buoyantFaces = FaceVelocity.new(geometry)
	buoyantFaces:Initialize(neutralState)
	local momentum = Momentum.new(geometry)
	momentum:Predict(neutralState, neutralProfile, buoyantFaces, 0.25)
	for offset = 0, buffer.len(buoyantFaces.W) - 4, 4 do
		near(
			buffer.readf32(buoyantFaces.W, offset),
			0,
			0,
			"Environmental air has no spurious buoyancy velocity"
		)
	end
	neutralState:SetCell("theta", 4, 3, 4, neutralState:GetCell("theta", 4, 3, 4) + 1)
	momentum:Predict(neutralState, neutralProfile, buoyantFaces, 0.25)
	check(
		buffer.readf32(buoyantFaces.W, (grid:Index(4, 3, 4) - 1) * 4) > 0,
		"Thermal perturbation accelerates vertical face velocity"
	)
	Projection.new(geometry):Project(buoyantFaces, 0.25)
	buoyantFaces:WriteCellCenters(neutralState)
	check(
		neutralState:GetCell("w", 4, 3, 4) > 0,
		"Pressure correction retains a local thermal updraft"
	)
	for _, options in { { Viscosity = -1 }, { DragTimescale = 0 }, { DragTimescale = 0 / 0 } } do
		rejects(function()
			Momentum.new(geometry, options)
		end, "Invalid momentum configuration must fail")
	end
	local backgroundState = makeState()
	local backgroundProfile =
		Sounding.Initialize(backgroundState, grid.Dy, { BackgroundU = 8, BackgroundV = 4 })
	for index = 1, grid.Count do
		local _, y = grid:Coordinates(index)
		backgroundState:Set("theta", index, buffer.readf32(backgroundProfile.Theta, (y - 1) * 4))
		backgroundState:Set("qv", index, buffer.readf32(backgroundProfile.Qv, (y - 1) * 4))
	end
	local backgroundFaces = FaceVelocity.new(geometry)
	backgroundFaces:Initialize(backgroundState)
	Momentum.new(geometry):Predict(backgroundState, backgroundProfile, backgroundFaces, 0.25)
	for index = 0, grid.Count - 1 do
		near(
			buffer.readf32(backgroundFaces.U, index * 4),
			8,
			0,
			"Uniform background x momentum remains steady"
		)
		near(
			buffer.readf32(backgroundFaces.V, index * 4),
			4,
			0,
			"Uniform background z momentum remains steady"
		)
	end
	for offset = 0, buffer.len(backgroundFaces.W) - 4, 4 do
		near(
			buffer.readf32(backgroundFaces.W, offset),
			0,
			0,
			"Neutral background wind creates no vertical momentum"
		)
	end
	buffer.writef32(backgroundFaces.U, 0, 10000)
	local momentumSnapshots: { [string]: any } = {}
	for _, field in { "U", "V", "W" } do
		momentumSnapshots[field] =
			{ Buffer = backgroundFaces[field], Bytes = buffer.tostring(backgroundFaces[field]) }
	end
	rejects(function()
		Momentum.new(geometry):Predict(backgroundState, backgroundProfile, backgroundFaces, 0.25)
	end, "Excessive momentum Courant number must fail")
	for field, snapshot in momentumSnapshots do
		check(
			backgroundFaces[field] == snapshot.Buffer
				and buffer.tostring(backgroundFaces[field]) == snapshot.Bytes,
			"Failed momentum prediction preserves all live face buffers"
		)
	end
	backgroundFaces:Initialize(backgroundState)
	for y = 0, grid.SizeY - 1 do
		buffer.writef32(backgroundProfile.V, y * 4, 0)
	end
	for index = 0, grid.Count - 1 do
		buffer.writef32(
			backgroundFaces.V,
			index * 4,
			math.sin((index % grid.SizeX) * 2 * math.pi / grid.SizeX)
		)
	end
	local transverseBefore = buffer.fromstring(buffer.tostring(backgroundFaces.V))
	Momentum.new(geometry, { Viscosity = 0 })
		:Predict(backgroundState, backgroundProfile, backgroundFaces, 0.25)
	local dragDecay = math.exp(-0.25 / 30)
	for index = 0, grid.Count - 1 do
		local xm = buffer.readu32(geometry.Xm, index * 4)
		local original = buffer.readf32(transverseBefore, index * 4)
		local donor = buffer.readf32(transverseBefore, xm * 4)
		local expected = (original - 0.25 * 8 / grid.Dx * (original - donor)) * dragDecay
		near(
			buffer.readf32(backgroundFaces.V, index * 4),
			expected,
			1e-7,
			"Transverse momentum uses the correct periodic upwind donor and exact drag"
		)
	end
	backgroundState:Fill("qr", 0.001)
	for y = 0, grid.SizeY - 1 do
		buffer.writef32(backgroundProfile.U, y * 4, 0)
	end
	local loadedFaces = uniformFaces(0, 0)
	Momentum.new(geometry):Predict(backgroundState, backgroundProfile, loadedFaces, 0.25)
	check(
		buffer.readf32(loadedFaces.W, geometry.Plane * 4) < 0,
		"Rain water contributes liquid loading to the vertical momentum source"
	)
	for _, wallOffset in { 0, geometry.Count * 4 } do
		local unsealed = uniformFaces(0, 0)
		buffer.writef32(unsealed.W, wallOffset, 1)
		rejects(function()
			Transport.new(geometry):Advance(makeState(), unsealed, 0.25)
		end, "Scalar transport rejects a nonzero wall face")
		rejects(function()
			Momentum.new(geometry):Predict(neutralState, neutralProfile, unsealed, 0.25)
		end, "Momentum rejects a nonzero wall face")
		rejects(function()
			Projection.new(geometry):Project(unsealed, 0.25)
		end, "Pressure projection rejects a nonzero wall face")
	end
	print(
		string.format(
			"PASS: 3D geometry, constant/pulse flux conservation, periodic wrap, sealed walls, CFL failure and manufactured projection; div RMS %.3g -> %.3g, max %.3g",
			beforeRms,
			afterRms,
			afterMax
		)
	)
	local reworkNumerics = require("./rework-numerics")
	reworkNumerics(root, loadModule, check, near, rejects)
	if operatorsOnly then
		return
	end
	for _, configuration in
		{
			{ BackgroundU = 0 / 0 },
			{ ShearV = math.huge },
			{ ProjectionOptions = { MaxIterations = 0 } },
			{ MomentumOptions = { Viscosity = -1 } },
		}
	do
		rejects(function()
			Atmosphere.new(grid, configuration)
		end, "Invalid atmosphere configuration must fail")
	end
	local deterministicA =
		Atmosphere.new(grid, { BackgroundU = -4, BackgroundV = 3, ShearU = 0.001 })
	local deterministicB =
		Atmosphere.new(grid, { BackgroundU = -4, BackgroundV = 3, ShearU = 0.001 })
	for _ = 1, 16 do
		deterministicA:Step(0.25)
		deterministicB:Step(0.25)
	end
	for _, field in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
		check(
			buffer.tostring(deterministicA.State.Fields[field])
				== buffer.tostring(deterministicB.State.Fields[field]),
			"Identical fixed-step simulations have deterministic field snapshots"
		)
	end
	for _, field in { "U", "V", "W" } do
		check(
			buffer.tostring(deterministicA.Faces[field])
				== buffer.tostring(deterministicB.Faces[field]),
			"Identical fixed-step simulations have deterministic face snapshots"
		)
	end
	local testTransaction = require("./transactional-simulation")
	testTransaction(root, loadModule, check, near, rejects)
	if quick then
		return
	end

	-- Measured reference from the unchanged Phase 1 production run (240s):
	-- qv+qc drift -0.19963%; this is comparison data, not a physics implementation.
	local referenceDrift = -0.19963
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
	local summaries = {}
	local function runScenario(
		label: string,
		configuration: any,
		expectCloud: boolean,
		preview: boolean?
	): any
		local simulationGrid = if preview
			then Grid3D.new(24, 12, 24, 12, Vector3.new(-144, 24, -144))
			else Grid3D.new(24, 12, 24, 64, Vector3.new(-768, 128, -768))
		local simulation = Atmosphere.new(simulationGrid, configuration)
		local initial = simulation:GetDiagnostics()
		local initialWater = initial.WaterSum
		near(initial.MaxCloudWater, 0, 0, "Scenario starts with no painted cloud water")
		local bufferCount, bufferBytes = ownedBuffers(simulation)
		local pressureSnapshot = buffer.tostring(simulation.State.Fields.pressure)
		local peakCloud, peakU, peakV, peakW = 0, 0, 0, 0
		local firstCloud: number? = nil
		local firstCloudWater: number? = nil
		local exactFirstVisible: number? = nil
		local firstCentroid: any = nil
		local finalCentroid: any = nil
		local maximumDivergence, maximumIterations, maximumCourant = 0, 0, 0
		local totalMilliseconds, maximumMilliseconds = 0, 0
		local snapshots = {}
		local startTime = os.clock()
		for step = 1, 960 do
			simulation:Step(0.25)
			if preview and (firstCloudWater == nil or exactFirstVisible == nil) then
				local maximumCloud = 0
				for offset = 0, simulationGrid.Count * 4 - 4, 4 do
					maximumCloud =
						math.max(maximumCloud, buffer.readf32(simulation.State.Fields.qc, offset))
				end
				if maximumCloud > 0 then
					firstCloudWater = firstCloudWater or simulation.Time
				end
				if maximumCloud >= 0.00005 then
					exactFirstVisible = simulation.Time
				end
			end
			totalMilliseconds += simulation.StepMilliseconds
			maximumMilliseconds = math.max(maximumMilliseconds, simulation.StepMilliseconds)
			maximumIterations = math.max(maximumIterations, simulation.Projection.Last.Iterations)
			maximumCourant =
				math.max(maximumCourant, simulation.MomentumCourant, simulation.TransportCourant)
			if step % 40 == 0 then
				local diagnostics = simulation:GetDiagnostics()
				for index = 1, simulationGrid.Count do
					for _, field in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
						local value = simulation.State:Get(field, index)
						check(
							value == value and math.abs(value) < math.huge,
							"3D scenario fields stay finite"
						)
						if field == "qv" or field == "qc" or field == "qr" then
							check(value >= 0, "3D scenario water stays nonnegative")
						end
					end
				end
				peakCloud = math.max(peakCloud, diagnostics.MaxCloudWater)
				peakU = math.max(peakU, math.abs(diagnostics.MinU), math.abs(diagnostics.MaxU))
				peakV = math.max(peakV, math.abs(diagnostics.MinV), math.abs(diagnostics.MaxV))
				peakW = math.max(peakW, math.abs(diagnostics.MinW), math.abs(diagnostics.MaxW))
				if diagnostics.MaxCloudWater >= 0.00005 then
					firstCloud = firstCloud or simulation.Time
					if diagnostics.CloudCentroidDefined then
						local centroid = {
							X = diagnostics.CloudCentroidX,
							Y = diagnostics.CloudCentroidY,
							Z = diagnostics.CloudCentroidZ,
							Time = simulation.Time,
						}
						firstCentroid = firstCentroid or centroid
						finalCentroid = centroid
					end
				end
				local divergenceRms, divergenceMax =
					simulation.Projection:Divergence(simulation.Faces)
				maximumDivergence = math.max(maximumDivergence, divergenceMax)
				check(
					divergenceRms <= simulation.Projection.Last.PostTolerance
						and divergenceMax <= simulation.Projection.Last.PostTolerance,
					"Projected scenario satisfies reported float32 divergence tolerance"
				)
				if step % 240 == 0 then
					local snapshot = table.clone(diagnostics)
					snapshot.ProjectionPostTolerance = simulation.Projection.Last.PostTolerance
					table.insert(snapshots, snapshot)
					print(
						string.format(
							"%s t=%.0fs qc=%.6g cloudcells=%d waterdrift=%+.8f%% div_rms/max=%.3g/%.3g PCG=%d residual=%.3g centroid=(%.1f,%.1f,%.1f)m",
							label,
							simulation.Time,
							diagnostics.MaxCloudWater,
							diagnostics.CloudCells,
							diagnostics.WaterDriftFraction * 100,
							divergenceRms,
							divergenceMax,
							diagnostics.ProjectionIterations,
							diagnostics.ProjectionResidual,
							diagnostics.CloudCentroidX,
							diagnostics.CloudCentroidY,
							diagnostics.CloudCentroidZ
						)
					)
				end
			end
		end
		local final = simulation:GetDiagnostics()
		local drift = (final.WaterSum / initialWater - 1) * 100
		local finalBufferCount, finalBufferBytes = ownedBuffers(simulation)
		near(finalBufferCount, bufferCount, 0, "Simulation reuses a fixed owned buffer count")
		near(finalBufferBytes, bufferBytes, 0, "Simulation owned buffer storage stays fixed")
		near(simulation.Time, 240, 1e-10, "3D scenario advances fixed physical time")
		check(
			buffer.tostring(simulation.State.Fields.pressure) == pressureSnapshot,
			"Projection leaves absolute thermodynamic pressure unchanged"
		)
		check(
			math.abs(drift) < 0.0001,
			"3D shared flux transport conserves total water to float32 precision over 240s"
		)
		check(
			math.abs(drift) < math.abs(referenceDrift) * 0.01,
			"3D total water drift improves measured Phase 1 baseline"
		)
		check(peakW > 0 and peakW < 100, "3D buoyancy develops finite vertical motion")
		local centroidDisplacement: any = nil
		if firstCentroid and finalCentroid then
			local lengthX = simulationGrid.SizeX * simulationGrid.Dx
			local lengthZ = simulationGrid.SizeZ * simulationGrid.Dz
			centroidDisplacement = {
				X = (finalCentroid.X - firstCentroid.X + lengthX * 0.5) % lengthX - lengthX * 0.5,
				Y = finalCentroid.Y - firstCentroid.Y,
				Z = (finalCentroid.Z - firstCentroid.Z + lengthZ * 0.5) % lengthZ - lengthZ * 0.5,
				Seconds = finalCentroid.Time - firstCentroid.Time,
			}
		end
		local summary = {
			Scenario = label,
			Configuration = configuration or {},
			ScalarScheme = simulation.Transport.Scheme,
			DisplayCellSizeStuds = simulationGrid.CellSize,
			DisplayBottomStuds = simulationGrid.Origin.Y,
			PhysicalSpacingMeters = {
				Dx = simulationGrid.Dx,
				Dy = simulationGrid.Dy,
				Dz = simulationGrid.Dz,
			},
			Initial = initial,
			Final = final,
			Snapshots = snapshots,
			FirstVisibleCloudSeconds = firstCloud,
			FirstCloudWaterSecondsExact = firstCloudWater,
			FirstVisibleCloudSecondsExact = exactFirstVisible,
			PeakCloud = peakCloud,
			SampledPeakFaceU = peakU,
			SampledPeakFaceV = peakV,
			SampledPeakFaceW = peakW,
			SampledMaximumDivergence = maximumDivergence,
			MaximumIterations = maximumIterations,
			MaximumCourant = maximumCourant,
			MeanStepMilliseconds = totalMilliseconds / 960,
			MaximumStepMilliseconds = maximumMilliseconds,
			RuntimeSeconds = os.clock() - startTime,
			OwnedBufferCount = bufferCount,
			OwnedBufferBytes = bufferBytes,
			CentroidDisplacement = centroidDisplacement,
		}
		table.insert(summaries, summary)
		print(
			string.format(
				"PASS: %s 960steps/240s qc_peak=%.6g sampled face|u,v,w|=(%.3g,%.3g,%.3g)m/s first5e-5=%.1fs waterdrift=%+.8f%% div_max=%.3g PCGmax=%d Courantmax=%.4g step_mean/max=%.3f/%.3fms buffers=%d/%dbytes runtime=%.2fs",
				label,
				peakCloud,
				peakU,
				peakV,
				peakW,
				firstCloud or -1,
				drift,
				maximumDivergence,
				maximumIterations,
				maximumCourant,
				summary.MeanStepMilliseconds,
				maximumMilliseconds,
				bufferCount,
				bufferBytes,
				summary.RuntimeSeconds
			)
		)
		if expectCloud then
			check(
				peakCloud >= 0.00005,
				"Expected cloud scenario creates visible cloud water dynamically"
			)
			if configuration then
				check(
					centroidDisplacement ~= nil
						and centroidDisplacement.Seconds >= 20
						and centroidDisplacement.X > 5
						and centroidDisplacement.Z > 5,
					"Visible cloud centroid advances with configured positive horizontal wind"
				)
				print(
					string.format(
						"PASS: cloud centroid translated (%.2f,%.2f,%.2f)m over %.0fs",
						centroidDisplacement.X,
						centroidDisplacement.Y,
						centroidDisplacement.Z,
						centroidDisplacement.Seconds
					)
				)
			end
		end
		if preview then
			check(
				exactFirstVisible ~= nil and exactFirstVisible < 60,
				"Studio preview generates visible cloud within one simulated minute"
			)
			print(
				string.format(
					"PASS: preview exact first qc>0 at %.2fs and qc>=5e-5 at %.2fs; display %.0fstud cells, bottom %.0fstuds",
					firstCloudWater or -1,
					exactFirstVisible or -1,
					simulationGrid.CellSize,
					simulationGrid.Origin.Y
				)
			)
		end
		return simulation
	end
	local defaultSimulation = runScenario("default", nil, true)
	local advectingSimulation =
		runScenario("weak wind", { BackgroundU = 0.5, BackgroundV = 0.25 }, true)
	check(
		advectingSimulation.State:Get("u", 1) ~= defaultSimulation.State:Get("u", 1),
		"Configured wind affects authoritative velocity state"
	)
	runScenario(
		"wind8/4 stress",
		{ BackgroundU = 8, BackgroundV = 4, ShearU = 0.002, ShearV = -0.001 },
		false
	)
	runScenario(
		"Studio preview",
		{ BackgroundU = 2, BackgroundV = 1, BubbleRelativeHumidity = 0.999 },
		true,
		true
	)
	return summaries
end
