--!native
--!strict

local Geometry = require(script.Parent.Parent.Core.Geometry)

local Projection = {}
Projection.__index = Projection

export type FaceFields = { U: buffer, V: buffer, W: buffer }
export type Options = {
	MaxIterations: number?,
	AbsoluteTolerance: number?, -- divergence, s^-1
	RelativeTolerance: number?,
}
export type Diagnostics = {
	Iterations: number,
	Residual: number, -- equation RMS expressed as divergence, s^-1
	ResidualMax: number,
	BeforeRms: number,
	BeforeMax: number,
	AfterRms: number,
	AfterMax: number,
	TargetTolerance: number,
	QuantizationFloor: number, -- IEEE float32 face-rounding bound, s^-1
	F64RoundingFloor: number, -- scale-dependent operator/staging arithmetic bound, s^-1
	PostTolerance: number,
	CompatibilityMean: number,
	Converged: boolean,
}
export type Projection = typeof(setmetatable(
	{} :: {
		Geometry: Geometry.Geometry,
		Correction: buffer, -- float64 kinematic pressure, m^2/s^2; never hydrostatic Pa
		Rhs: buffer,
		ResidualBuffer: buffer,
		Search: buffer,
		Operator: buffer,
		Preconditioned: buffer,
		InverseDiagonal: buffer,
		Pending: FaceFields,
		Last: Diagnostics,
		MaxIterations: number,
		AbsoluteTolerance: number,
		RelativeTolerance: number,
		Ax: number,
		Ay: number,
		Az: number,
		InverseDx: number,
		InverseDy: number,
		InverseDz: number,
		Float32SubnormalFloor: number,
	},
	Projection
))

local DOUBLE_EPSILON = 2.220446049250313e-16
local FLOAT_EPSILON = 1.1920928955078125e-7
local FLOAT_HALF_SUBNORMAL = 2 ^ -150
local DOUBLE_MIN_NORMAL = 2.2250738585072014e-308
-- gamma_n = n*epsilon/(1-n*epsilon). Using machine epsilon instead of unit
-- roundoff gives margin for the <=32 operations in each operator/face term.
local F64_GAMMA = 32 * DOUBLE_EPSILON / (1 - 32 * DOUBLE_EPSILON)

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function removeMean(field: buffer, count: number): number
	local sum, compensation = 0, 0
	for offset = 0, count * 8 - 8, 8 do
		local corrected = buffer.readf64(field, offset) - compensation
		local nextSum = sum + corrected
		compensation = (nextSum - sum) - corrected
		sum = nextSum
	end
	local mean = sum / count
	assert(finite(mean), "Projection null-space mean overflowed")
	for offset = 0, count * 8 - 8, 8 do
		buffer.writef64(field, offset, buffer.readf64(field, offset) - mean)
	end
	return mean
end

-- Structured seven-point A=-DG. Periodic X/Z and clamped Y pressure neighbors
-- match Geometry exactly, including singleton axes. No neighbor-map reads are
-- needed in this dominant loop. Optional p'Ap accumulation saves another scan.
local function applyOperator(
	self: Projection,
	source: buffer,
	destination: buffer,
	accumulateDot: boolean
): number
	local grid = self.Geometry.Grid
	local nx, ny, nz = grid.SizeX, grid.SizeY, grid.SizeZ
	local rowBytes, planeBytes = nx * 8, self.Geometry.Plane * 8
	local ax, ay, az = self.Ax, self.Ay, self.Az
	local product = 0
	for y = 0, ny - 1 do
		local yp = if y < ny - 1 then planeBytes else 0
		local ym = if y > 0 then -planeBytes else 0
		local plane = y * planeBytes
		for z = 0, nz - 1 do
			local base = plane + z * rowBytes
			local zp = if z < nz - 1 then rowBytes else -(nz - 1) * rowBytes
			local zm = if z > 0 then -rowBytes else (nz - 1) * rowBytes
			for x = 0, nx - 1 do
				local offset = base + x * 8
				local xp = if x < nx - 1 then offset + 8 else base
				local xm = if x > 0 then offset - 8 else base + rowBytes - 8
				local value = buffer.readf64(source, offset)
				local result = ax
						* ((value - buffer.readf64(source, xp)) + (value - buffer.readf64(
							source,
							xm
						)))
					+ ay * ((value - buffer.readf64(source, offset + yp)) + (value - buffer.readf64(
						source,
						offset + ym
					)))
					+ az
						* ((value - buffer.readf64(source, offset + zp)) + (value - buffer.readf64(
							source,
							offset + zm
						)))
				assert(finite(result), "Projection operator produced a nonfinite value")
				buffer.writef64(destination, offset, result)
				if accumulateDot then
					product += value * result
				end
			end
		end
	end
	assert(finite(product), "Projection operator dot product overflowed")
	return product
