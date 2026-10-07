--!strict

local Grid3D = require(script.Parent.Core.Grid3D)
local AtmosphereState = require(script.Parent.Core.AtmosphereState)
local Sounding = require(script.Parent.Thermodynamics.Sounding)
local WarmCloud = require(script.Parent.Microphysics.WarmCloud)
local Buoyancy = require(script.Parent.Dynamics.Buoyancy)
local Validation = require(script.Parent.Utilities.Validation)

local Simulation = {}
Simulation.__index = Simulation

Simulation.FixedDt = 0.25 -- physical seconds, 4 Hz; independent of Heartbeat dt.
Simulation.CellHeightMeters = 100 -- display cells remain 64 studs by default.
local DRAG_TIMESCALE = 30 -- s, unresolved momentum dissipation in this column prototype.
local MAX_COURANT = 0.5
local TRANSPORT_FIELDS = { "theta", "qv", "qc", "w" }

export type Diagnostics = {
	Time: number,
	CloudCells: number,
	MaxCloudWater: number,
	MaxVerticalVelocity: number,
	TotalWater: number, -- sum of mixing ratios, not kilograms (no density/volume weighting).
}

export type Simulation = typeof(setmetatable(
	{} :: {
		State: AtmosphereState.AtmosphereState,
		Profile: Sounding.Profile,
		Scratch: { [string]: buffer },
		Time: number,
	},
	Simulation
))

function Simulation.new(grid: Grid3D.Grid3D): Simulation
	assert(grid.SizeY >= 3, "Vertical simulation requires at least three layers")
	local state = AtmosphereState.new(grid)
	local scratch: { [string]: buffer } = {}
	for _, name in TRANSPORT_FIELDS do
		scratch[name] = buffer.create(grid.Count * 4)
	end
	local self = setmetatable({
		State = state,
		Profile = Sounding.Initialize(state, Simulation.CellHeightMeters),
		Scratch = scratch,
		Time = 0,
	}, Simulation)
	Validation.CheckState(state)
	return self
end

-- First-order material (advective-form) transport in independent vertical
-- columns. Positive interpolation weights require CFL <= 0.5. This preserves
-- bounds and avoids update-order bias, but without pressure projection it does
-- NOT conserve the domain water integral in a divergent velocity field.
local function transport(self: Simulation, dt: number)
	local state = self.State
	local grid = state.Grid
	local strideBytes = grid.SizeX * grid.SizeZ * 4
	local oldW = state.Fields.w
	local factor = dt / self.Profile.CellHeightMeters
	for y = 1, grid.SizeY do
		local first = (y - 1) * strideBytes
		for offset = first, first + strideBytes - 4, 4 do
			local velocity = buffer.readf32(oldW, offset)
			local courant = math.abs(velocity) * factor
			if not Validation.IsFinite(courant) or courant > MAX_COURANT then
				error(
					string.format(
						"Vertical CFL exceeded at cell %d: %.6g (limit %.2f)",
						offset / 4 + 1,
						courant,
						MAX_COURANT
					)
				)
			end
			local donorOffset = offset
			if velocity > 0 and y > 1 then
				donorOffset -= strideBytes
			elseif velocity < 0 and y < grid.SizeY then
				donorOffset += strideBytes
			end
			for _, name in TRANSPORT_FIELDS do
				local field = state.Fields[name]
				local value = buffer.readf32(field, offset)
				local donor = buffer.readf32(field, donorOffset)
				buffer.writef32(self.Scratch[name], offset, value + courant * (donor - value))
			end
		end
	end
	-- Commit only after every source cell has been read. References to State stay
	-- stable; consumers must not retain individual buffers across a Step.
	for _, name in TRANSPORT_FIELDS do
		local old = state.Fields[name]
		state.Fields[name] = self.Scratch[name]
		self.Scratch[name] = old
	end
end

function Simulation:Step(dt: number)
	assert(
		Validation.IsFinite(dt) and dt > 0 and dt <= Simulation.FixedDt,
		"Step dt must be positive and at most FixedDt"
	)
	Validation.CheckState(self.State)
	transport(self, dt)
	local fields = self.State.Fields
	local grid = self.State.Grid
	local stride = grid.SizeX * grid.SizeZ
	for y = 1, grid.SizeY do
		local rowOffset = (y - 1) * 4
		local environmentTheta = buffer.readf32(self.Profile.Theta, rowOffset)
		local environmentQv = buffer.readf32(self.Profile.Qv, rowOffset)
		for index = (y - 1) * stride + 1, y * stride do
			local offset = (index - 1) * 4
			local theta, qv, qc = WarmCloud.Adjust(
				buffer.readf32(fields.theta, offset),
				buffer.readf32(fields.qv, offset),
				buffer.readf32(fields.qc, offset),
				buffer.readf32(fields.pressure, offset)
			)
			local buoyancy = Buoyancy.Calculate(theta, qv, qc, environmentTheta, environmentQv)
			local velocity = 0 -- sealed boundary cell centers at top/bottom.
			if y > 1 and y < grid.SizeY then
				velocity = Buoyancy.UpdateVelocity(
					buffer.readf32(fields.w, offset),
					buoyancy,
					dt,
					DRAG_TIMESCALE
				)
			end
			buffer.writef32(fields.theta, offset, theta)
			buffer.writef32(fields.qv, offset, qv)
			buffer.writef32(fields.qc, offset, qc)
			buffer.writef32(fields.w, offset, velocity)
		end
	end
	Validation.CheckState(self.State)
	self.Time += dt
end

function Simulation:GetDiagnostics(): Diagnostics
	local fields = self.State.Fields
	local cloudCells = 0
	local maxCloudWater = 0
	local maxVerticalVelocity = 0
	local totalWater = 0
	for index = 1, self.State.Grid.Count do
		local offset = (index - 1) * 4
		local qc = buffer.readf32(fields.qc, offset)
		if qc >= 0.00005 then -- matches the default thin-cloud debug threshold.
			cloudCells += 1
		end
		maxCloudWater = math.max(maxCloudWater, qc)
		maxVerticalVelocity =
			math.max(maxVerticalVelocity, math.abs(buffer.readf32(fields.w, offset)))
		totalWater += buffer.readf32(fields.qv, offset) + qc + buffer.readf32(fields.qr, offset)
	end
	return {
		Time = self.Time,
		CloudCells = cloudCells,
		MaxCloudWater = maxCloudWater,
		MaxVerticalVelocity = maxVerticalVelocity,
		TotalWater = totalWater,
	}
end

return Simulation
