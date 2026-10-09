--!strict

local AtmosphereState = require(script.Parent.Parent.Core.AtmosphereState)
local Geometry = require(script.Parent.Parent.Core.Geometry)
local FaceVelocity = require(script.Parent.Parent.Core.FaceVelocity)
local Sounding = require(script.Parent.Parent.Thermodynamics.Sounding)
local Buoyancy = require(script.Parent.Buoyancy)
local Validation = require(script.Parent.Parent.Utilities.Validation)

local Momentum = {}
Momentum.__index = Momentum

local MAX_COURANT = 0.8
local MAX_FLOAT32 = 3.4028234663852886e38

export type Options = {
	Viscosity: number?, -- m^2/s; zero disables explicit diffusion.
	DragTimescale: number?, -- seconds, relaxation toward the sounding wind and w=0.
}

export type Momentum = typeof(setmetatable(
	{} :: {
		Geometry: Geometry.Geometry,
		ScratchU: buffer,
		ScratchV: buffer,
		ScratchW: buffer,
		Buoyancy: buffer,
		Viscosity: number,
		DragTimescale: number,
		InvDx: number,
		InvDy: number,
		InvDz: number,
		DiffusionRate: number,
	},
	Momentum
))

function Momentum.new(geometry: Geometry.Geometry, options: Options?): Momentum
	local settings = options or {}
	local viscosity = settings.Viscosity or 10
	local dragTimescale = settings.DragTimescale or 30
	assert(
		Validation.IsFinite(viscosity) and viscosity >= 0,
		"Viscosity must be finite and nonnegative (m^2/s)"
	)
	assert(
		Validation.IsFinite(dragTimescale) and dragTimescale > 0,
		"Drag timescale must be finite and positive (s)"
	)
	local invDx = 1 / geometry.Dx
	local invDy = 1 / geometry.Dy
	local invDz = 1 / geometry.Dz
	local diffusionRate = 2 * viscosity * (invDx * invDx + invDy * invDy + invDz * invDz)
	assert(Validation.IsFinite(diffusionRate), "Momentum diffusion coefficients overflowed")
	return setmetatable({
		Geometry = geometry,
		ScratchU = buffer.create(geometry.Count * 4),
		ScratchV = buffer.create(geometry.Count * 4),
		ScratchW = buffer.create((geometry.Count + geometry.Plane) * 4),
		Buoyancy = buffer.create(geometry.Count * 4),
		Viscosity = viscosity,
		DragTimescale = dragTimescale,
		InvDx = invDx,
		InvDy = invDy,
		InvDz = invDz,
		DiffusionRate = diffusionRate,
	}, Momentum)
end

local function checkedWrite(field: buffer, offset: number, value: number, component: string)
	if not Validation.IsFinite(value) or math.abs(value) > MAX_FLOAT32 then
		error(
			string.format(
				"Nonfinite/overflowed momentum %s at face %d: %s",
				component,
				offset / 4 + 1,
				tostring(value)
			)
		)
	end
	buffer.writef32(field, offset, value)
end

-- Explicit first-order material advection plus seven-point viscosity. Neighbors
-- are face indices here; U/V use clamped Y ghosts, W uses real sealed-wall faces.
local function predictComponent(
	self: Momentum,
	field: buffer,
	index: number,
	xp: number,
	xm: number,
	yp: number,
	ym: number,
	zp: number,
	zm: number,
	advectX: number,
	advectY: number,
	advectZ: number,
	dt: number
): (number, number)
	local courant = dt
		* (
			math.abs(advectX) * self.InvDx
			+ math.abs(advectY) * self.InvDy
			+ math.abs(advectZ) * self.InvDz
			+ self.DiffusionRate
		)
	if not Validation.IsFinite(courant) or courant > MAX_COURANT then
		error(
			string.format(
				"Momentum CFL/diffusion limit exceeded at face %d: %.6g (limit %.2f)",
				index + 1,
				courant,
				MAX_COURANT
			)
		)
	end

	local value = buffer.readf32(field, index * 4)
	local plusX = buffer.readf32(field, xp * 4)
	local minusX = buffer.readf32(field, xm * 4)
	local plusY = buffer.readf32(field, yp * 4)
	local minusY = buffer.readf32(field, ym * 4)
	local plusZ = buffer.readf32(field, zp * 4)
	local minusZ = buffer.readf32(field, zm * 4)
	local derivativeX = if advectX >= 0 then value - minusX else plusX - value
	local derivativeY = if advectY >= 0 then value - minusY else plusY - value
	local derivativeZ = if advectZ >= 0 then value - minusZ else plusZ - value
	local advection = advectX * derivativeX * self.InvDx
		+ advectY * derivativeY * self.InvDy
		+ advectZ * derivativeZ * self.InvDz
	local laplacian = (plusX - 2 * value + minusX) * self.InvDx * self.InvDx
		+ (plusY - 2 * value + minusY) * self.InvDy * self.InvDy
		+ (plusZ - 2 * value + minusZ) * self.InvDz * self.InvDz
	return value + dt * (self.Viscosity * laplacian - advection), courant