end

local function precondition(self: Projection): number
	local residual, diagonal, destination =
		self.ResidualBuffer, self.InverseDiagonal, self.Preconditioned
	local product = 0
	for offset = 0, self.Geometry.Count * 8 - 8, 8 do
		local value = buffer.readf64(residual, offset)
		local z = value * buffer.readf64(diagonal, offset)
		buffer.writef64(destination, offset, z)
		product += value * z
	end
	-- A annihilates constants and compatible residuals are zero-mean. Keeping
	-- M^-1*r's constant component gives the same quotient-space PCG iteration;
	-- phi's gauge is enforced before the actual-residual acceptance check.
	assert(finite(product) and product > 0, "Projection preconditioner broke down")
	return product
end

local function residualNorm(self: Projection, dt: number): (number, number)
	local sumSquares, maximum = 0, 0
	for offset = 0, self.Geometry.Count * 8 - 8, 8 do
		local value = buffer.readf64(self.ResidualBuffer, offset)
		assert(finite(value), "Projection residual became nonfinite")
		sumSquares += value * value
		maximum = math.max(maximum, math.abs(value))
	end
	local rms = dt * math.sqrt(sumSquares / self.Geometry.Count)
	maximum *= dt
	assert(finite(rms) and finite(maximum), "Projection residual norm overflowed")
	return rms, maximum
end

local function trueResidual(self: Projection)
	applyOperator(self, self.Correction, self.Operator, false)
	local rhs, operator, residual = self.Rhs, self.Operator, self.ResidualBuffer
	for offset = 0, self.Geometry.Count * 8 - 8, 8 do
		buffer.writef64(
			residual,
			offset,
			buffer.readf64(rhs, offset) - buffer.readf64(operator, offset)
		)
	end
	removeMean(residual, self.Geometry.Count)
end

local function checkFaces(self: Projection, faces: FaceFields)
	local geometry = self.Geometry
	assert(buffer.len(faces.U) == geometry.Count * 4, "Projection U buffer length mismatch")
	assert(buffer.len(faces.V) == geometry.Count * 4, "Projection V buffer length mismatch")
	assert(
		buffer.len(faces.W) == (geometry.Count + geometry.Plane) * 4,
		"Projection W buffer length mismatch"
	)
	assert(
		faces.U ~= faces.V and faces.U ~= faces.W and faces.V ~= faces.W,
		"Projection face buffers must not alias"
	)
	for offset = 0, geometry.Plane * 4 - 4, 4 do
		assert(
			buffer.readf32(faces.W, offset) == 0
				and buffer.readf32(faces.W, geometry.Count * 4 + offset) == 0,
			"Projection requires exactly zero normal velocity at sealed Y walls"
		)
	end
end

-- VelocityScale bounds adjacent face magnitudes divided by spacing. It is used
-- for an IEEE rounding envelope, not to loosen the float64 equation solve.
local function measure(
	self: Projection,
	faces: FaceFields,
	writeRhs: boolean
): (number, number, number, number, number)
	checkFaces(self, faces)
	local geometry = self.Geometry
	local uField, vField, wField, xpField, zpField =
		faces.U, faces.V, faces.W, geometry.Xp, geometry.Zp
	local ix, iy, iz, planeBytes =
		self.InverseDx, self.InverseDy, self.InverseDz, geometry.Plane * 4
	local sum, compensation, sumSquares, sumTerms, maximum, velocityScale = 0, 0, 0, 0, 0, 0
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local u, v, w =
			buffer.readf32(uField, offset),
			buffer.readf32(vField, offset),
			buffer.readf32(wField, offset)
		local up = buffer.readf32(uField, buffer.readu32(xpField, offset) * 4)
		local vp = buffer.readf32(vField, buffer.readu32(zpField, offset) * 4)
		local wp = buffer.readf32(wField, offset + planeBytes)
		assert(
			finite(u) and finite(v) and finite(w) and finite(up) and finite(vp) and finite(wp),
			"Nonfinite projection face velocity"
		)
		local du, dv, dw = (up - u) * ix, (vp - v) * iz, (wp - w) * iy
		local divergence = du + dv + dw
		assert(finite(divergence), "Projection divergence overflowed")
		if writeRhs then
			buffer.writef64(self.Rhs, index * 8, divergence)
		end
		local corrected = divergence - compensation
		local nextSum = sum + corrected
		compensation = (nextSum - sum) - corrected
		sum = nextSum
		sumSquares += divergence * divergence
		sumTerms += math.abs(du) + math.abs(dv) + math.abs(dw)
		maximum = math.max(maximum, math.abs(divergence))
		velocityScale = math.max(
			velocityScale,
			(math.abs(u) + math.abs(up)) * ix
				+ (math.abs(v) + math.abs(vp)) * iz
				+ (math.abs(w) + math.abs(wp)) * iy
		)
	end
	local rms, mean, meanTerms =
		math.sqrt(sumSquares / geometry.Count), sum / geometry.Count, sumTerms / geometry.Count
	assert(
		finite(rms) and finite(mean) and finite(meanTerms) and finite(velocityScale),
		"Projection divergence statistics overflowed"
	)
	return rms, maximum, mean, meanTerms, velocityScale
