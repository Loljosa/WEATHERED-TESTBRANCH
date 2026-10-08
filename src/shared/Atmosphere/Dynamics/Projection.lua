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
	Residual: number, -- RMS equation residual expressed as divergence, s^-1
	BeforeRms: number,
	BeforeMax: number,
	AfterRms: number,
	AfterMax: number,
	TargetTolerance: number,
	QuantizationFloor: number,
	PostTolerance: number,
	CompatibilityMean: number,
	Converged: boolean,
}
export type Projection = typeof(setmetatable(
	{} :: {
		Geometry: Geometry.Geometry,
		Correction: buffer, -- float64 kinematic pressure correction, m^2/s^2; NOT Pa
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
	},
	Projection
))

local DOUBLE_EPSILON = 2.220446049250313e-16
local FLOAT_EPSILON = 1.1920928955078125e-7
local MINIMUM_FLOAT32_FLOOR = 5e-8 -- s^-1, reported rather than hidden in solver tolerance

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function removeMean(field: buffer, count: number): number
	-- Compensated summation keeps the null-space compatibility/gauge operation
	-- independent of the scan direction to floating-point roundoff.
	local sum = 0
	local compensation = 0
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

local function dot(a: buffer, b: buffer, count: number): number
	local sum = 0
	for offset = 0, count * 8 - 8, 8 do
		sum += buffer.readf64(a, offset) * buffer.readf64(b, offset)
	end
	assert(finite(sum), "Projection dot product overflowed")
	return sum
end

-- Positive semidefinite A = -D G. The same neighbor topology and face
-- gradients are used for correction and conservative transport divergence.
local function applyOperator(self: Projection, source: buffer, destination: buffer)
	local geometry = self.Geometry
	local ax = 1 / (geometry.Dx * geometry.Dx)
	local ay = 1 / (geometry.Dy * geometry.Dy)
	local az = 1 / (geometry.Dz * geometry.Dz)
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local value = buffer.readf64(source, index * 8)
		local result = ax
				* ((value - buffer.readf64(source, buffer.readu32(geometry.Xp, offset) * 8)) + (value - buffer.readf64(
					source,
					buffer.readu32(geometry.Xm, offset) * 8
				)))
			+ ay * ((value - buffer.readf64(source, buffer.readu32(geometry.Yp, offset) * 8)) + (value - buffer.readf64(
				source,
				buffer.readu32(geometry.Ym, offset) * 8
			)))
			+ az
				* ((value - buffer.readf64(source, buffer.readu32(geometry.Zp, offset) * 8)) + (value - buffer.readf64(
					source,
					buffer.readu32(geometry.Zm, offset) * 8
				)))
		assert(finite(result), "Projection operator produced a nonfinite value")
		buffer.writef64(destination, index * 8, result)
	end
end

local function precondition(self: Projection)
	for offset = 0, self.Geometry.Count * 8 - 8, 8 do
		buffer.writef64(
			self.Preconditioned,
			offset,
			buffer.readf64(self.ResidualBuffer, offset)
				* buffer.readf64(self.InverseDiagonal, offset)
		)
	end
	-- P M^-1 P is positive definite on the zero-mean subspace even though the
	-- Neumann-wall Jacobi diagonal differs from the interior diagonal.
	removeMean(self.Preconditioned, self.Geometry.Count)
end

local function residualNorm(self: Projection, dt: number): (number, number)
	local sumSquares = 0
	local maximum = 0
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
	applyOperator(self, self.Correction, self.Operator)
	for offset = 0, self.Geometry.Count * 8 - 8, 8 do
		buffer.writef64(
			self.ResidualBuffer,
			offset,
			buffer.readf64(self.Rhs, offset) - buffer.readf64(self.Operator, offset)
		)
	end
	removeMean(self.ResidualBuffer, self.Geometry.Count)
end

local function checkFaces(self: Projection, faces: FaceFields)
	local geometry = self.Geometry
	assert(buffer.len(faces.U) == geometry.Count * 4, "Projection U buffer length mismatch")
	assert(buffer.len(faces.V) == geometry.Count * 4, "Projection V buffer length mismatch")
	assert(
		buffer.len(faces.W) == (geometry.Count + geometry.Plane) * 4,
		"Projection W buffer length mismatch"
	)
	for offset = 0, geometry.Plane * 4 - 4, 4 do
		assert(
			buffer.readf32(faces.W, offset) == 0
				and buffer.readf32(faces.W, geometry.Count * 4 + offset) == 0,
			"Projection requires exactly zero normal velocity at sealed Y walls"
		)
	end
end