end

-- MAC predictor only; pressure projection follows elsewhere. All components read
-- the previous face buffers, then swap together. Cell-center winds are diagnostics.
-- Exact local drag follows explicit advection/diffusion; W includes buoyancy during
-- drag integration. No velocity clipping conceals a violated stability bound.
function Momentum:Predict(
	state: AtmosphereState.AtmosphereState,
	profile: Sounding.Profile,
	faces: FaceVelocity.FaceVelocity,
	dt: number
): number
	assert(Validation.IsFinite(dt) and dt > 0, "Momentum timestep must be finite and positive (s)")
	local geometry = self.Geometry
	assert(
		state.Grid == geometry.Grid and faces.Geometry == geometry,
		"Momentum geometry must match state and faces"
	)
	assert(profile.CellHeightMeters == geometry.Dy, "Sounding height must match physical Y spacing")
	local count = geometry.Count
	-- Each normal face velocity participates in its component CFL check below;
	-- invalid velocities fail there before any live-face commit, without an extra scan.
	assert(buffer.len(faces.U) == count * 4, "Momentum U buffer length mismatch")
	assert(buffer.len(faces.V) == count * 4, "Momentum V buffer length mismatch")
	assert(buffer.len(faces.W) == (count + geometry.Plane) * 4, "Momentum W buffer length mismatch")
	local plane = geometry.Plane
	local rowBytes = plane * 4
	for offset = 0, rowBytes - 4, 4 do
		assert(
			buffer.readf32(faces.W, offset) == 0
				and buffer.readf32(faces.W, count * 4 + offset) == 0,
			"Momentum requires sealed vertical wall faces"
		)
	end

	local fields = state.Fields
	for y = 0, geometry.Grid.SizeY - 1 do
		local rowOffset = y * 4
		local environmentTheta = buffer.readf32(profile.Theta, rowOffset)
		local environmentQv = buffer.readf32(profile.Qv, rowOffset)
		assert(
			Validation.IsFinite(buffer.readf32(profile.U, rowOffset))
				and Validation.IsFinite(buffer.readf32(profile.V, rowOffset)),
			"Sounding wind must be finite"
		)
		for offset = y * rowBytes, (y + 1) * rowBytes - 4, 4 do
			local qc = buffer.readf32(fields.qc, offset)
			local qr = buffer.readf32(fields.qr, offset)
			assert(
				Validation.IsFinite(qc) and qc >= 0 and Validation.IsFinite(qr) and qr >= 0,
				"Liquid water must be finite and nonnegative"
			)
			local acceleration = Buoyancy.Calculate(
				buffer.readf32(fields.theta, offset),
				buffer.readf32(fields.qv, offset),
				qc + qr,
				environmentTheta,
				environmentQv
			)
			checkedWrite(self.Buoyancy, offset, acceleration, "buoyancy")
		end
	end

	local oldU = faces.U
	local oldV = faces.V
	local oldW = faces.W
	local decay = math.exp(-dt / self.DragTimescale)
	local ratio = dt / self.DragTimescale
	local responseTime = self.DragTimescale * (1 - decay)
	if ratio < 1e-5 then
		responseTime = dt * (1 - ratio * 0.5 + ratio * ratio / 6)
	end
	local maximumCourant = 0
	buffer.fill(self.ScratchW, 0, 0, rowBytes)
	buffer.fill(self.ScratchW, count * 4, 0, rowBytes)

	for y = 0, geometry.Grid.SizeY - 1 do
		local targetU = buffer.readf32(profile.U, y * 4)
		local targetV = buffer.readf32(profile.V, y * 4)
		for index = y * plane, (y + 1) * plane - 1 do
			local offset = index * 4
			local xp = buffer.readu32(geometry.Xp, offset)
			local xm = buffer.readu32(geometry.Xm, offset)
			local yp = buffer.readu32(geometry.Yp, offset)
			local ym = buffer.readu32(geometry.Ym, offset)
			local zp = buffer.readu32(geometry.Zp, offset)
			local zm = buffer.readu32(geometry.Zm, offset)
			local zpXm = buffer.readu32(geometry.Zp, xm * 4)
			local xpZm = buffer.readu32(geometry.Xp, zm * 4)

			local advectXU = buffer.readf32(oldU, offset)
			local advectZU = 0.25
				* (
					buffer.readf32(oldV, offset)
					+ buffer.readf32(oldV, zp * 4)
					+ buffer.readf32(oldV, xm * 4)
					+ buffer.readf32(oldV, zpXm * 4)
				)
			local advectYU = 0.25
				* (
					buffer.readf32(oldW, offset)
					+ buffer.readf32(oldW, (index + plane) * 4)
					+ buffer.readf32(oldW, xm * 4)
					+ buffer.readf32(oldW, (xm + plane) * 4)
				)
			local predictedU, courantU = predictComponent(
				self,
				oldU,
				index,
				xp,
				xm,
				yp,
				ym,
				zp,
				zm,
				advectXU,
				advectYU,
				advectZU,
				dt
			)
			checkedWrite(self.ScratchU, offset, targetU + (predictedU - targetU) * decay, "U")

			local advectXV = 0.25
				* (
					buffer.readf32(oldU, offset)
					+ buffer.readf32(oldU, xp * 4)
					+ buffer.readf32(oldU, zm * 4)
					+ buffer.readf32(oldU, xpZm * 4)
				)
			local advectZV = buffer.readf32(oldV, offset)
			local advectYV = 0.25
				* (
					buffer.readf32(oldW, offset)
					+ buffer.readf32(oldW, (index + plane) * 4)
					+ buffer.readf32(oldW, zm * 4)
					+ buffer.readf32(oldW, (zm + plane) * 4)
				)
			local predictedV, courantV = predictComponent(
				self,
				oldV,
				index,
				xp,
				xm,
				yp,
				ym,
				zp,
				zm,
				advectXV,
				advectYV,
				advectZV,
				dt
			)
			checkedWrite(self.ScratchV, offset, targetV + (predictedV - targetV) * decay, "V")
			maximumCourant = math.max(maximumCourant, courantU, courantV)

			if y > 0 then
				local below = index - plane
				local xpBelow = buffer.readu32(geometry.Xp, below * 4)
				local zpBelow = buffer.readu32(geometry.Zp, below * 4)
				local advectXW = 0.25
					* (
						buffer.readf32(oldU, offset)
						+ buffer.readf32(oldU, xp * 4)
						+ buffer.readf32(oldU, below * 4)
						+ buffer.readf32(oldU, xpBelow * 4)
					)
				local advectZW = 0.25
					* (
						buffer.readf32(oldV, offset)
						+ buffer.readf32(oldV, zp * 4)
						+ buffer.readf32(oldV, below * 4)
						+ buffer.readf32(oldV, zpBelow * 4)
					)
				local advectYW = buffer.readf32(oldW, offset)
				local predictedW, courantW = predictComponent(
					self,
					oldW,
					index,
					xp,
					xm,
					index + plane,
					below,
					zp,
					zm,
					advectXW,
					advectYW,
					advectZW,
					dt
				)
				local acceleration = 0.5
					* (
						buffer.readf32(self.Buoyancy, below * 4)
						+ buffer.readf32(self.Buoyancy, offset)
					)
				checkedWrite(
					self.ScratchW,
					offset,
					predictedW * decay + acceleration * responseTime,
					"W"
				)
				maximumCourant = math.max(maximumCourant, courantW)
			end
		end
	end

	local previousU = faces.U
	local previousV = faces.V
	local previousW = faces.W
	faces.U = self.ScratchU
	faces.V = self.ScratchV
	faces.W = self.ScratchW
	self.ScratchU = previousU
	self.ScratchV = previousV
	self.ScratchW = previousW
	return maximumCourant
end

return Momentum
