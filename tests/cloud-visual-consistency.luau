--!strict

return function(root: any, load: any, check: any, near: any, rejects: any, quick: boolean?)
	local Config = load(root.Rendering.CloudRenderConfig)
	local Detail = load(root.Rendering.CloudDetailNoise)
	local Lighting = load(root.Rendering.CloudLighting)
	local LOD = load(root.Rendering.CloudRenderLOD)
	local params = Detail.Create(84219)
	local summary = {}
	local previousCubes, previousDistance = 0, 0
	local Coordinates = load(root.World.WorldCoordinates)
	local Field = load(root.World.WeatherField)
	local authoritative = Field.new(Coordinates.new(), { SizeX = 4, SizeY = 3, SizeZ = 4 })
	local originalBuffers = {}
	for name, field in authoritative.Fields do
		originalBuffers[name] = buffer.tostring(field)
	end
	local originalTime, originalTick = authoritative.Time, authoritative.Tick
	for _, name in { "Mobile", "Balanced", "High", "Ultra" } do
		local quality = Config.GetQuality(name)
		check(
			quality.MaxCubes > previousCubes and quality.ViewDistance > previousDistance,
			"Quality presets progressively increase bounded visual budgets"
		)
		previousCubes, previousDistance = quality.MaxCubes, quality.ViewDistance
		check(
			quality.MaxCubes <= 1280 and quality.MaxClusters <= 96,
			"Visual resources remain capped in every quality"
		)
		check(
			quality.MaxCubeSize == 48
				and quality.NearSubdivisions == 4
				and quality.MediumSubdivisions <= 4
				and quality.FarSubdivisions <= 2,
			"Adaptive cubic subdivision has a bounded 48-stud root and 12-stud smallest detail"
		)
		check(
			quality.MaxPoolCubes == quality.MaxCubes + quality.MaxInactiveCubes,
			"Inactive cached objects have an explicit cap"
		)
		check(
			quality.MaxCreatesPerUpdate >= 6 and quality.MaxCreatesPerUpdate <= 16,
			"Instance construction is spread across updates"
		)
		check(
			quality.UpdateHz >= 5
				and quality.UpdateHz <= 12
				and quality.UpdateBudgetMilliseconds <= 5,
			"Client sampling is rate and time budget bounded"
		)
		check(
			quality.NoiseSamples >= 1 and quality.NoiseSamples <= 3 and quality.LightingSamples <= 3,
			"Per-cube noise and optical depth have fixed limits"
		)
		near(
			Detail.Sample(params, 10, 490, -2, 0.5, 0, quality),
			0,
			0,
			"All clients agree that an empty cloud is empty"
		)
		local level, samples, radius, priority = LOD.Decide(0, nil, quality)
		check(
			level == 1 and samples == quality.NearSubdivisions and radius == 1 and priority == 1,
			"Nearby clouds select detailed bounded sampling"
		)
		level, samples = LOD.Decide(quality.ViewDistance + 1, nil, quality)
		check(level == 0 and samples == 0, "Distant clouds are culled without atmospheric deletion")
		local edge = quality.ViewDistance * 0.25
		check(
			LOD.Decide(edge * 1.05, 1, quality) == 1,
			"Near LOD resists small outward camera movement"
		)
		check(
			LOD.Decide(edge * 0.95, 2, quality) == 2,
			"Medium LOD resists small inward camera movement"
		)
		check(
			LOD.Decide(edge * 1.13, 1, quality) == 2,
			"Near LOD eventually transitions after hysteresis"
		)
		check(
			LOD.Decide(edge * 0.87, 2, quality) == 1,
			"Medium LOD eventually transitions after hysteresis"
		)
		check(
			LOD.Decide(quality.ViewDistance * 0.95, 0, quality) == 0,
			"Recently culled clouds avoid distance-boundary flicker"
		)
		check(
			LOD.Decide(quality.ViewDistance * 0.85, 0, quality) ~= 0,
			"Culled clouds return when camera approaches"
		)
		local count = if quick then 60 else 200
		for index = 0, count do
			local density = index / count
			local value = Detail.Sample(params, 112, 470, -14, 0.5, density, quality)
			check(
				value >= 0 and value <= density,
				"Every quality expresses the same density support without invented liquid"
			)
		end
		summary[name] = {
			MaxCubes = quality.MaxCubes,
			MaxClusters = quality.MaxClusters,
			MaxPoolCubes = quality.MaxPoolCubes,
			MaxCreatesPerUpdate = quality.MaxCreatesPerUpdate,
			ViewDistance = quality.ViewDistance,
		}
	end
	for name, field in authoritative.Fields do
		check(
			buffer.tostring(field) == originalBuffers[name],
			"Choosing every client graphics quality leaves authoritative "
				.. name
				.. " bytes unchanged"
		)
	end
	near(authoritative.Time, originalTime, 0, "Visual settings cannot advance the physical clock")
	near(authoritative.Tick, originalTick, 0, "Visual settings cannot schedule atmospheric steps")
	near(Config.GetQuality("mObIlE").MaxCubes, 256, 0, "Quality command names are case insensitive")
	near(Config.GetQuality().MaxCubes, 512, 0, "Balanced is the non-mobile default")
	check(Config.DefaultMode == "Cubes", "Giant diagnostic voxels are not the gameplay default")
	for _, mode in { "Cubes", "Voxels", "HybridDebug", "Off" } do
		check(
			Config.ValidateMode(string.lower(mode)) == mode,
			"Render modes normalize validated local commands"
		)
	end
	check(
		Config.ValidateMode("smooth") == "Cubes",
		"Existing smooth commands select real cubic geometry"
	)
	check(
		Config.DefaultTexture == nil and Config.ValidateTexture == nil,
		"Cubic cloud graphics have no texture dependency"
	)
	rejects(function()
		Config.GetQuality("Maximum")
	end, "Invalid qualities are rejected")
	rejects(function()
		Config.ValidateMode("particleserver")
	end, "Invalid render modes are rejected")
	rejects(function()
		LOD.Decide(math.huge, nil, Config.GetQuality())
	end, "Infinite camera distances are rejected")
	rejects(function()
		LOD.Decide(0, 7, Config.GetQuality())
	end, "Invalid LOD history is rejected")

	local lowerSize, lowerCount, lowerShade, lowerSoft = Config.Layer(0)
	local upperSize, upperCount, upperShade, upperSoft = Config.Layer(1)
	near(lowerSize, 12, 0, "Nearby lower cloud detail starts at a 12-stud equal-axis cube")
	near(upperSize, 24, 0, "Upper cloud detail reaches a 24-stud equal-axis cube")
	check(
		lowerSize < upperSize and lowerCount > upperCount,
		"Lower detail is smaller and denser than broad upper cubes"
	)
	check(
		lowerShade < upperShade and lowerSoft < upperSoft,
		"Upper cube structure is brighter and softer"
	)
	for _, knot in { 0.25, 0.65 } do
		local beforeSize, beforeCount, beforeShade = Config.Layer(knot - 1e-6)
		local atSize, atCount, atShade = Config.Layer(knot)
		local afterSize, afterCount, afterShade = Config.Layer(knot + 1e-6)
		near(beforeSize, afterSize, 1e-9, "Layer size has no visible seam")
		near(beforeCount, afterCount, 1e-9, "Layer cube density has no visible seam")
		near(beforeShade, afterShade, 1e-9, "Layer illumination has no visible seam")
		near(
			(afterSize - atSize) / 1e-6,
			(atSize - beforeSize) / 1e-6,
			4e-5,
			"Layer size has matching derivative at artistic boundary"
		)
	end
	local layerBefore = Config.Layer(0.3)
	local layerAfter = Config.Layer(0.3, { LowerProportion = 0.35, MiddleProportion = 0.35 })
	check(
		layerBefore ~= layerAfter,
		"Layer proportions are configurable without changing physical height"
	)
	rejects(function()
		Config.Layer(0 / 0)
	end, "NaN cloud height is rejected")
	rejects(function()
		Config.Layer(0, { LowerProportion = 0.5, MiddleProportion = 0.6 })
	end, "Invalid artistic layer proportions are rejected")
	local lastSize, lastCount = -math.huge, math.huge
	local levels = if quick then 40 else 160
	for index = 0, levels do
		local h = index / levels
		local size, count = Config.Layer(h)
		check(
			size >= lastSize and count <= lastCount,
			"Layer distribution changes continuously from small dense bases to broad tops"
		)
		lastSize, lastCount = size, count
		for _, density in { 0, 0.2, 0.8, 1 } do
			local r, g, b =
				Lighting.Shade(density, h, 0, if h < 0.5 then 1 else -1, 0, 0.2, 0.9, 0.1, 0.5)
			check(
				r == r and r >= 0.24 and r <= 1 and r == g and r == b,
				"Approximate shading stays finite, neutral and bounded"
			)
		end
	end
	local underside = Lighting.Shade(0.8, 0, 0, 1, 0, 0, 1, 0, 0.5)
	local top = Lighting.Shade(0.8, 1, 0, -1, 0, 0, 1, 0, 0.5)
	check(
		top > underside and underside > 0.35,
		"Lighting produces brighter upper structure without a black cloud base"
	)
	local thinBase = Lighting.Shade(0.1, 0, 0, 1, 0, 0, 1, 0, 0.5)
	check(thinBase > underside, "Dense undersides receive more attenuation than thin ones")
	local extreme = Lighting.Shade(0.5, 0.5, 1e300, 1e300, 1e300, 1e300, 1e300, 1e300, 0.5)
	check(
		extreme == extreme and extreme >= 0.24,
		"Scaled gradient normalization avoids floating-point overflow"
	)
	local calls = 0
	local function uniform(_x: number, _y: number, _z: number): number
		calls += 1
		return 0.5
	end
	near(
		Lighting.OpticalDepth(uniform, 0, 0, 0, 0, 1, 0, 40, 3),
		0.6,
		1e-14,
		"Optical depth is explicitly a low-sample display attenuation proxy"
	)
	near(calls, 3, 0, "Optical depth samples obey the hard cap")
	near(
		Lighting.OpticalDepth(uniform, 0, 0, 0, 0, 1, 0, 40, 0),
		0,
		0,
		"Cheap quality can skip integration"
	)
	near(calls, 3, 0, "Disabled lighting integration calls no density sampler")
	rejects(function()
		Lighting.OpticalDepth(uniform, 0, 0, 0, 0, 1, 0, 40, 4)
	end, "Unbounded per-cube light sampling is rejected")
	rejects(function()
		Lighting.Shade(0 / 0, 0, 0, 0, 0, 0, 1, 0, 1)
	end, "NaN shading inputs are rejected")
	return {
		Presets = summary,
		Layers = { Lower = 0.25, Middle = 0.4, Upper = 0.35 },
		OpticalSamplesMaximum = 3,
		LightingIsVolumetricScattering = false,
	}
end