-- Optionally writes the unscaled divergence into Rhs for the subsequent solve.
local function measure(
	self: Projection,
	faces: FaceFields,
	writeRhs: boolean
): (number, number, number, number)
	checkFaces(self, faces)
	local geometry = self.Geometry
	local sum = 0
	local compensation = 0
	local sumSquares = 0
	local sumTerms = 0
	local maximum = 0
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local u = buffer.readf32(faces.U, offset)
		local v = buffer.readf32(faces.V, offset)
		local w = buffer.readf32(faces.W, offset)
		local up = buffer.readf32(faces.U, buffer.readu32(geometry.Xp, offset) * 4)
		local vp = buffer.readf32(faces.V, buffer.readu32(geometry.Zp, offset) * 4)
		local wp = buffer.readf32(faces.W, offset + geometry.Plane * 4)
		assert(
			finite(u) and finite(v) and finite(w) and finite(up) and finite(vp) and finite(wp),
			"Nonfinite projection face velocity"
		)
		local du = (up - u) / geometry.Dx
		local dv = (vp - v) / geometry.Dz
		local dw = (wp - w) / geometry.Dy
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
	end
	local rms = math.sqrt(sumSquares / geometry.Count)
	local mean = sum / geometry.Count
	local meanTerms = sumTerms / geometry.Count
	assert(
		finite(rms) and finite(mean) and finite(meanTerms),
		"Projection divergence statistics overflowed"
	)
	return rms, maximum, mean, meanTerms
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
			BeforeRms = 0,
			BeforeMax = 0,
			AfterRms = 0,
			AfterMax = 0,
			TargetTolerance = 0,
			QuantizationFloor = 0,
			PostTolerance = 0,
			CompatibilityMean = 0,
			Converged = false,
		},
		MaxIterations = maxIterations,
		AbsoluteTolerance = absoluteTolerance,
		RelativeTolerance = relativeTolerance,
	}, Projection)
	local ax = 1 / (geometry.Dx * geometry.Dx)
	local ay = 1 / (geometry.Dy * geometry.Dy)
	local az = 1 / (geometry.Dz * geometry.Dz)
	assert(
		finite(ax) and finite(ay) and finite(az) and ax > 0 and ay > 0 and az > 0,
		"Projection spacing cannot form a finite positive Laplacian"
	)
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local diagonal = 0
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
		assert(finite(diagonal), "Projection Jacobi diagonal overflowed")
		buffer.writef64(self.InverseDiagonal, index * 8, if diagonal > 0 then 1 / diagonal else 0)
	end
	return self
end

function Projection:Divergence(faces: FaceFields): (number, number)
	local rms, maximum = measure(self, faces, false)
	return rms, maximum
end

