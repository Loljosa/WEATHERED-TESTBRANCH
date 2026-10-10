--!native
--!strict

local CloudHeightmaps = require(script.Parent.CloudHeightmaps)
local SeededNoise = require(script.Parent.SeededNoise)

local CloudDensityField = {}
export type Region = {
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

local function smoothEdge(value: number, core: number): number
	if value <= core then
		return 1
	elseif value >= 1 then
		return 0
	end
	local t = (value - core) / (1 - core)
	return 1 - t * t * (3 - 2 * t)
end

function CloudDensityField.Sample(
	source: CloudHeightmaps.Source,
	x: number,
	y: number,
	z: number,
	region: Region
): number
	assert(
		x == x
			and y == y
			and z == z
			and math.abs(x) < math.huge
			and math.abs(y) < math.huge
			and math.abs(z) < math.huge,
		"Source coordinates must be finite physical meters"
	)
	assert(
		region.SizeX > 0
			and region.SizeX < math.huge
			and region.SizeZ > 0
			and region.SizeZ < math.huge,
		"Periodic source region extents must be positive finite meters"
	)
	if y <= source.BaseAltitude or y >= source.TopAltitude then
		return 0
	end
	-- The minimum image is compatible with the solver's lateral periodicity.
	-- Source support is strictly smaller than half a domain: this coordinate's
	-- cusp is outside nonzero support, keeping the whole field continuous.
	local dx = ((x - source.X + region.SizeX * 0.5) % region.SizeX - region.SizeX * 0.5)
		/ source.RadiusX
	local dz = ((z - source.Z + region.SizeZ * 0.5) % region.SizeZ - region.SizeZ * 0.5)
		/ source.RadiusZ
	local dy = (y - source.Y) / source.RadiusY
	local envelopeRadius = math.sqrt(dx * dx + dz * dz)
	if envelopeRadius >= 1 then
		return 0
	end
	local warpAmplitude = source.Noise.DomainWarpAmplitude
	if warpAmplitude > 0 then
		local warp = SeededNoise.Sample3D(source.Noise.Warp, dx * 0.6, dy * 0.6, dz * 0.6)
			* warpAmplitude
		dx += warp
		dz -= warp * 0.75
	end
	local footprint, baseInset, topInset, sideWidth, depth =
		CloudHeightmaps.Sample(source, dx, dy, dz)
	local lower = source.BaseAltitude + baseInset * source.RadiusY
	local upper = source.TopAltitude - topInset * source.RadiusY
	local height = (y - (lower + upper) * 0.5) / ((upper - lower) * 0.5)
	if math.abs(height) >= 1 then
		return 0
	end
	local structure = SeededNoise.Fractal3D(source.Noise.Structure, dx * 0.9, dy * 0.9, dz * 0.9, 3)
	-- Broad/middle/edge octaves influence contours by at most 12%. A broad core
	-- and smooth shoulder prevent high-frequency noise creating isolated cells.
	local contour = 1 + (if source.Kind == "Broken" then 0.24 else 0.12) * structure
	local radial = math.sqrt((dx / sideWidth) ^ 2 + (dz / depth) ^ 2) / (footprint * contour)
	local vertical = smoothEdge(math.abs(height), 0.42)
	local horizontal = smoothEdge(radial, if source.Kind == "Broad" then 0.55 else 0.5)
	return horizontal * vertical * smoothEdge(envelopeRadius, 0.65)
end

return table.freeze(CloudDensityField)
