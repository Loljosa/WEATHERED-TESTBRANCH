--!native
--!strict

local AtmosphereState = require(script.Parent.Parent.Core.AtmosphereState)
local FaceVelocity = require(script.Parent.Parent.Core.FaceVelocity)
local Geometry = require(script.Parent.Parent.Core.Geometry)

local Transport = {}
Transport.__index = Transport

Transport.MaxCourant = 0.8
local MAX_FLOAT32 = 3.4028234663852886e38
local SCALAR_FIELDS: { AtmosphereState.FieldName } = { "theta", "qv", "qc", "qr" }
-- Leave a double-precision rounding margin in limiter budgets. This changes
-- accepted face transfers, not cell values, so conservation remains pairwise.
local BUDGET_SAFETY = 1 - 64 * 2.220446049250313e-16

export type Scheme = "FCT" | "Upwind"
export type Options = { Scheme: Scheme? }
export type Diagnostics = {
	CorrectionFaces: number, -- nonzero transfers over both RK stages/all fields
	LimitedFaces: number,
}

export type Transport = typeof(setmetatable(
	{} :: {
		Geometry: Geometry.Geometry,
		Scheme: Scheme,
		FluxU: buffer,
		FluxV: buffer,
		FluxW: buffer,
		Outputs: { [string]: buffer },
		ZeroFields: { [string]: boolean },
		Stage: buffer,
		Low: buffer,
		RPlus: buffer,
		RMinus: buffer,
		Last: Diagnostics,
	},
	Transport
))

-- Constant-density finite-volume transport on authoritative MAC faces.
-- FCT corrects shared upwind fluxes toward MC-MUSCL fluxes, then SSPRK2 combines
-- two bounded stages. Upwind preserves the first-order comparison operator.
-- Face velocities are m/s, Dx/Dy/Dz meters, dt seconds. Scalar integrals are
-- conserved to final float32 commit roundoff. No cell-value clipping is used.
function Transport.new(geometry: Geometry.Geometry, options: Options?): Transport
	local scheme: Scheme = if options and options.Scheme then options.Scheme else "FCT"
	assert(scheme == "FCT" or scheme == "Upwind", "Unknown scalar transport scheme")
	local outputs: { [string]: buffer } = {}
	local zeroFields: { [string]: boolean } = {}
	for _, name in SCALAR_FIELDS do
		outputs[name] = buffer.create(geometry.Count * 4)
		zeroFields[name] = false
	end
	return setmetatable({
		Geometry = geometry,
		Scheme = scheme,
		FluxU = buffer.create(geometry.Count * 8),
		FluxV = buffer.create(geometry.Count * 8),
		FluxW = buffer.create((geometry.Count + geometry.Plane) * 8),
		Outputs = outputs,
		ZeroFields = zeroFields,
		Stage = buffer.create(geometry.Count * 8),
		Low = buffer.create(geometry.Count * 8),
		RPlus = buffer.create(geometry.Count * 8),
		RMinus = buffer.create(geometry.Count * 8),
		Last = { CorrectionFaces = 0, LimitedFaces = 0 },
	}, Transport)
