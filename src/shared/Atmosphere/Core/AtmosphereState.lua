--!strict

local Grid3D = require(script.Parent.Grid3D)

export type FieldName =
	"u"
	| "v"
	| "w"
	| "theta"
	| "qv"
	| "qc"
	| "qr"
	| "pressure"

export type AtmosphereState = {
	Grid: Grid3D.Grid3D,
	Fields: { [string]: buffer },

	Get: (self: AtmosphereState, field: FieldName, index: number) -> number,
	Set: (self: AtmosphereState, field: FieldName, index: number, value: number) -> (),
	GetCell: (
		self: AtmosphereState,
		field: FieldName,
		x: number,
		y: number,
		z: number
	) -> number,
	SetCell: (
		self: AtmosphereState,
		field: FieldName,
		x: number,
		y: number,
		z: number,
		value: number
	) -> (),
	Fill: (self: AtmosphereState, field: FieldName, value: number) -> (),
}

local AtmosphereState = {}
AtmosphereState.__index = AtmosphereState

local FIELD_NAMES: { FieldName } = {
	"u",
	"v",
	"w",

	"theta",

	"qv",
	"qc",
	"qr",

	"pressure",
}

local FLOAT_SIZE = 4

local function offset(index: number): number
	return (index - 1) * FLOAT_SIZE
end

local function createField(count: number): buffer
	return buffer.create(count * FLOAT_SIZE)
end

function AtmosphereState.new(grid: Grid3D.Grid3D): AtmosphereState
	local fields: { [string]: buffer } = {}

	for _, name in FIELD_NAMES do
		fields[name] = createField(grid.Count)
	end

	local self = setmetatable({
		Grid = grid,
		Fields = fields,
	}, AtmosphereState)

	self:Fill("theta", 300.0)
	self:Fill("pressure", 100000.0)

	return self
end

function AtmosphereState:Get(field: FieldName, index: number): number
	assert(index >= 1 and index <= self.Grid.Count, "Atmosphere index outside domain")

	local fieldBuffer = self.Fields[field]
	assert(fieldBuffer ~= nil, "Unknown atmospheric field")

	return buffer.readf32(fieldBuffer, offset(index))
end

function AtmosphereState:Set(field: FieldName, index: number, value: number)
	assert(index >= 1 and index <= self.Grid.Count, "Atmosphere index outside domain")

	local fieldBuffer = self.Fields[field]
	assert(fieldBuffer ~= nil, "Unknown atmospheric field")

	buffer.writef32(fieldBuffer, offset(index), value)
end

function AtmosphereState:GetCell(
	field: FieldName,
	x: number,
	y: number,
	z: number
): number
	return self:Get(field, self.Grid:Index(x, y, z))
end

function AtmosphereState:SetCell(
	field: FieldName,
	x: number,
	y: number,
	z: number,
	value: number
)
	self:Set(field, self.Grid:Index(x, y, z), value)
end

function AtmosphereState:Fill(field: FieldName, value: number)
	local fieldBuffer = self.Fields[field]
	assert(fieldBuffer ~= nil, "Unknown atmospheric field")

	for index = 1, self.Grid.Count do
		buffer.writef32(fieldBuffer, offset(index), value)
	end
end

return AtmosphereState
