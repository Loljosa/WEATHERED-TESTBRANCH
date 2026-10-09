--!native
--!strict

local AtmosphereState = require(script.Parent.AtmosphereState)
local Geometry = require(script.Parent.Geometry)

local FaceVelocity = {}
FaceVelocity.__index = FaceVelocity

export type FaceVelocity = typeof(setmetatable(
	{} :: {
		Geometry: Geometry.Geometry,
		U: buffer,
		V: buffer,
		W: buffer,
	},
	FaceVelocity
))

-- Authoritative MAC velocities in m/s. U/V each store Count unique periodic
-- negative-X/negative-Z faces; positive faces use Xp/Zp CELL indices. W stores
-- Count+Plane negative-Y faces; cell i's top face is i+Plane, including wall faces.
-- AtmosphereState u/v/w remain derived cell-center diagnostics.
function FaceVelocity.new(geometry: Geometry.Geometry): FaceVelocity
	return setmetatable({
		Geometry = geometry,
		U = buffer.create(geometry.Count * 4),
		V = buffer.create(geometry.Count * 4),
		W = buffer.create((geometry.Count + geometry.Plane) * 4),
	}, FaceVelocity)
end

function FaceVelocity:Seal()
	local wallBytes = self.Geometry.Plane * 4
	buffer.fill(self.W, 0, 0, wallBytes)
	buffer.fill(self.W, self.Geometry.Count * 4, 0, wallBytes)
end

local function checkFieldFinite(field: buffer, component: string)
	for offset = 0, buffer.len(field) - 4, 4 do
		local value = buffer.readf32(field, offset)
		if value ~= value or math.abs(value) == math.huge then
			error("Nonfinite " .. component .. " velocity at face " .. tostring(offset / 4 + 1))
		end
	end
end

function FaceVelocity:CheckFinite()
	local geometry = self.Geometry
	assert(buffer.len(self.U) == geometry.Count * 4, "U face buffer has incorrect length")
	assert(buffer.len(self.V) == geometry.Count * 4, "V face buffer has incorrect length")
	assert(
		buffer.len(self.W) == (geometry.Count + geometry.Plane) * 4,
		"W face buffer has incorrect length"
	)
	checkFieldFinite(self.U, "U")
	checkFieldFinite(self.V, "V")
	checkFieldFinite(self.W, "W")
end

function FaceVelocity:Initialize(state: AtmosphereState.AtmosphereState)
	local geometry = self.Geometry
	assert(state.Grid == geometry.Grid, "State grid must match face geometry")
	local fields = state.Fields
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local xm = buffer.readu32(geometry.Xm, offset) * 4
		local zm = buffer.readu32(geometry.Zm, offset) * 4
		local ym = buffer.readu32(geometry.Ym, offset) * 4
		local centerW = buffer.readf32(fields.w, offset)
		assert(
			centerW == centerW and math.abs(centerW) < math.huge,
			"Initial cell-center W must be finite"
		)
		buffer.writef32(
			self.U,
			offset,
			0.5 * (buffer.readf32(fields.u, xm) + buffer.readf32(fields.u, offset))
		)
		buffer.writef32(
			self.V,
			offset,
			0.5 * (buffer.readf32(fields.v, zm) + buffer.readf32(fields.v, offset))
		)
		buffer.writef32(self.W, offset, 0.5 * (buffer.readf32(fields.w, ym) + centerW))
	end
	self:Seal()
	self:CheckFinite()
end

function FaceVelocity:WriteCellCenters(state: AtmosphereState.AtmosphereState)
	local geometry = self.Geometry
	assert(state.Grid == geometry.Grid, "State grid must match face geometry")
	self:CheckFinite()
	local fields = state.Fields
	local stride = geometry.Plane * 4
	for index = 0, geometry.Count - 1 do
		local offset = index * 4
		local xp = buffer.readu32(geometry.Xp, offset) * 4
		local zp = buffer.readu32(geometry.Zp, offset) * 4
		buffer.writef32(
			fields.u,
			offset,
			0.5 * (buffer.readf32(self.U, offset) + buffer.readf32(self.U, xp))
		)
		buffer.writef32(
			fields.v,
			offset,
			0.5 * (buffer.readf32(self.V, offset) + buffer.readf32(self.V, zp))
		)
		buffer.writef32(
			fields.w,
			offset,
			0.5 * (buffer.readf32(self.W, offset) + buffer.readf32(self.W, offset + stride))
		)
	end
end

return FaceVelocity