end

function Projection.new(geometry: Geometry.Geometry, options: Options?): Projection
	local configured = options or {}
	local maxIterations = configured.MaxIterations or 200
	local absoluteTolerance = if configured.AbsoluteTolerance ~= nil
		then configured.AbsoluteTolerance
		else 1e-9
	local relativeTolerance = if configured.RelativeTolerance ~= nil
		then configured.RelativeTolerance
		else 1e-7
	assert(
		finite(maxIterations) and maxIterations >= 1 and maxIterations % 1 == 0,
		"Projection MaxIterations must be a positive integer"
	)
	assert(
		finite(absoluteTolerance) and absoluteTolerance >= 0,
		"Projection absolute tolerance must be finite and nonnegative"
	)
	assert(
		finite(relativeTolerance) and relativeTolerance >= 0,
		"Projection relative tolerance must be finite and nonnegative"
	)
	assert(
		absoluteTolerance > 0 or relativeTolerance > 0,
		"Projection requires a positive convergence tolerance"
	)
	local ix, iy, iz = 1 / geometry.Dx, 1 / geometry.Dy, 1 / geometry.Dz
	local ax, ay, az = ix * ix, iy * iy, iz * iz
	assert(
		finite(ax)
			and finite(ay)
			and finite(az)
			and ax >= DOUBLE_MIN_NORMAL
			and ay >= DOUBLE_MIN_NORMAL
			and az >= DOUBLE_MIN_NORMAL,
		"Projection requires finite normal float64 Laplacian coefficients"
	)
	local bytes = geometry.Count * 8
	local self = setmetatable({
		Geometry = geometry,
		Correction = buffer.create(bytes),
		Rhs = buffer.create(bytes),
		ResidualBuffer = buffer.create(bytes),
		Search = buffer.create(bytes),
		Operator = buffer.create(bytes),
		Preconditioned = buffer.create(bytes),
		InverseDiagonal = buffer.create(bytes),
		Pending = {
			U = buffer.create(geometry.Count * 4),
			V = buffer.create(geometry.Count * 4),
			W = buffer.create((geometry.Count + geometry.Plane) * 4),
		},
		Last = {
			Iterations = 0,
			Residual = 0,
			ResidualMax = 0,
			BeforeRms = 0,
			BeforeMax = 0,
			AfterRms = 0,
			AfterMax = 0,
			TargetTolerance = 0,
			QuantizationFloor = 0,
			F64RoundingFloor = 0,
			PostTolerance = 0,
			CompatibilityMean = 0,
			Converged = false,
		},
		MaxIterations = maxIterations,
		AbsoluteTolerance = absoluteTolerance,
		RelativeTolerance = relativeTolerance,
		Ax = ax,
		Ay = ay,
		Az = az,
		InverseDx = ix,
		InverseDy = iy,
		InverseDz = iz,
		Float32SubnormalFloor = FLOAT_HALF_SUBNORMAL * 2 * (ix + iy + iz),
	}, Projection)
	for index = 0, geometry.Count - 1 do
		local offset, diagonal = index * 4, 0
		if buffer.readu32(geometry.Xp, offset) ~= index then
			diagonal += ax
		end
		if buffer.readu32(geometry.Xm, offset) ~= index then
			diagonal += ax
		end
		if buffer.readu32(geometry.Yp, offset) ~= index then
			diagonal += ay
		end
		if buffer.readu32(geometry.Ym, offset) ~= index then
			diagonal += ay
		end
		if buffer.readu32(geometry.Zp, offset) ~= index then
			diagonal += az
		end
		if buffer.readu32(geometry.Zm, offset) ~= index then
			diagonal += az
		end
		local inverse = if diagonal > 0 then 1 / diagonal else 0
		assert(finite(diagonal) and finite(inverse), "Projection Jacobi diagonal overflowed")
		buffer.writef64(self.InverseDiagonal, index * 8, inverse)
	end
	return self
