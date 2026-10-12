--!strict

local SeededNoise = require(script.Parent.Parent.Generation.SeededNoise)
local WorldSeed = require(script.Parent.Parent.Generation.WorldSeed)
local Config = require(script.Parent.CloudRenderConfig)

local Detail = {}
export type Parameters = {
	Seed: number,
	Broad: SeededNoise.Parameters,
	Contour: SeededNoise.Parameters,
	Fine: SeededNoise.Parameters,
}
local UINT32 = 4294967296

local function finite(value: number)
	assert(value == value and math.abs(value) < math.huge, "Cloud detail input must be finite")
end

function Detail.Create(seed: number): Parameters
	WorldSeed.Validate(seed)
	return table.freeze({
		Seed = WorldSeed.Derive(seed, "cloud-visual-placement"),
		Broad = SeededNoise.Create(seed, "cloud-visual-broad"),
		Contour = SeededNoise.Create(seed, "cloud-visual-contour"),
		Fine = SeededNoise.Create(seed, "cloud-visual-fine"),
	})
end

-- Density is a normalized display quantity. Noise only removes/modulates
-- existing reconstructed support: it never adds liquid or creates an island.
-- Coordinates are studs, independent of camera and logical region identity.
-- Cache this result per stable candidate; never evaluate per pixel/frame.
function Detail.Sample(
	parameters: Parameters,
	x: number,
	y: number,
	z: number,
	height: number,
	density: number,
	quality: Config.Quality
): number
	finite(x)
	finite(y)
	finite(z)
	finite(height)
	finite(density)
	assert(density >= 0 and density <= 1, "Visual density must be normalized to 0..1")
	if density == 0 then
		return 0
	end
	local broad = SeededNoise.Sample3D(parameters.Broad, x / 240, y / 160, z / 240)
	local contour = if quality.NoiseSamples >= 2
		then SeededNoise.Sample3D(parameters.Contour, x / 72, y / 52, z / 72)
		else broad
	local fine = if quality.NoiseSamples >= 3
		then SeededNoise.Sample3D(parameters.Fine, x / 23, y / 19, z / 23)
		else contour
	local noise = 0.58 * broad + 0.30 * contour + 0.12 * fine
	-- Thin edges get stronger breakup; dense interiors retain coherent support.
	local edge = (1 - density) * (1 - density)
	local amplitude = 0.16 + 0.34 * edge
	local attenuation = 1 - amplitude * (0.5 + 0.5 * noise)
	return density * attenuation
end

local function randomChannel(
	seed: number,
	identity: number,
	ordinal: number,
	channel: number
): number
	local hash = WorldSeed.Hash(
		bit32.bxor(seed, WorldSeed.Hash(identity % UINT32), WorldSeed.Hash(ordinal), channel)
	)
	return hash / UINT32
end

-- Stable candidate IDs are global lattice IDs, not player or streamed region IDs.
-- Returns normalized offsets (-.42..+.42), rotation (degrees), size multiplier.
function Detail.Offsets(
	parameters: Parameters,
	spatialId: number,
	cubeOrdinal: number
): (number, number, number, number, number)
	finite(spatialId)
	assert(
		spatialId % 1 == 0 and math.abs(spatialId) <= 9007199254740991,
		"Cloud spatial ID must be an exact integer"
	)
	assert(
		cubeOrdinal >= 1 and cubeOrdinal <= 65535 and cubeOrdinal % 1 == 0,
		"Cloud cube ordinal must be 1..65535"
	)
	local seed = parameters.Seed
	return (randomChannel(seed, spatialId, cubeOrdinal, 11) - 0.5) * 0.84,
		(randomChannel(seed, spatialId, cubeOrdinal, 23) - 0.5) * 0.84,
		(randomChannel(seed, spatialId, cubeOrdinal, 47) - 0.5) * 0.84,
		randomChannel(seed, spatialId, cubeOrdinal, 83) * 360,
		0.78 + randomChannel(seed, spatialId, cubeOrdinal, 127) * 0.44
end

return table.freeze(Detail)
