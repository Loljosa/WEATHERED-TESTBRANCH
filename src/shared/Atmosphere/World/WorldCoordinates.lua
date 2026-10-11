--!strict

-- One unit conversion owns the coarse weather domain. Horizontal coordinates
-- are world-global; altitude meters are absolute and map to a separate visual
-- base. Logical regions are bookkeeping subdivisions, never physical walls.
local WorldCoordinates = {}
WorldCoordinates.__index = WorldCoordinates

local WORLD_SIZE_STUDS = 4028
local REGIONS_PER_AXIS = 4
local REGION_SIZE_STUDS = WORLD_SIZE_STUDS / REGIONS_PER_AXIS

export type Options = {
	WidthStuds: number?,
	DepthStuds: number?,
	CenterX: number?,
	CenterZ: number?,
	StudsPerMeter: number?,
	BottomStuds: number?,
	BaseAltitudeMeters: number?,
	HeightMeters: number?,
}

export type RegionBounds = {
	X: number,
	Z: number,
	Id: number,
	MinX: number,
	MaxX: number,
	MinZ: number,
	MaxZ: number,
	WidthStuds: number,
	DepthStuds: number,
	MinXMeters: number,
	MaxXMeters: number,
	MinZMeters: number,
	MaxZMeters: number,
}

export type PhysicalRegion = {
	OriginX: number,
	OriginY: number,
	OriginZ: number,
	SizeX: number,
	SizeY: number,
	SizeZ: number,
	Dx: number,
	Dy: number,
	Dz: number,
}

export type Coordinates = typeof(setmetatable(
	{} :: {
		WidthStuds: number,
		DepthStuds: number,
		CenterX: number,
		CenterZ: number,
		MinX: number,
		MaxX: number,
		MinZ: number,
		MaxZ: number,
		StudsPerMeter: number,
		WidthMeters: number,
		DepthMeters: number,
		MinXMeters: number,
		MaxXMeters: number,
		MinZMeters: number,
		MaxZMeters: number,
		BottomStuds: number,
		TopStuds: number,
		BaseAltitudeMeters: number,
		TopAltitudeMeters: number,
		HeightMeters: number,
		RegionsX: number,
		RegionsZ: number,
		RegionCount: number,
		RegionSizeStuds: number,
		Bounds: { RegionBounds },
	},
	WorldCoordinates
))

local function finite(value: number, name: string)
	assert(
		type(value) == "number" and value == value and math.abs(value) < math.huge,
		name .. " must be finite"
	)
end

local function dimension(value: number, name: string)
	finite(value, name)
	assert(value >= 1 and value % 1 == 0, name .. " must be a positive integer")
end

local function regionCoordinate(value: number, name: string)
	dimension(value + 1, name)
	assert(value < REGIONS_PER_AXIS, name .. " must be in 0..3")
end

local function validateCell(x: number, y: number, z: number, nx: number, ny: number, nz: number)
	dimension(nx, "SizeX")
	dimension(ny, "SizeY")
	dimension(nz, "SizeZ")
	dimension(x, "Cell X")
	dimension(y, "Cell Y")
	dimension(z, "Cell Z")
	assert(x <= nx and y <= ny and z <= nz, "Cell is outside the world field")
end