end

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
		local courant = dt
			* (
				(
						math.max(buffer.readf32(faces.U, xp), 0)
						+ math.max(-buffer.readf32(faces.U, offset), 0)
					)
					/ geometry.Dx
				+ (math.max(buffer.readf32(faces.V, zp), 0) + math.max(
					-buffer.readf32(faces.V, offset),
					0
				)) / geometry.Dz
				+ (
						math.max(buffer.readf32(faces.W, (index + geometry.Plane) * 4), 0)
						+ math.max(-buffer.readf32(faces.W, offset), 0)
					)
					/ geometry.Dy
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
		local anyNonzero = false
		assert(buffer.len(field) == geometry.Count * 4, "Scalar field buffer has incorrect length")
		for index = 0, geometry.Count - 1 do
			local value = buffer.readf32(field, index * 4)
			anyNonzero = anyNonzero or value ~= 0
			if
				value ~= value
				or math.abs(value) == math.huge
				or value < 0
				or (name == "theta" and value == 0)
			then
				error("Invalid transport scalar " .. name .. " at cell " .. tostring(index + 1))
			end
		end
		self.ZeroFields[name] = not anyNonzero
	end
	return maxCourant
end

local function writeOutput(output: buffer, index: number, value: number, name: string)
	if
		value ~= value
		or math.abs(value) > MAX_FLOAT32
		or value < 0
		or (name == "theta" and value == 0)
	then
		error("Transport produced invalid scalar " .. name .. " at cell " .. tostring(index + 1))
	end
	buffer.writef32(output, index * 4, value)
end

-- Stage always holds float64 source data; avoiding indirect scalar readers in
-- the hot loops also avoids quantizing the intermediate RK stage.
local function buildLowFluxes(self: Transport, faces: FaceVelocity.FaceVelocity)
	local g = self.Geometry
	local fluxU, fluxV, fluxW, stage = self.FluxU, self.FluxV, self.FluxW, self.Stage
	for index = 0, g.Count - 1 do
		local offset = index * 4
		local u = buffer.readf32(faces.U, offset)
		local v = buffer.readf32(faces.V, offset)
		local w = buffer.readf32(faces.W, offset)
		local donorU = if u >= 0 then buffer.readu32(g.Xm, offset) else index
		local donorV = if v >= 0 then buffer.readu32(g.Zm, offset) else index
		local donorW = if w >= 0 then buffer.readu32(g.Ym, offset) else index
		buffer.writef64(fluxU, index * 8, u * buffer.readf64(stage, donorU * 8))
		buffer.writef64(fluxV, index * 8, v * buffer.readf64(stage, donorV * 8))
		buffer.writef64(fluxW, index * 8, w * buffer.readf64(stage, donorW * 8))
	end
	buffer.fill(fluxW, g.Count * 8, 0, g.Plane * 8)
end

local function lowOrderStage(self: Transport, dt: number)
	local g = self.Geometry
	local fluxU, fluxV, fluxW, stage, lowField =
		self.FluxU, self.FluxV, self.FluxW, self.Stage, self.Low
	for index = 0, g.Count - 1 do
		local xp = buffer.readu32(g.Xp, index * 4)
		local zp = buffer.readu32(g.Zp, index * 4)
		local divergence = (buffer.readf64(fluxU, xp * 8) - buffer.readf64(fluxU, index * 8)) / g.Dx
			+ (buffer.readf64(fluxV, zp * 8) - buffer.readf64(fluxV, index * 8)) / g.Dz
			+ (buffer.readf64(fluxW, (index + g.Plane) * 8) - buffer.readf64(fluxW, index * 8))
				/ g.Dy
		local low = buffer.readf64(stage, index * 8) - dt * divergence
		if low ~= low or low < 0 or low == math.huge then
			error("Invalid low-order transport stage at cell " .. tostring(index + 1))
		end
		buffer.writef64(lowField, index * 8, low)
	end
end

-- Monotonized-central slope, in scalar units per cell (not per meter).
local function slope(source: buffer, index: number, minus: buffer, plus: buffer): number
	local value = buffer.readf64(source, index * 8)
	local left = value - buffer.readf64(source, buffer.readu32(minus, index * 4) * 8)
	local right = buffer.readf64(source, buffer.readu32(plus, index * 4) * 8) - value
	if left * right <= 0 then
		return 0
	end
	local sign = if left > 0 then 1 else -1
	return sign * math.min(2 * math.abs(left), 2 * math.abs(right), 0.5 * math.abs(left + right))
end

-- Replace low flux storage with A = dt/d * (F_MUSCL - F_upwind), oriented
-- from the minus neighbor into this cell. F_MUSCL reconstructs the upwind
-- donor by +/- half an MC slope; therefore A = dt/d * |velocity| * slope/2.
local function buildCorrections(self: Transport, faces: FaceVelocity.FaceVelocity, dt: number)
	local g = self.Geometry
	local fluxU, fluxV, fluxW, stage = self.FluxU, self.FluxV, self.FluxW, self.Stage
	for index = 0, g.Count - 1 do
		local offset = index * 4
		local u = buffer.readf32(faces.U, offset)
		local v = buffer.readf32(faces.V, offset)
		local w = buffer.readf32(faces.W, offset)
		local donorU = if u >= 0 then buffer.readu32(g.Xm, offset) else index
		local donorV = if v >= 0 then buffer.readu32(g.Zm, offset) else index
		local donorW = if w >= 0 then buffer.readu32(g.Ym, offset) else index
		buffer.writef64(
			fluxU,
			index * 8,
			0.5 * math.abs(u) * dt / g.Dx * slope(stage, donorU, g.Xm, g.Xp)
		)
		buffer.writef64(
			fluxV,
			index * 8,
			0.5 * math.abs(v) * dt / g.Dz * slope(stage, donorV, g.Zm, g.Zp)
		)
		buffer.writef64(
			fluxW,
			index * 8,
			0.5 * math.abs(w) * dt / g.Dy * slope(stage, donorW, g.Ym, g.Yp)
		)
	end
	buffer.fill(fluxW, g.Count * 8, 0, g.Plane * 8)
end

-- Sum signed antidiffusive cell contributions, then budget how much can be
-- accepted toward each bound. Including qLow makes the correction feasible
-- even for a divergent test flow: FCT never conceals compression by clipping.
local function budgetCorrections(self: Transport)
	local g = self.Geometry
	local fluxU, fluxV, fluxW, stage = self.FluxU, self.FluxV, self.FluxW, self.Stage
	local lowField, rPlus, rMinus = self.Low, self.RPlus, self.RMinus
	for index = 0, g.Count - 1 do
		local offset = index * 4
		local xp = buffer.readu32(g.Xp, offset)
		local xm = buffer.readu32(g.Xm, offset)
		local yp = buffer.readu32(g.Yp, offset)
		local ym = buffer.readu32(g.Ym, offset)
		local zp = buffer.readu32(g.Zp, offset)
		local zm = buffer.readu32(g.Zm, offset)
		local left = buffer.readf64(fluxU, index * 8)
		local right = -buffer.readf64(fluxU, xp * 8)
		local back = buffer.readf64(fluxV, index * 8)
		local front = -buffer.readf64(fluxV, zp * 8)
		local bottom = buffer.readf64(fluxW, index * 8)
		local top = -buffer.readf64(fluxW, (index + g.Plane) * 8)
		local positive = math.max(left, 0)
			+ math.max(right, 0)
			+ math.max(back, 0)
			+ math.max(front, 0)
			+ math.max(bottom, 0)
			+ math.max(top, 0)
		local negative = math.max(-left, 0)
			+ math.max(-right, 0)
			+ math.max(-back, 0)
			+ math.max(-front, 0)
			+ math.max(-bottom, 0)
			+ math.max(-top, 0)
		local low = buffer.readf64(lowField, index * 8)
		local value = buffer.readf64(stage, index * 8)
		local vxm = buffer.readf64(stage, xm * 8)
		local vxp = buffer.readf64(stage, xp * 8)
		local vym = buffer.readf64(stage, ym * 8)
		local vyp = buffer.readf64(stage, yp * 8)
		local vzm = buffer.readf64(stage, zm * 8)
		local vzp = buffer.readf64(stage, zp * 8)
		local minimum = math.min(low, value, vxm, vxp, vym, vyp, vzm, vzp)
		local maximum = math.max(low, value, vxm, vxp, vym, vyp, vzm, vzp)
		buffer.writef64(
			rPlus,
			index * 8,
			if positive > 0 then math.min(1, (maximum - low) * BUDGET_SAFETY / positive) else 1
		)
		buffer.writef64(
			rMinus,
			index * 8,
			if negative > 0 then math.min(1, (low - minimum) * BUDGET_SAFETY / negative) else 1
		)
	end
end

local function limitFace(self: Transport, transfers: buffer, index: number, minus: number)
	local transfer = buffer.readf64(transfers, index * 8)
	local factor = if transfer >= 0
		then math.min(buffer.readf64(self.RPlus, index * 8), buffer.readf64(self.RMinus, minus * 8))
		else math.min(
			buffer.readf64(self.RMinus, index * 8),
			buffer.readf64(self.RPlus, minus * 8)
		)
	if transfer ~= 0 then
		self.Last.CorrectionFaces += 1
		if factor < 1 - 1e-12 then
			self.Last.LimitedFaces += 1
		end
	end
	buffer.writef64(transfers, index * 8, factor * transfer)
end

-- A shared face factor satisfies BOTH adjacent budgets. Each accepted positive
-- sum <= RPlus*PPlus <= qMax-qLow and negative sum <= qLow-qMin. Thus qLow plus
-- corrections stays bounded/nonnegative while every transfer cancels pairwise.
local function limitCorrections(self: Transport)
	local g = self.Geometry
	for index = 0, g.Count - 1 do
		limitFace(self, self.FluxU, index, buffer.readu32(g.Xm, index * 4))
		limitFace(self, self.FluxV, index, buffer.readu32(g.Zm, index * 4))
		limitFace(self, self.FluxW, index, buffer.readu32(g.Ym, index * 4))
	end
end

local function correctedStage(self: Transport, original: buffer, output: buffer?, name: string)
	local g = self.Geometry
	local fluxU, fluxV, fluxW, stage, low = self.FluxU, self.FluxV, self.FluxW, self.Stage, self.Low
	for index = 0, g.Count - 1 do
		local xp = buffer.readu32(g.Xp, index * 4)
		local zp = buffer.readu32(g.Zp, index * 4)
		local value = buffer.readf64(low, index * 8)
			+ buffer.readf64(fluxU, index * 8)
			- buffer.readf64(fluxU, xp * 8)
			+ buffer.readf64(fluxV, index * 8)
			- buffer.readf64(fluxV, zp * 8)
			+ buffer.readf64(fluxW, index * 8)
			- buffer.readf64(fluxW, (index + g.Plane) * 8)
		if value ~= value or value < 0 or value == math.huge then
			error("Invalid bounded transport stage at cell " .. tostring(index + 1))
		end
		if output then
			-- SSPRK2 convex combination: source and both stages conserve water and
			-- are nonnegative. Only this final result is rounded to float32.
			writeOutput(output, index, 0.5 * (buffer.readf32(original, index * 4) + value), name)
		else
			-- Source has been fully consumed by the preceding flux/budget passes.
			buffer.writef64(stage, index * 8, value)
		end
	end
end

local function fctStage(
	self: Transport,
	original: buffer,
	output: buffer?,
	name: string,
	faces: FaceVelocity.FaceVelocity,
	dt: number
)
	buildLowFluxes(self, faces)
	lowOrderStage(self, dt)
	buildCorrections(self, faces, dt)
	budgetCorrections(self)
	limitCorrections(self)
	correctedStage(self, original, output, name)
end

function Transport:Advance(
	state: AtmosphereState.AtmosphereState,
	faces: FaceVelocity.FaceVelocity,
	dt: number
): number
	local maxCourant = preflight(self, state, faces, dt)
	self.Last.CorrectionFaces = 0
	self.Last.LimitedFaces = 0
	if dt == 0 then
		return maxCourant
	end
	for _, name in SCALAR_FIELDS do
		local field = state.Fields[name]
		if self.ZeroFields[name] then
			-- Exactly zero source has exactly zero flux/correction under either
			-- scheme for every velocity field. This is an identity, not a threshold.
			buffer.fill(self.Outputs[name], 0, 0)
		else
			for index = 0, self.Geometry.Count - 1 do
				buffer.writef64(self.Stage, index * 8, buffer.readf32(field, index * 4))
			end
			if self.Scheme == "FCT" then
				fctStage(self, field, nil, name, faces, dt)
				fctStage(self, field, self.Outputs[name], name, faces, dt)
			else
				buildLowFluxes(self, faces)
				lowOrderStage(self, dt)
				for index = 0, self.Geometry.Count - 1 do
					writeOutput(
						self.Outputs[name],
						index,
						buffer.readf64(self.Low, index * 8),
						name
					)
				end
			end
		end
	end
	-- Commit all four fields together only after their complete outputs validate.
	-- Both source and output buffers are reusable; no timestep allocation occurs.
	for _, name in SCALAR_FIELDS do
		local old = state.Fields[name]
		state.Fields[name] = self.Outputs[name]
		self.Outputs[name] = old
	end
	return maxCourant
end

return Transport
