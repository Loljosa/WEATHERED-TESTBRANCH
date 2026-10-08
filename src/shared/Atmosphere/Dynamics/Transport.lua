--!strict

local AtmosphereState = require(script.Parent.Parent.Core.AtmosphereState)
local FaceVelocity = require(script.Parent.Parent.Core.FaceVelocity)
local Geometry = require(script.Parent.Parent.Core.Geometry)

local Transport = {}
Transport.__index = Transport

Transport.MaxCourant = 0.8
local MAX_FLOAT32 = 3.4028234663852886e38
local SCALAR_FIELDS: { AtmosphereState.FieldName } = { "theta", "qv", "qc", "qr" }

export type Transport = typeof(setmetatable(
	{} :: {
		Geometry: Geometry.Geometry,
		FluxU: buffer,
		FluxV: buffer,
		FluxW: buffer,
		ScalarScratch: buffer,
	},
	Transport
))

-- First-order finite-volume shared-face upwind transport on the MAC grid.
-- Scalars use cell-centered float32; fluxes use reusable float64 buffers so both
-- cells bordering a face consume the same flux. Faces carry physical m/s and
-- Dx/Dy/Dz are meters. This constant-density model conserves volume-integrated
-- scalars up to float32 commit roundoff. Bounds additionally require a nearly
-- divergence-free velocity field, supplied by the pressure projection.
function Transport.new(geometry: Geometry.Geometry): Transport
	return setmetatable({
		Geometry = geometry,
		FluxU = buffer.create(geometry.Count * 8),
		FluxV = buffer.create(geometry.Count * 8),
		FluxW = buffer.create((geometry.Count + geometry.Plane) * 8),
		ScalarScratch = buffer.create(geometry.Count * 4),
	}, Transport)
end

-- Reject invalid inputs and multidimensional OUTGOING CFL before committing
-- any scalar. Summing outgoing rates, rather than axiswise maxima, guarantees
-- a nonnegative remaining donor fraction for this unsplit upwind update.
local function preflight(
	self: Transport,
	state: AtmosphereState.AtmosphereState,
	faces: FaceVelocity.FaceVelocity,
	dt: number
): number
	local geometry = self.Geometry
	assert(state.Grid == geometry.Grid, "State grid must match transport geometry")
	assert(faces.Geometry == geometry, "Face velocities must match transport geometry")
	assert(dt >= 0 and dt < math.huge, "Transport timestep must be finite and nonnegative")
	faces:CheckFinite()
	for index = 0, geometry.Plane - 1 do
		assert(
			buffer.readf32(faces.W, index * 4) == 0
				and buffer.readf32(faces.W, (geometry.Count + index) * 4) == 0,
			"Vertical wall velocities must be sealed before transport"
		)
	end
	local maxCourant = 0
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local xp = buffer.readu32(geometry.Xp, offset) * 4
		local zp = buffer.readu32(geometry.Zp, offset) * 4
		local uLeft = buffer.readf32(faces.U, offset)
		local uRight = buffer.readf32(faces.U, xp)
		local vBack = buffer.readf32(faces.V, offset)
		local vFront = buffer.readf32(faces.V, zp)
		local wBottom = buffer.readf32(faces.W, offset)
		local wTop = buffer.readf32(faces.W, (index + geometry.Plane) * 4)
		local courant = dt
			* (
				(math.max(uRight, 0) + math.max(-uLeft, 0)) / geometry.Dx
				+ (math.max(vFront, 0) + math.max(-vBack, 0)) / geometry.Dz
				+ (math.max(wTop, 0) + math.max(-wBottom, 0)) / geometry.Dy
			)
		if courant ~= courant or courant > Transport.MaxCourant then
			error(
				string.format(
					"Transport outgoing CFL exceeded at cell %d: %.6g (limit %.2f)",
					index + 1,
					courant,
					Transport.MaxCourant
				)
			)
		end
		maxCourant = math.max(maxCourant, courant)
	end
	for _, name in SCALAR_FIELDS do
		local field = state.Fields[name]
		assert(buffer.len(field) == geometry.Count * 4, "Scalar field buffer has incorrect length")
		for index = 0, geometry.Count - 1 do
			local value = buffer.readf32(field, index * 4)
			if
				value ~= value
				or math.abs(value) == math.huge
				or value < 0
				or (name == "theta" and value == 0)
			then
				error("Invalid transport scalar " .. name .. " at cell " .. tostring(index + 1))
			end
		end
	end
	return maxCourant
end

local function buildFluxes(self: Transport, field: buffer, faces: FaceVelocity.FaceVelocity)
	local geometry = self.Geometry
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local u = buffer.readf32(faces.U, offset)
		local v = buffer.readf32(faces.V, offset)
		local w = buffer.readf32(faces.W, offset)
		local donorU = if u >= 0 then buffer.readu32(geometry.Xm, offset) else index
		local donorV = if v >= 0 then buffer.readu32(geometry.Zm, offset) else index
		local donorW = if w >= 0 then buffer.readu32(geometry.Ym, offset) else index
		buffer.writef64(self.FluxU, index * 8, u * buffer.readf32(field, donorU * 4))
		buffer.writef64(self.FluxV, index * 8, v * buffer.readf32(field, donorV * 4))
		buffer.writef64(self.FluxW, index * 8, w * buffer.readf32(field, donorW * 4))
	end
	-- The extra top wall faces have no donor cell above the domain and zero flux.
	buffer.fill(self.FluxW, geometry.Count * 8, 0, geometry.Plane * 8)
end

function Transport:Advance(
	state: AtmosphereState.AtmosphereState,
	faces: FaceVelocity.FaceVelocity,
	dt: number
): number
	local maxCourant = preflight(self, state, faces, dt)
	if dt == 0 then
		return maxCourant
	end
	local geometry = self.Geometry
	for _, name in SCALAR_FIELDS do
		local field = state.Fields[name]
		buildFluxes(self, field, faces)
		for index = 0, geometry.Count - 1 do
			local offset = index * 4
			local xp = buffer.readu32(geometry.Xp, offset)
			local zp = buffer.readu32(geometry.Zp, offset)
			local divergence = (
				buffer.readf64(self.FluxU, xp * 8) - buffer.readf64(self.FluxU, index * 8)
			)
					/ geometry.Dx
				+ (buffer.readf64(self.FluxV, zp * 8) - buffer.readf64(self.FluxV, index * 8)) / geometry.Dz
				+ (
						buffer.readf64(self.FluxW, (index + geometry.Plane) * 8)
						- buffer.readf64(self.FluxW, index * 8)
					)
					/ geometry.Dy
			local value = buffer.readf32(field, offset) - dt * divergence
			if
				value ~= value
				or math.abs(value) > MAX_FLOAT32
				or value < 0
				or (name == "theta" and value == 0)
			then
				error(
					"Transport produced invalid scalar "
						.. name
						.. " at cell "
						.. tostring(index + 1)
				)
			end
			buffer.writef32(self.ScalarScratch, offset, value)
		end
		-- Every source cell for this scalar has been read before the swap. Keep the
		-- state object stable; consumers must not retain field buffers across Steps.
		state.Fields[name] = self.ScalarScratch
		self.ScalarScratch = field
	end
	return maxCourant
end

return Transport
