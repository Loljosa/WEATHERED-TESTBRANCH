--!strict

local WorldSeed = require(script.Parent.WorldSeed)
local SeededNoise = require(script.Parent.SeededNoise)
local CloudHeightmaps = require(script.Parent.CloudHeightmaps)
local CloudDensityField = require(script.Parent.CloudDensityField)

local CloudSourceGenerator = {}
export type Region = CloudDensityField.Region
export type Source = CloudHeightmaps.Source
export type Settings = {
	GenerationTick: number?,
	Intensity: number?,
	TemperaturePerturbation: number?,
	TargetRelativeHumidity: number?,
	MoisturePerturbation: number?,
	Kind: string?,
	DomainWarpAmplitude: number?,
}
local KINDS = table.freeze({ "Compact", "Broad", "Broken", "Tower" })

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

function CloudSourceGenerator.ValidateRegion(region: Region)
	for _, key in { "OriginX", "OriginY", "OriginZ", "SizeX", "SizeY", "SizeZ", "Dx", "Dy", "Dz" } do
		assert(
			finite((region :: any)[key]),
			"Source region must contain finite meter geometry: " .. key
		)
	end
	assert(
		region.Dx > 0 and region.Dy > 0 and region.Dz > 0,
		"Source grid spacing must be positive meters"
	)
	assert(
		finite(region.OriginX + region.SizeX)
			and finite(region.OriginY + region.SizeY)
			and finite(region.OriginZ + region.SizeZ),
		"Source region world-coordinate bounds must remain finite"
	)
	assert(
		region.SizeX >= 5 * region.Dx
			and region.SizeZ >= 5 * region.Dz
			and region.SizeY >= 5 * region.Dy,
		"Source region requires at least five cells per axis to resolve smooth formations"
	)
end

function CloudSourceGenerator.Generate(
	seed: number,
	eventIndex: number,
	region: Region,
	settings: Settings?
): Source
	WorldSeed.Validate(seed)
	CloudSourceGenerator.ValidateRegion(region)
	local options = settings or {}
	local stream = string.format(
		"cloud:%.17g:%.17g:%.17g:%.17g:%.17g:%.17g",
		region.OriginX,
		region.OriginY,
		region.OriginZ,
		region.SizeX,
		region.SizeY,
		region.SizeZ
	)
	local sourceSeed = WorldSeed.Derive(seed, stream, eventIndex)
	local function unit(label: string): number
		return WorldSeed.Hash(WorldSeed.Derive(sourceSeed, label)) / 4294967296
	end
	local kind = options.Kind or KINDS[math.floor(unit("kind") * #KINDS) + 1]
	assert(
		table.find(KINDS, kind) ~= nil,
		"Cloud source Kind must be Compact, Broad, Broken or Tower"
	)
	local intensity = options.Intensity or (0.85 + 0.15 * unit("intensity"))
	local temperature = options.TemperaturePerturbation or (5 + 2 * unit("temperature"))
	local rh = options.TargetRelativeHumidity or 0.9999
	local moisture = options.MoisturePerturbation or (0.018 + 0.004 * unit("moisture"))
	local generationTick = options.GenerationTick or 0
	local warp = options.DomainWarpAmplitude or 0
	assert(
		finite(intensity) and intensity > 0 and intensity <= 1,
		"Source Intensity must be in (0,1]"
	)
	assert(
		finite(temperature) and temperature >= 0 and temperature <= 7,
		"Source temperature perturbation must be 0..7 K"
	)
	assert(finite(rh) and rh > 0 and rh <= 1, "Source RH must be in (0,1]")
	assert(
		finite(moisture) and moisture >= 0 and moisture <= 0.03,
		"Source moisture increment must be 0..0.03 kg/kg"
	)
	assert(
		generationTick % 1 == 0 and generationTick >= 0 and generationTick <= 2147483647,
		"Generation tick must be a bounded nonnegative integer"
	)
	assert(
		finite(warp) and warp >= 0 and warp <= 0.08,
		"Domain warp amplitude must be 0..0.08 source radii"
	)
	local broad = kind == "Broad" or kind == "Broken"
	local radiusX = math.max(
		2 * region.Dx,
		region.SizeX * (if broad then 0.22 else 0.15) * (0.9 + 0.35 * unit("radius-x"))
	)
	local radiusZ = math.max(
		2 * region.Dz,
		region.SizeZ * (if broad then 0.2 else 0.14) * (0.9 + 0.35 * unit("radius-z"))
	)
	radiusX = math.min(radiusX, region.SizeX * 0.4)
	radiusZ = math.min(radiusZ, region.SizeZ * 0.4)
	local available = region.SizeY - 2 * region.Dy
	local thickness = math.min(
		available,
		math.max(
			3 * region.Dy,
			(if kind == "Tower" then 600 else 380) * (0.9 + 0.3 * unit("thickness"))
		)
	)
	local base = region.OriginY
		+ region.Dy
		+ math.min(0.5 * region.Dy + 90 * unit("base"), available - thickness)
	local top = base + thickness
	local noise: CloudHeightmaps.NoiseConfiguration = table.freeze({
		XZ = SeededNoise.Create(sourceSeed, "heightmap-xz"),
		XY = SeededNoise.Create(sourceSeed, "heightmap-xy"),
		YZ = SeededNoise.Create(sourceSeed, "heightmap-yz"),
		Structure = SeededNoise.Create(sourceSeed, "cloud-3d"),
		Warp = SeededNoise.Create(sourceSeed, "domain-warp"),
		DomainWarpAmplitude = warp,
	})
	return table.freeze({
		Id = string.format("cloud:%d:%d:%d", seed, eventIndex, sourceSeed),
		Seed = sourceSeed,
		WorldSeed = seed,
		EventIndex = eventIndex,
		GenerationTick = generationTick,
		X = region.OriginX + region.SizeX * unit("position-x"),
		Y = (base + top) * 0.5,
		Z = region.OriginZ + region.SizeZ * unit("position-z"),
		RadiusX = radiusX,
		RadiusY = thickness * 0.5,
		RadiusZ = radiusZ,
		BaseAltitude = base,
		TopAltitude = top,
		TemperaturePerturbation = temperature,
		MoisturePerturbation = moisture,
		TargetRelativeHumidity = rh,
		Intensity = intensity,
		Kind = kind,
		Noise = noise,
	})
end

return table.freeze(CloudSourceGenerator)
