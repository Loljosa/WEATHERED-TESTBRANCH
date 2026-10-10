--!native
--!strict

local SeededNoise = require(script.Parent.SeededNoise)

local CloudHeightmaps = {}
export type NoiseConfiguration = {
	XZ: SeededNoise.Parameters,
	XY: SeededNoise.Parameters,
	YZ: SeededNoise.Parameters,
	Structure: SeededNoise.Parameters,
	Warp: SeededNoise.Parameters,
	DomainWarpAmplitude: number,
}
export type Source = {
	Id: string,
	Seed: number,
	WorldSeed: number,
	EventIndex: number,
	GenerationTick: number,
	X: number,
	Y: number,
	Z: number,
	RadiusX: number,
	RadiusY: number,
	RadiusZ: number,
	BaseAltitude: number,
	TopAltitude: number,
	TemperaturePerturbation: number, -- potential-temperature excess, K
	MoisturePerturbation: number, -- upper vapor increment, kg/kg (not painted qc)
	TargetRelativeHumidity: number, -- vapor target fraction at perturbed theta
	Intensity: number, -- source weight, dimensionless
	Kind: string,
	Noise: NoiseConfiguration,
}

-- dx/dy/dz are local coordinates normalized by the source's physical radii.
-- These three independently seeded planes constrain one continuous 3D source;
-- they do not allocate sampled heightmap tables or create visual cloud mass.
function CloudHeightmaps.Sample(
	source: Source,
	dx: number,
	dy: number,
	dz: number
): (number, number, number, number, number)
	local xz = SeededNoise.Fractal2D(source.Noise.XZ, dx * 1.2, dz * 1.2, 2)
	local top = SeededNoise.Sample2D(source.Noise.XZ, dx * 0.8 + 3.75, dz * 0.8 - 5.5)
	local xy = SeededNoise.Fractal2D(source.Noise.XY, dx * 1.1, dy * 0.9, 2)
	local yz = SeededNoise.Fractal2D(source.Noise.YZ, dy * 0.9, dz * 1.1, 2)
	local footprint = 1 + 0.16 * xz
	-- Bounds move inward from the descriptor's envelope: altitude assertions
	-- remain true even where both surfaces are irregular and asymmetric.
	local baseOffset = 0.11 + 0.07 * xz
	local topOffset = 0.11 + 0.08 * top
	local sideWidth = 1 + 0.14 * xy
	local depth = 1 + 0.14 * yz
	return footprint, baseOffset, topOffset, sideWidth, depth
end

return table.freeze(CloudHeightmaps)