function WorldCoordinates.new(options: Options?): Coordinates
	local settings = options or {}
	assert(
		(settings.WidthStuds == nil or settings.WidthStuds == WORLD_SIZE_STUDS)
			and (settings.DepthStuds == nil or settings.DepthStuds == WORLD_SIZE_STUDS),
		"Phase 2.6 horizontal coverage must be exactly 4028 by 4028 studs"
	)
	local centerX = settings.CenterX or 0
	local centerZ = settings.CenterZ or 0
	local ratio = settings.StudsPerMeter or 2
	local bottom = settings.BottomStuds or 424
	local altitude = settings.BaseAltitudeMeters or 1000
	local height = settings.HeightMeters or 72
	finite(centerX, "CenterX (studs)")
	finite(centerZ, "CenterZ (studs)")
	finite(ratio, "StudsPerMeter")
	-- This configurable modeling scale is intentionally explicit and bounded.
	-- It does not inherit the old debug Grid3D's independent CellSize spacing.
	assert(ratio >= 0.1 and ratio <= 100, "StudsPerMeter must be in 0.1..100")
	finite(bottom, "BottomStuds")
	finite(altitude, "BaseAltitudeMeters")
	finite(height, "HeightMeters")
	assert(height > 0, "HeightMeters must be positive")
	local half = WORLD_SIZE_STUDS / 2
	local minX, maxX = centerX - half, centerX + half
	local minZ, maxZ = centerZ - half, centerZ + half
	local top = bottom + height * ratio
	finite(top, "TopStuds")
	finite(altitude + height, "TopAltitudeMeters")
	assert(top > bottom and altitude + height > altitude, "Vertical extent must be representable")
	assert(
		maxX - minX == WORLD_SIZE_STUDS and maxZ - minZ == WORLD_SIZE_STUDS,
		"World center is too large to represent exact 4028-stud coverage"
	)
	local bounds: { RegionBounds } = table.create(REGIONS_PER_AXIS * REGIONS_PER_AXIS)
	for rz = 0, REGIONS_PER_AXIS - 1 do
		for rx = 0, REGIONS_PER_AXIS - 1 do
			local id = rz * REGIONS_PER_AXIS + rx + 1
			local left = minX + rx * REGION_SIZE_STUDS
			local front = minZ + rz * REGION_SIZE_STUDS
			bounds[id] = table.freeze({
				X = rx,
				Z = rz,
				Id = id,
				MinX = left,
				MaxX = left + REGION_SIZE_STUDS,
				MinZ = front,
				MaxZ = front + REGION_SIZE_STUDS,
				WidthStuds = REGION_SIZE_STUDS,
				DepthStuds = REGION_SIZE_STUDS,
				MinXMeters = left / ratio,
				MaxXMeters = (left + REGION_SIZE_STUDS) / ratio,
				MinZMeters = front / ratio,
				MaxZMeters = (front + REGION_SIZE_STUDS) / ratio,
			})
		end
	end
	return table.freeze(setmetatable({
		WidthStuds = WORLD_SIZE_STUDS,
		DepthStuds = WORLD_SIZE_STUDS,
		CenterX = centerX,
		CenterZ = centerZ,
		MinX = minX,
		MaxX = maxX,
		MinZ = minZ,
		MaxZ = maxZ,
		StudsPerMeter = ratio,
		WidthMeters = WORLD_SIZE_STUDS / ratio,
		DepthMeters = WORLD_SIZE_STUDS / ratio,
		MinXMeters = minX / ratio,
		MaxXMeters = maxX / ratio,
		MinZMeters = minZ / ratio,
		MaxZMeters = maxZ / ratio,
		BottomStuds = bottom,
		TopStuds = top,
		BaseAltitudeMeters = altitude,
		TopAltitudeMeters = altitude + height,
		HeightMeters = height,
		RegionsX = REGIONS_PER_AXIS,
		RegionsZ = REGIONS_PER_AXIS,
		RegionCount = REGIONS_PER_AXIS * REGIONS_PER_AXIS,
		RegionSizeStuds = REGION_SIZE_STUDS,
		Bounds = table.freeze(bounds),
	}, WorldCoordinates))
end

function WorldCoordinates:StudsToMeters(value: number): number
	finite(value, "Stud distance")
	local result = value / self.StudsPerMeter
	finite(result, "Converted meter distance")
	return result
end

function WorldCoordinates:MetersToStuds(value: number): number
	finite(value, "Meter distance")
	local result = value * self.StudsPerMeter
	finite(result, "Converted stud distance")
	return result
end

function WorldCoordinates:WorldToPhysical(x: number, y: number, z: number): (number, number, number)
	finite(x, "World X (studs)")
	finite(y, "World Y (studs)")
	finite(z, "World Z (studs)")
	local physicalX = self:StudsToMeters(x)
	local physicalY = self.BaseAltitudeMeters + self:StudsToMeters(y - self.BottomStuds)
	local physicalZ = self:StudsToMeters(z)
	finite(physicalY, "Converted physical altitude (meters)")
	return physicalX, physicalY, physicalZ
end

function WorldCoordinates:PhysicalToWorld(x: number, y: number, z: number): (number, number, number)
	finite(x, "Physical X (meters)")
	finite(y, "Physical altitude (meters)")
	finite(z, "Physical Z (meters)")
	local worldX = self:MetersToStuds(x)
	local worldY = self.BottomStuds + self:MetersToStuds(y - self.BaseAltitudeMeters)
	local worldZ = self:MetersToStuds(z)
	finite(worldY, "Converted world Y (studs)")
	return worldX, worldY, worldZ
end

