--!strict

local Grid3D = {}
Grid3D.__index = Grid3D

export type Grid3D = typeof(setmetatable(
	{} :: {
		SizeX: number,
		SizeY: number,
		SizeZ: number,

		CellSize: number,
		Origin: Vector3,

		Count: number,
	},
	Grid3D
))

local function validateDimension(value: number, name: string)
	assert(value > 0 and value < math.huge, name .. " must be finite and greater than zero")
	assert(value % 1 == 0, name .. " must be an integer")
end

function Grid3D.new(
	sizeX: number,
	sizeY: number,
	sizeZ: number,
	cellSize: number,
	origin: Vector3
): Grid3D
	validateDimension(sizeX, "sizeX")
	validateDimension(sizeY, "sizeY")
	validateDimension(sizeZ, "sizeZ")

	-- CellSize and Origin are Roblox studs, independent of the simulation's meter scale.
	assert(cellSize > 0 and cellSize < math.huge, "cellSize must be finite and greater than zero")
	for _, component in { origin.X, origin.Y, origin.Z } do
		assert(component == component and math.abs(component) < math.huge, "Origin must be finite")
	end

	return setmetatable({
		SizeX = sizeX,
		SizeY = sizeY,
		SizeZ = sizeZ,

		CellSize = cellSize,
		Origin = origin,

		Count = sizeX * sizeY * sizeZ,
	}, Grid3D)
end

function Grid3D:IsInside(x: number, y: number, z: number): boolean
	return x % 1 == 0
		and y % 1 == 0
		and z % 1 == 0
		and x >= 1
		and x <= self.SizeX
		and y >= 1
		and y <= self.SizeY
		and z >= 1
		and z <= self.SizeZ
end

function Grid3D:Index(x: number, y: number, z: number): number
	assert(self:IsInside(x, y, z), "Grid coordinate outside domain")

	return ((y - 1) * self.SizeZ + (z - 1)) * self.SizeX + x
end

function Grid3D:Coordinates(index: number): (number, number, number)
	assert(index % 1 == 0 and index >= 1 and index <= self.Count, "Grid index outside domain")

	local zeroIndex = index - 1

	local x = (zeroIndex % self.SizeX) + 1

	local yzIndex = math.floor(zeroIndex / self.SizeX)

	local z = (yzIndex % self.SizeZ) + 1
	local y = math.floor(yzIndex / self.SizeZ) + 1

	return x, y, z
end

function Grid3D:GridToWorld(x: number, y: number, z: number): Vector3
	assert(self:IsInside(x, y, z), "Grid coordinate outside domain")

	return self.Origin
		+ Vector3.new(
			(x - 0.5) * self.CellSize,
			(y - 0.5) * self.CellSize,
			(z - 0.5) * self.CellSize
		)
end

function Grid3D:WorldToGrid(position: Vector3): (number, number, number)
	assert(
		position.X == position.X
			and position.Y == position.Y
			and position.Z == position.Z
			and math.abs(position.X) < math.huge
			and math.abs(position.Y) < math.huge
			and math.abs(position.Z) < math.huge,
		"World position must be finite"
	)
	local relative = position - self.Origin

	local x = math.floor(relative.X / self.CellSize) + 1
	local y = math.floor(relative.Y / self.CellSize) + 1
	local z = math.floor(relative.Z / self.CellSize) + 1

	return x, y, z
end

return Grid3D
