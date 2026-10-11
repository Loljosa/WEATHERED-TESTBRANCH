--!native
--!strict

-- One globally continuous constant-density finite-volume grid. Region IDs are
-- diagnostic partitions only: every internal face has one shared flux. Scalars
-- are kg/kg dry air (water) or K (theta), not density-weighted mass.
local Advection = {}
Advection.__index = Advection

export type Grid = {
	SizeX: number,
	SizeY: number,
	SizeZ: number,
	Count: number,
	Dx: number,
	Dy: number,
	Dz: number,
}

export type Faces = { U: buffer, V: buffer, W: buffer }
export type Advection = typeof(setmetatable(
	{} :: {
		Grid: Grid,
		Boundary: string,
		FluxU: buffer,
		FluxV: buffer,
		FluxW: buffer,
		RegionQcFlux: buffer,
		RegionWaterNet: buffer,
		InternalQcTransfer: number,
		OuterQcTransfer: number,
		CourantLimit: number,
		MaxSubsteps: number,
	},
	Advection
))

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

function Advection.UOffset(grid: Grid, x: number, y: number, z: number): number
	return ((y * grid.SizeZ + z) * (grid.SizeX + 1) + x) * 8
end

function Advection.VOffset(grid: Grid, x: number, y: number, z: number): number
	return ((y * (grid.SizeZ + 1) + z) * grid.SizeX + x) * 8
end

function Advection.WOffset(grid: Grid, x: number, y: number, z: number): number
	return ((y * grid.SizeZ + z) * grid.SizeX + x) * 8
end

local uOffset = Advection.UOffset
local vOffset = Advection.VOffset
local wOffset = Advection.WOffset

function Advection.new(
	grid: Grid,
	boundary: string?,
	courantLimit: number?,
	maxSubsteps: number?
): Advection
	local selected = boundary or "Periodic"
	assert(
		selected == "Periodic" or selected == "Sealed",
		"World boundary must be Periodic or Sealed"
	)
	local limit = courantLimit or 0.9
	local maximum = maxSubsteps or 32
	assert(finite(limit) and limit > 0 and limit <= 1, "World Courant limit must be in (0,1]")
	assert(
		maximum >= 1 and maximum <= 64 and maximum % 1 == 0,
		"Maximum world substeps must be 1..64"
	)
	assert(
		grid.SizeX % 4 == 0 and grid.SizeZ % 4 == 0,
		"World grid must align with four-by-four regions"
	)
	return setmetatable({
		Grid = grid,
		Boundary = selected,
		FluxU = buffer.create((grid.SizeX + 1) * grid.SizeY * grid.SizeZ * 8),
		FluxV = buffer.create(grid.SizeX * grid.SizeY * (grid.SizeZ + 1) * 8),
		FluxW = buffer.create(grid.SizeX * (grid.SizeY + 1) * grid.SizeZ * 8),
		RegionQcFlux = buffer.create(16 * 8),
		RegionWaterNet = buffer.create(16 * 8),
		InternalQcTransfer = 0,
		OuterQcTransfer = 0,
		CourantLimit = limit,
		MaxSubsteps = maximum,
	}, Advection)
end

-- Positivity condition uses the sum of ALL outgoing face speeds, not three
-- independent one-dimensional Courant tests. Its convex weights are valid
-- because the prescribed face velocity is discretely divergence free.
function Advection:Courant(faces: Faces, dt: number): (number, number, number)
	local grid = self.Grid
	local maximum, divergenceMaximum, divergenceSquared = 0, 0, 0
	for y = 0, grid.SizeY - 1 do
		for z = 0, grid.SizeZ - 1 do
			for x = 0, grid.SizeX - 1 do
				local west = buffer.readf64(faces.U, uOffset(grid, x, y, z))
				local east = buffer.readf64(faces.U, uOffset(grid, x + 1, y, z))
				local south = buffer.readf64(faces.V, vOffset(grid, x, y, z))
				local north = buffer.readf64(faces.V, vOffset(grid, x, y, z + 1))
				local bottom = buffer.readf64(faces.W, wOffset(grid, x, y, z))
				local top = buffer.readf64(faces.W, wOffset(grid, x, y + 1, z))
				assert(
					finite(west)
						and finite(east)
						and finite(south)
						and finite(north)
						and finite(bottom)
						and finite(top),
					"Nonfinite world face velocity"
				)
				local courant = dt
					* (
						(math.max(east, 0) + math.max(-west, 0)) / grid.Dx
						+ (math.max(north, 0) + math.max(-south, 0)) / grid.Dz
						+ (math.max(top, 0) + math.max(-bottom, 0)) / grid.Dy
					)
				local divergence = (east - west) / grid.Dx
					+ (north - south) / grid.Dz
					+ (top - bottom) / grid.Dy
				maximum = math.max(maximum, courant)
				divergenceMaximum = math.max(divergenceMaximum, math.abs(divergence))
				divergenceSquared += divergence * divergence
			end
		end
	end
	assert(
		divergenceMaximum <= 1e-10,
		"World face velocities are not divergence free; mixing-ratio transport would be inconsistent"
	)
	return maximum, divergenceMaximum, math.sqrt(divergenceSquared / grid.Count)
end

function Advection:Substeps(faces: Faces, dt: number): (number, number, number, number)
	assert(finite(dt) and dt > 0, "World timestep must be positive and finite")
	local courant, maximum, rms = self:Courant(faces, dt)
	local steps = math.max(1, math.ceil(courant / self.CourantLimit))
	assert(
		steps <= self.MaxSubsteps,
		"World transport CFL requires more than the configured maximum substeps"
	)
	return steps, courant, maximum, rms