end

function Projection:Divergence(faces: FaceFields): (number, number)
	local rms, maximum = measure(self, faces, false)
	return rms, maximum
end

-- u_new=u_star-dt*G(phi), A(phi)=-D(u_star)/dt. All accepted residuals are
-- checked against the actual float64 equation after enforcing phi's zero mean.
-- Faces are committed only after the staged float32 postcondition succeeds.
function Projection:Project(faces: FaceFields, dt: number): Diagnostics
	local last = self.Last
	last.Converged = false -- describes this attempt, including early input failures
	assert(finite(dt) and dt > 0, "Projection dt must be finite and positive")
	assert(
		faces.U ~= self.Pending.U
			and faces.U ~= self.Pending.V
			and faces.V ~= self.Pending.U
			and faces.V ~= self.Pending.V
			and faces.W ~= self.Pending.W,
		"Projection input must not alias owned staging buffers"
	)
	local beforeRms, beforeMax, mean, meanTerms, beforeScale = measure(self, faces, true)
	last.Iterations, last.Residual, last.ResidualMax = 0, beforeRms, beforeMax
	last.BeforeRms, last.BeforeMax, last.AfterRms, last.AfterMax =
		beforeRms, beforeMax, beforeRms, beforeMax
	last.CompatibilityMean = mean
	local target = math.max(self.AbsoluteTolerance, self.RelativeTolerance * beforeRms)
	assert(finite(target), "Projection convergence tolerance overflowed")
	last.TargetTolerance, last.QuantizationFloor, last.F64RoundingFloor, last.PostTolerance =
		target, 0, 0, target
	assert(
		math.abs(mean) <= 64 * DOUBLE_EPSILON * meanTerms,
		"Projection RHS is incompatible with sealed/periodic boundaries"
	)
	if beforeRms <= target and beforeMax <= target then
		buffer.fill(self.Correction, 0, 0)
		last.Converged = true
		return last -- includes exact zero flow with a relative-only target of zero
	end
	assert(target > 0, "Projection convergence tolerance underflowed")
	local count = self.Geometry.Count
	for offset = 0, count * 8 - 8, 8 do
		local divergence = buffer.readf64(self.Rhs, offset) - mean
		local rhs = -divergence / dt
		assert(
			finite(rhs) and (divergence == 0 or rhs ~= 0),
			"Projection RHS overflowed or underflowed"
		)
		buffer.writef64(self.Rhs, offset, rhs)
	end
	removeMean(self.Rhs, count)
	removeMean(self.Correction, count)
	trueResidual(self)
	local rms, maximum = residualNorm(self, dt)
	if rms > beforeRms then
		buffer.fill(self.Correction, 0, 0) -- keep a warm start only when it improves RMS
		buffer.copy(self.ResidualBuffer, 0, self.Rhs)
		rms, maximum = residualNorm(self, dt)
	end
	local converged = rms <= target and maximum <= target
	if not converged then
		local rho = precondition(self)
		buffer.copy(self.Search, 0, self.Preconditioned)
		local phi, residual, search, operator, zField, diagonal =
			self.Correction,
			self.ResidualBuffer,
			self.Search,
			self.Operator,
			self.Preconditioned,
			self.InverseDiagonal
		for iteration = 1, self.MaxIterations do
			local denominator = applyOperator(self, search, operator, true)
			assert(denominator > 0, "Projection conjugate-gradient operator broke down")
			local alpha = rho / denominator
			assert(finite(alpha) and alpha > 0, "Projection conjugate-gradient step broke down")
			local sumSquares, residualMax, nextRho = 0, 0, 0
			-- Fuse correction, residual, norm and Jacobi products into one scan.
			for offset = 0, count * 8 - 8, 8 do
				buffer.writef64(
					phi,
					offset,
					buffer.readf64(phi, offset) + alpha * buffer.readf64(search, offset)
				)
				local value = buffer.readf64(residual, offset)
					- alpha * buffer.readf64(operator, offset)
				assert(finite(value), "Projection residual became nonfinite")
				local z = value * buffer.readf64(diagonal, offset)
				buffer.writef64(residual, offset, value)
				buffer.writef64(zField, offset, z)
				sumSquares += value * value
				residualMax = math.max(residualMax, math.abs(value))
				nextRho += value * z
			end
			last.Iterations = iteration
			rms, maximum = dt * math.sqrt(sumSquares / count), dt * residualMax
			assert(finite(rms) and finite(maximum), "Projection residual norm overflowed")
			local restart = false
			if rms <= target and maximum <= target then
				removeMean(phi, count)
				trueResidual(self)
				rms, maximum = residualNorm(self, dt)
				if rms <= target and maximum <= target then
					converged = true
					break
				end
				restart = true
				nextRho = precondition(self)
			end
			if iteration == self.MaxIterations then
				break
			end
			assert(
				finite(nextRho) and nextRho > 0,
				"Projection conjugate-gradient residual broke down"
			)
			local beta = if restart then 0 else nextRho / rho
			assert(finite(beta) and beta >= 0, "Projection conjugate-gradient search broke down")
			for offset = 0, count * 8 - 8, 8 do
				buffer.writef64(
					search,
					offset,
					buffer.readf64(zField, offset) + beta * buffer.readf64(search, offset)
				)
			end
			rho = nextRho
		end
	end
	last.Residual, last.ResidualMax = rms, maximum
	if not converged then
		error(
			string.format(
				"Projection did not converge in %d iterations: RMS %.6g, max %.6g, target %.6g s^-1",
				last.Iterations,
				rms,
				maximum,
				target
			)
		)
	end
	-- The gauge was already enforced before the verified true residual. Repeating
	-- that subtraction here would alter the equation we just checked by roundoff.
	local geometry = self.Geometry
	local pending, correction = self.Pending, self.Correction
	local xmField, zmField, ymField = geometry.Xm, geometry.Zm, geometry.Ym
	local maxPhi, stageU, stageV, stageW = 0, 0, 0, 0
	for index = 0, count - 1 do
		local offset = index * 4
		local phi = buffer.readf64(correction, index * 8)
		maxPhi = math.max(maxPhi, math.abs(phi))
		local deltaU = dt
			* (phi - buffer.readf64(correction, buffer.readu32(xmField, offset) * 8))
			* self.InverseDx
		local deltaV = dt
			* (phi - buffer.readf64(correction, buffer.readu32(zmField, offset) * 8))
			* self.InverseDz
		local u, v = buffer.readf32(faces.U, offset), buffer.readf32(faces.V, offset)
		buffer.writef32(pending.U, offset, u - deltaU)
		buffer.writef32(pending.V, offset, v - deltaV)
		stageU, stageV =
			math.max(stageU, math.abs(u) + math.abs(deltaU)),
			math.max(stageV, math.abs(v) + math.abs(deltaV))
		if index >= geometry.Plane then
			local deltaW = dt
				* (phi - buffer.readf64(correction, buffer.readu32(ymField, offset) * 8))
				* self.InverseDy
			local w = buffer.readf32(faces.W, offset)
			buffer.writef32(pending.W, offset, w - deltaW)
			stageW = math.max(stageW, math.abs(w) + math.abs(deltaW))
		end
	end
	buffer.fill(pending.W, 0, 0, geometry.Plane * 4)
	buffer.fill(pending.W, count * 4, 0, geometry.Plane * 4)
	local afterRms, afterMax, _, _, afterScale = measure(self, pending, false)
	-- Relative IEEE32 rounding bound converted from exact to stored magnitudes,
	-- plus half an absolute subnormal ulp for each of the six adjacent faces.
	local quantization = 0.500001 * FLOAT_EPSILON * afterScale + self.Float32SubnormalFloor
	local stageScale = 2
		* (stageU * self.InverseDx + stageV * self.InverseDz + stageW * self.InverseDy)
	-- Four*max|phi|*(ax+ay+az) bounds the absolute six-term Laplacian sum.
	-- The scale terms also cover staging and before/after divergence arithmetic.
	local f64Rounding = F64_GAMMA
		* (beforeScale + afterScale + stageScale + dt * 4 * maxPhi * (self.Ax + self.Ay + self.Az))
	local postTolerance = target + quantization + f64Rounding + math.abs(mean)
	assert(finite(postTolerance), "Projection postcondition rounding bound overflowed")
	last.AfterRms, last.AfterMax = afterRms, afterMax
	last.QuantizationFloor, last.F64RoundingFloor, last.PostTolerance =
		quantization, f64Rounding, postTolerance
	if afterRms > postTolerance or afterMax > postTolerance then
		error(
			string.format(
				"Projection float32 postcondition failed: RMS %.6g, max %.6g, tolerance %.6g s^-1",
				afterRms,
				afterMax,
				postTolerance
			)
		)
	end
	buffer.copy(faces.U, 0, pending.U)
	buffer.copy(faces.V, 0, pending.V)
	buffer.copy(faces.W, 0, pending.W)
	last.Converged = true
	return last
end

return Projection