-- Bounds are half-open. +2014 is outside the default domain; explicit global
-- wrapping maps it to -2014. No internal 1007-stud region wraps independently.
function WorldCoordinates:WorldToRegion(x: number, z: number): (number?, number?, number?)
	finite(x, "World X (studs)")
	finite(z, "World Z (studs)")
	if x < self.MinX or x >= self.MaxX or z < self.MinZ or z >= self.MaxZ then
		return nil, nil, nil
	end
	-- A representable point immediately below MaxX can have x-MinX round up
	-- to the full extent. The explicit inside test above remains authoritative.
	local rx = math.min(self.RegionsX - 1, math.floor((x - self.MinX) / self.RegionSizeStuds))
	local rz = math.min(self.RegionsZ - 1, math.floor((z - self.MinZ) / self.RegionSizeStuds))
	return rx, rz, rz * self.RegionsX + rx + 1
end

function WorldCoordinates:RegionBounds(rx: number, rz: number): RegionBounds
	regionCoordinate(rx, "Region X")
	regionCoordinate(rz, "Region Z")
	return self.Bounds[rz * self.RegionsX + rx + 1]
end

function WorldCoordinates:RegionCoordinates(id: number): (number, number)
	dimension(id, "Region ID")
	assert(id <= self.RegionCount, "Region ID must be in 1..16")
	return (id - 1) % self.RegionsX, math.floor((id - 1) / self.RegionsX)
end

function WorldCoordinates:WrapX(x: number): number
	finite(x, "World X (studs)")
	if x >= self.MinX and x < self.MaxX then
		return x
	end
	return self.MinX + (x - self.MinX) % self.WidthStuds
end

function WorldCoordinates:WrapZ(z: number): number
	finite(z, "World Z (studs)")
	if z >= self.MinZ and z < self.MaxZ then
		return z
	end
	return self.MinZ + (z - self.MinZ) % self.DepthStuds
end

function WorldCoordinates:WrapPhysicalX(x: number): number
	finite(x, "Physical X (meters)")
	if x >= self.MinXMeters and x < self.MaxXMeters then
		return x
	end
	return self.MinXMeters + (x - self.MinXMeters) % self.WidthMeters
end

function WorldCoordinates:WrapPhysicalZ(z: number): number
	finite(z, "Physical Z (meters)")
	if z >= self.MinZMeters and z < self.MaxZMeters then
		return z
	end
	return self.MinZMeters + (z - self.MinZMeters) % self.DepthMeters
end

function WorldCoordinates:PhysicalRegion(nx: number, ny: number, nz: number): PhysicalRegion
	dimension(nx, "SizeX")
	dimension(ny, "SizeY")
	dimension(nz, "SizeZ")
	return table.freeze({
		OriginX = self.MinXMeters,
		OriginY = self.BaseAltitudeMeters,
		OriginZ = self.MinZMeters,
		SizeX = self.WidthMeters,
		SizeY = self.HeightMeters,
		SizeZ = self.DepthMeters,
		Dx = self.WidthMeters / nx,
		Dy = self.HeightMeters / ny,
		Dz = self.DepthMeters / nz,
	})
end

function WorldCoordinates:CellCenterPhysical(
	x: number,
	y: number,
	z: number,
	nx: number,
	ny: number,
	nz: number
): (number, number, number)
	validateCell(x, y, z, nx, ny, nz)
	return self.MinXMeters + (x - 0.5) * self.WidthMeters / nx,
		self.BaseAltitudeMeters + (y - 0.5) * self.HeightMeters / ny,
		self.MinZMeters + (z - 0.5) * self.DepthMeters / nz
end

function WorldCoordinates:CellCenterWorld(
	x: number,
	y: number,
	z: number,
	nx: number,
	ny: number,
	nz: number
): (number, number, number)
	return self:PhysicalToWorld(self:CellCenterPhysical(x, y, z, nx, ny, nz))
end

function WorldCoordinates:WorldToCell(
	x: number,
	y: number,
	z: number,
	nx: number,
	ny: number,
	nz: number
): (number?, number?, number?)
	dimension(nx, "SizeX")
	dimension(ny, "SizeY")
	dimension(nz, "SizeZ")
	finite(y, "World Y (studs)")
	if self:WorldToRegion(x, z) == nil or y < self.BottomStuds or y >= self.TopStuds then
		return nil, nil, nil
	end
	return math.min(nx, math.floor((x - self.MinX) * nx / self.WidthStuds) + 1),
		math.min(
			ny,
			math.floor((y - self.BottomStuds) * ny / (self.TopStuds - self.BottomStuds)) + 1
		),
		math.min(nz, math.floor((z - self.MinZ) * nz / self.DepthStuds) + 1)
end

return table.freeze(WorldCoordinates)