end

function Advection:ResetRegionFlux()
	buffer.fill(self.RegionQcFlux, 0, 0)
	buffer.fill(self.RegionWaterNet, 0, 0)
	self.InternalQcTransfer, self.OuterQcTransfer = 0, 0
end

local function region(grid: Grid, x: number, z: number): number
	return (math.floor(z / (grid.SizeZ / 4)) * 4 + math.floor(x / (grid.SizeX / 4))) * 8
end

local function add(target: buffer, offset: number, increment: number)
	buffer.writef64(target, offset, buffer.readf64(target, offset) + increment)
end

-- Signed net water transfer and absolute liquid transfer at diagnostic region
-- interfaces. This counts flux, never unique clouds. The units are unweighted
-- cell mixing-ratio sums, matching the global fixed-volume water ledger.
function Advection:AccumulateRegionFlux(name: string, dt: number)
	if name == "theta" then
		return
	end
	local grid = self.Grid
	local nx, nz = grid.SizeX, grid.SizeZ
	for y = 0, grid.SizeY - 1 do
		for z = 0, nz - 1 do
			for boundary = 0, 3 do
				local x = boundary * (nx / 4)
				local west = (x - 1) % nx
				local transfer = dt / grid.Dx * buffer.readf64(self.FluxU, uOffset(grid, x, y, z))
				local a, b = region(grid, west, z), region(grid, x, z)
				add(self.RegionWaterNet, a, -transfer)
				add(self.RegionWaterNet, b, transfer)
				if name == "qc" then
					add(self.RegionQcFlux, a, math.abs(transfer))
					add(self.RegionQcFlux, b, math.abs(transfer))
					if boundary == 0 then
						self.OuterQcTransfer += math.abs(transfer)
					else
						self.InternalQcTransfer += math.abs(transfer)
					end
				end
			end
		end
		for x = 0, nx - 1 do
			for boundary = 0, 3 do
				local z = boundary * (nz / 4)
				local south = (z - 1) % nz
				local transfer = dt / grid.Dz * buffer.readf64(self.FluxV, vOffset(grid, x, y, z))
				local a, b = region(grid, x, south), region(grid, x, z)
				add(self.RegionWaterNet, a, -transfer)
				add(self.RegionWaterNet, b, transfer)
				if name == "qc" then
					add(self.RegionQcFlux, a, math.abs(transfer))
					add(self.RegionQcFlux, b, math.abs(transfer))
					if boundary == 0 then
						self.OuterQcTransfer += math.abs(transfer)
					else
						self.InternalQcTransfer += math.abs(transfer)
					end
				end
			end
		end
	end
end

function Advection:Advect(
	source: buffer,
	destination: buffer,
	faces: Faces,
	dt: number,
	name: string
)
	local grid = self.Grid
	local nx, ny, nz = grid.SizeX, grid.SizeY, grid.SizeZ
	local row = nx * 8
	local layer = nx * nz * 8
	for y = 0, ny - 1 do
		for z = 0, nz - 1 do
			local base = y * layer + z * row
			for x = 0, nx do
				local offset = uOffset(grid, x, y, z)
				local velocity = buffer.readf64(faces.U, offset)
				local donor = if velocity >= 0 then (x - 1) % nx else x % nx
				buffer.writef64(
					self.FluxU,
					offset,
					velocity * buffer.readf64(source, base + donor * 8)
				)
			end
		end
		for z = 0, nz do
			for x = 0, nx - 1 do
				local offset = vOffset(grid, x, y, z)
				local velocity = buffer.readf64(faces.V, offset)
				local donor = if velocity >= 0 then (z - 1) % nz else z % nz
				buffer.writef64(
					self.FluxV,
					offset,
					velocity * buffer.readf64(source, y * layer + donor * row + x * 8)
				)
			end
		end
	end
	for y = 0, ny do
		for z = 0, nz - 1 do
			for x = 0, nx - 1 do
				local offset = wOffset(grid, x, y, z)
				local velocity = buffer.readf64(faces.W, offset)
				if y == 0 or y == ny then
					assert(velocity == 0, "Top and bottom world faces must be sealed")
					buffer.writef64(self.FluxW, offset, 0)
				else
					local donor = if velocity >= 0 then y - 1 else y
					buffer.writef64(
						self.FluxW,
						offset,
						velocity * buffer.readf64(source, donor * layer + z * row + x * 8)
					)
				end
			end
		end
	end
	self:AccumulateRegionFlux(name, dt)
	for y = 0, ny - 1 do
		for z = 0, nz - 1 do
			for x = 0, nx - 1 do
				local offset = y * layer + z * row + x * 8
				local east = buffer.readf64(self.FluxU, uOffset(grid, x + 1, y, z))
				local west = buffer.readf64(self.FluxU, uOffset(grid, x, y, z))
				local north = buffer.readf64(self.FluxV, vOffset(grid, x, y, z + 1))
				local south = buffer.readf64(self.FluxV, vOffset(grid, x, y, z))
				local top = buffer.readf64(self.FluxW, wOffset(grid, x, y + 1, z))
				local bottom = buffer.readf64(self.FluxW, wOffset(grid, x, y, z))
				local value = buffer.readf64(source, offset)
					- dt
						* ((east - west) / grid.Dx + (north - south) / grid.Dz + (top - bottom) / grid.Dy)
				assert(
					finite(value) and (if name == "theta" then value > 0 else value >= 0),
					"World transport produced an invalid scalar; no clipping was applied"
				)
				buffer.writef64(destination, offset, value)
			end
		end
	end
end

return table.freeze(Advection)