-- Boussinesq MAC projection, u_new = u_star - dt G phi, A phi = -D u_star/dt.
-- Periodic X/Z and homogeneous Neumann Y leave a constant null space. The
-- correction is kept in a zero-mean gauge and never written to hydrostatic Pa.
function Projection:Project(faces: FaceFields, dt: number): Diagnostics
	assert(finite(dt) and dt > 0, "Projection dt must be finite and positive")
	local beforeRms, beforeMax, mean, meanTerms = measure(self, faces, true)
	local last = self.Last
	last.Converged = false
	last.Iterations = 0
	last.Residual = beforeRms
	last.BeforeRms = beforeRms
	last.BeforeMax = beforeMax
	last.AfterRms = beforeRms
	last.AfterMax = beforeMax
	last.CompatibilityMean = mean
	local target = math.max(self.AbsoluteTolerance, self.RelativeTolerance * beforeRms)
	assert(
		finite(target) and target > 0,
		"Projection convergence tolerance overflowed or underflowed"
	)
	last.TargetTolerance = target
	last.QuantizationFloor = MINIMUM_FLOAT32_FLOOR
	last.PostTolerance = target + MINIMUM_FLOAT32_FLOOR
	-- With the sealed/periodic face layout the domain divergence integral is
	-- identically zero. Only arithmetic roundoff may be removed from the RHS.
	assert(
		math.abs(mean) <= 64 * DOUBLE_EPSILON * meanTerms,
		"Projection RHS is incompatible with sealed/periodic boundaries"
	)
	if beforeRms <= target and beforeMax <= target then
		buffer.fill(self.Correction, 0, 0)
		last.Converged = true
		return last
	end
	local count = self.Geometry.Count
	for offset = 0, count * 8 - 8, 8 do
		local rhs = -(buffer.readf64(self.Rhs, offset) - mean) / dt
		assert(finite(rhs), "Projection RHS overflowed")
		buffer.writef64(self.Rhs, offset, rhs)
	end
	removeMean(self.Rhs, count)
	removeMean(self.Correction, count) -- reuse the previous solve as a warm start
	trueResidual(self)
	local rms, maximum = residualNorm(self, dt)
	if rms > beforeRms then
		-- A forcing change can make yesterday's correction a poor initial guess.
		-- Retain the warm start only when it improves the initial residual norm.
		buffer.fill(self.Correction, 0, 0)
		trueResidual(self)
		rms, maximum = residualNorm(self, dt)
	end
	local converged = rms <= target and maximum <= target
	if not converged then
		precondition(self)
		buffer.copy(self.Search, 0, self.Preconditioned)
		local rho = dot(self.ResidualBuffer, self.Preconditioned, count)
		assert(rho > 0, "Projection preconditioner broke down")
		for iteration = 1, self.MaxIterations do
			applyOperator(self, self.Search, self.Operator)
			local denominator = dot(self.Search, self.Operator, count)
			assert(denominator > 0, "Projection conjugate-gradient operator broke down")
			local alpha = rho / denominator
			assert(finite(alpha) and alpha > 0, "Projection conjugate-gradient step broke down")
			for offset = 0, count * 8 - 8, 8 do
				buffer.writef64(
					self.Correction,
					offset,
					buffer.readf64(self.Correction, offset)
						+ alpha * buffer.readf64(self.Search, offset)
				)
				buffer.writef64(
					self.ResidualBuffer,
					offset,
					buffer.readf64(self.ResidualBuffer, offset)
						- alpha * buffer.readf64(self.Operator, offset)
				)
			end
			last.Iterations = iteration
			rms, maximum = residualNorm(self, dt)
			local restart = false
			if rms <= target and maximum <= target then
				removeMean(self.Correction, count)
				trueResidual(self) -- validate the actual equation, not just the recurrence
				rms, maximum = residualNorm(self, dt)
				if rms <= target and maximum <= target then
					converged = true
					break
				end
				restart = true
			end
			precondition(self)
			local nextRho = dot(self.ResidualBuffer, self.Preconditioned, count)
			assert(nextRho > 0, "Projection conjugate-gradient residual broke down")
			local beta = if restart then 0 else nextRho / rho
			assert(finite(beta) and beta >= 0, "Projection conjugate-gradient search broke down")
			for offset = 0, count * 8 - 8, 8 do
				buffer.writef64(
					self.Search,
					offset,
					buffer.readf64(self.Preconditioned, offset)
						+ beta * buffer.readf64(self.Search, offset)
				)
			end
			rho = nextRho
		end
	end
	last.Residual = rms
	if not converged then
		error(
			string.format(
				"Projection did not converge in %d iterations: residual %.6g s^-1, target %.6g s^-1",
				last.Iterations,
				rms,
				target
			)
		)
	end
	removeMean(self.Correction, count)
	local geometry = self.Geometry
	-- Stage float32 corrections. Overflow/postcondition errors preserve input faces.
	for index = 0, count - 1 do
		local offset = index * 4
		local phi = buffer.readf64(self.Correction, index * 8)
		local xm = buffer.readu32(geometry.Xm, offset)
		local zm = buffer.readu32(geometry.Zm, offset)
		buffer.writef32(
			self.Pending.U,
			offset,
			buffer.readf32(faces.U, offset)
				- dt * (phi - buffer.readf64(self.Correction, xm * 8)) / geometry.Dx
		)
		buffer.writef32(
			self.Pending.V,
			offset,
			buffer.readf32(faces.V, offset)
				- dt * (phi - buffer.readf64(self.Correction, zm * 8)) / geometry.Dz
		)
		if index >= geometry.Plane then
			local ym = buffer.readu32(geometry.Ym, offset)
			buffer.writef32(
				self.Pending.W,
				offset,
				buffer.readf32(faces.W, offset)
					- dt * (phi - buffer.readf64(self.Correction, ym * 8)) / geometry.Dy
			)
		end
	end
	buffer.fill(self.Pending.W, 0, 0, geometry.Plane * 4)
	buffer.fill(self.Pending.W, count * 4, 0, geometry.Plane * 4)
	local afterRms, afterMax = measure(self, self.Pending, false)
	local quantizationFloor = MINIMUM_FLOAT32_FLOOR
	for index = 0, count - 1 do
		local offset = index * 4
		-- Slight margin converts the relative rounding bound from exact values
		-- to the stored float32 magnitudes used here.
		local bound = 0.500001
			* FLOAT_EPSILON
			* (
				(
						math.abs(buffer.readf32(self.Pending.U, offset))
						+ math.abs(
							buffer.readf32(self.Pending.U, buffer.readu32(geometry.Xp, offset) * 4)
						)
					)
					/ geometry.Dx
				+ (math.abs(buffer.readf32(self.Pending.V, offset)) + math.abs(
					buffer.readf32(self.Pending.V, buffer.readu32(geometry.Zp, offset) * 4)
				)) / geometry.Dz
				+ (
						math.abs(buffer.readf32(self.Pending.W, offset))
						+ math.abs(buffer.readf32(self.Pending.W, offset + geometry.Plane * 4))
					)
					/ geometry.Dy
			)
		quantizationFloor = math.max(quantizationFloor, bound)
	end
	last.AfterRms = afterRms
	last.AfterMax = afterMax
	last.QuantizationFloor = quantizationFloor
	last.PostTolerance = target + quantizationFloor
	if afterRms > last.PostTolerance or afterMax > last.PostTolerance then
		error(
			string.format(
				"Projection float32 postcondition failed: RMS %.6g, max %.6g, tolerance %.6g s^-1",
				afterRms,
				afterMax,
				last.PostTolerance
			)
		)
	end
	buffer.copy(faces.U, 0, self.Pending.U)
	buffer.copy(faces.V, 0, self.Pending.V)
	buffer.copy(faces.W, 0, self.Pending.W)
	last.Converged = true
	return last
end

return Projection
