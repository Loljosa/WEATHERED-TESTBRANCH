--!strict

-- Client graphics settings never select a server grid or alter atmospheric water.
local Config = {}
export type Quality = {
	Name: string,
	MaxCubes: number,
	MaxClusters: number,
	MaxPoolCubes: number,
	MaxInactiveCubes: number,
	MaxCubeSize: number,
	MaxCreatesPerUpdate: number,
	MaxUpdatesPerUpdate: number,
	UpdateHz: number,
	ViewDistance: number,
	UpdateBudgetMilliseconds: number,
	NoiseSamples: number,
	LightingSamples: number,
	NearSubdivisions: number,
	MediumSubdivisions: number,
	FarSubdivisions: number,
}
export type LayerSettings = { LowerProportion: number, MiddleProportion: number }

Config.DefaultMode = "Cubes"
Config.DefaultQuality = "Balanced"
Config.DefaultLayers = table.freeze({ LowerProportion = 0.25, MiddleProportion = 0.40 })

local qualities: { [string]: Quality } = {
	Mobile = {
		Name = "Mobile",
		MaxCubes = 256,
		MaxClusters = 32,
		MaxPoolCubes = 288,
		MaxInactiveCubes = 32,
		MaxCubeSize = 48,
		MaxCreatesPerUpdate = 6,
		MaxUpdatesPerUpdate = 64,
		UpdateHz = 5,
		ViewDistance = 1500,
		UpdateBudgetMilliseconds = 2,
		NoiseSamples = 1,
		LightingSamples = 0,
		NearSubdivisions = 4,
		MediumSubdivisions = 2,
		FarSubdivisions = 1,
	},
	Balanced = {
		Name = "Balanced",
		MaxCubes = 512,
		MaxClusters = 48,
		MaxPoolCubes = 576,
		MaxInactiveCubes = 64,
		MaxCubeSize = 48,
		MaxCreatesPerUpdate = 8,
		MaxUpdatesPerUpdate = 96,
		UpdateHz = 8,
		ViewDistance = 2200,
		UpdateBudgetMilliseconds = 3,
		NoiseSamples = 2,
		LightingSamples = 0,
		NearSubdivisions = 4,
		MediumSubdivisions = 3,
		FarSubdivisions = 1,
	},
	High = {
		Name = "High",
		MaxCubes = 768,
		MaxClusters = 64,
		MaxPoolCubes = 864,
		MaxInactiveCubes = 96,
		MaxCubeSize = 48,
		MaxCreatesPerUpdate = 12,
		MaxUpdatesPerUpdate = 128,
		UpdateHz = 10,
		ViewDistance = 3000,
		UpdateBudgetMilliseconds = 4,
		NoiseSamples = 3,
		LightingSamples = 2,
		NearSubdivisions = 4,
		MediumSubdivisions = 4,
		FarSubdivisions = 2,
	},
	Ultra = {
		Name = "Ultra",
		MaxCubes = 1280,
		MaxClusters = 96,
		MaxPoolCubes = 1408,
		MaxInactiveCubes = 128,
		MaxCubeSize = 48,
		MaxCreatesPerUpdate = 16,
		MaxUpdatesPerUpdate = 192,
		UpdateHz = 12,
		ViewDistance = 5000,
		UpdateBudgetMilliseconds = 5,
		NoiseSamples = 3,
		LightingSamples = 3,
		NearSubdivisions = 4,
		MediumSubdivisions = 4,
		FarSubdivisions = 2,
	},
}
for _, quality in qualities do
	table.freeze(quality)
end
table.freeze(qualities)

local function finite(value: number)
	assert(value == value and math.abs(value) < math.huge, "Cloud layer values must be finite")
end

function Config.GetQuality(name: string?): Quality
	local selected = string.lower(name or Config.DefaultQuality)
	for key, quality in qualities do
		if string.lower(key) == selected then
			return quality
		end
	end
	error("Cloud quality must be Mobile, Balanced, High, or Ultra", 2)
end

function Config.ValidateMode(value: string): string
	assert(type(value) == "string", "Cloud rendering mode must be a string")
	local selected = string.lower(value)
	if selected == "smooth" then
		return "Cubes" -- Existing developer commands select the new 3D renderer.
	end
	for _, mode in { "Cubes", "Voxels", "HybridDebug", "Off" } do
		if selected == string.lower(mode) then
			return mode
		end
	end
	error("Cloud rendering mode must be Cubes (or Smooth), Voxels, HybridDebug, or Off", 2)
end

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

-- All channels have matching value and zero slope at their artistic knots: no
-- discontinuous layer bands. h must use the local column's liquid base/top.
-- Returns desired equal-axis cube side in STUDS, sample-density multiplier,
-- illumination and edge-softness factors. This never stretches the atmosphere.
function Config.Layer(height: number, settings: LayerSettings?): (number, number, number, number)
	finite(height)
	local selected = settings or Config.DefaultLayers
	local lower, middle = selected.LowerProportion, selected.MiddleProportion
	finite(lower)
	finite(middle)
	assert(
		lower >= 0.05 and middle >= 0.05 and lower + middle <= 0.95,
		"Cloud layer proportions need lower/middle >= 0.05 and upper >= 0.05"
	)
	local h = math.clamp(height, 0, 1)
	local segment, t
	if h < lower then
		segment, t = 0, smooth(h / lower)
	elseif h < lower + middle then
		segment, t = 1, smooth((h - lower) / middle)
	else
		segment, t = 2, smooth((h - lower - middle) / (1 - lower - middle))
	end
	-- No property table or captured closure is allocated per cube.
	if segment == 0 then
		return 12 + 2 * t, 1.55 - 0.37 * t, 0.74 + 0.11 * t, 0.80 + 0.08 * t
	elseif segment == 1 then
		return 14 + 6 * t, 1.18 - 0.30 * t, 0.85 + 0.12 * t, 0.88 + 0.08 * t
	end
	return 20 + 4 * t, 0.88 - 0.24 * t, 0.97 + 0.07 * t, 0.96 + 0.09 * t
end

return table.freeze(Config)
