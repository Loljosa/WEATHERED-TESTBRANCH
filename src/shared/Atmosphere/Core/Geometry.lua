--!strict

local Grid3D = require(script.Parent.Grid3D)

local Geometry = {}

export type Geometry = {
	Grid: Grid3D.Grid3D,
	Count: number,
	Plane: number,
	Dx: number,
	Dy: number,
	Dz: number,
	Xp: buffer,
	Xm: buffer,
	Yp: buffer,
	Ym: buffer,
	Zp: buffer,
	Zm: buffer,
}

-- Cached CELL neighbors store zero-based indices as uint32. Buffer byte offsets
-- are index*4. Horizontal X/Z boundaries are periodic; sealed Y wall neighbors
-- refer to the boundary cell itself. Face operators supply their own zero wall flux.
function Geometry.new(grid: Grid3D.Grid3D): Geometry
	assert(grid.Count < 4294967296, "Geometry count exceeds uint32 neighbor indexing")
	local count = grid.Count
	local plane = grid.SizeX * grid.SizeZ
	local geometry: Geometry = {
		Grid = grid,
		Count = count,
		Plane = plane,
		Dx = grid.Dx,
		Dy = grid.Dy,
		Dz = grid.Dz,
		Xp = buffer.create(count * 4),
		Xm = buffer.create(count * 4),
		Yp = buffer.create(count * 4),
		Ym = buffer.create(count * 4),
		Zp = buffer.create(count * 4),
		Zm = buffer.create(count * 4),
	}
	for y = 0, grid.SizeY - 1 do
		for z = 0, grid.SizeZ - 1 do
			for x = 0, grid.SizeX - 1 do
				local index = y * plane + z * grid.SizeX + x
				local offset = index * 4
				buffer.writeu32(
					geometry.Xp,
					offset,
					if x + 1 < grid.SizeX then index + 1 else index - grid.SizeX + 1
				)
				buffer.writeu32(
					geometry.Xm,
					offset,
					if x > 0 then index - 1 else index + grid.SizeX - 1
				)
				buffer.writeu32(
					geometry.Yp,
					offset,
					if y + 1 < grid.SizeY then index + plane else index
				)
				buffer.writeu32(geometry.Ym, offset, if y > 0 then index - plane else index)
				buffer.writeu32(
					geometry.Zp,
					offset,
					if z + 1 < grid.SizeZ then index + grid.SizeX else index - plane + grid.SizeX
				)
				buffer.writeu32(
					geometry.Zm,
					offset,
					if z > 0 then index - grid.SizeX else index + plane - grid.SizeX
				)
			end
		end
	end
	return table.freeze(geometry)
end

return table.freeze(Geometry)
