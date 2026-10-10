--!strict

-- Execute the production deterministic geometry independently of mutable fluids.
return function(root: any, loadModule: any, check: any, near: any, rejects: any)
	local WorldSeed = loadModule(root.Generation.WorldSeed)
	local Noise = loadModule(root.Generation.SeededNoise)
	local Heightmaps = loadModule(root.Generation.CloudHeightmaps)
	local Density = loadModule(root.Generation.CloudDensityField)
	local Generator = loadModule(root.Generation.CloudSourceGenerator)
	local region = {
		OriginX = -1200,
		OriginY = 0,
		OriginZ = -1200,
		SizeX = 2400,
		SizeY = 1200,
		SizeZ = 2400,
		Dx = 200,
		Dy = 100,
		Dz = 200,
	}
	local function equal(a: any, b: any): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for key, value in a do
			if not equal(value, b[key]) then
				return false
			end
		end
		for key in b do
			if a[key] == nil then
				return false
			end
		end
		return true
	end
	local function finite(value: number): boolean
		return value == value and math.abs(value) < math.huge
	end
	-- Independent arbitrary-precision Python uint32 arithmetic generated these
	-- vectors. They catch precision loss from direct 32-bit multiplication.
	for _, vector in
		{
			{ -2147483648, 596721352 },
			{ -84219, -1502056742 },
			{ 0, 1583315257 },
			{ 84219, -479685378 },
			{ 2147483647, 191581006 },
		}
	do
		near(
			WorldSeed.Derive(vector[1], "weather", 0),
			vector[2],
			0,
			"Seed hash matches independently calculated uint32 vectors"
		)
	end
	for _, seed in { -2147483648, -84219, -1, 0, 1, 84219, 2147483647 } do
		near(
			WorldSeed.Validate(seed),
			seed,
			0,
			"World seed preserves signed integer including zero"
		)
		local canonical, reason = WorldSeed.Resolve(seed, 123)
		near(canonical, seed, 0, "Canonical world seed takes precedence over development fallback")
		check(
			string.find(reason, "canonical", 1, true) ~= nil,
			"Seed adapter reports canonical provenance"
		)
		local fallback = WorldSeed.Resolve(nil, seed)
		near(fallback, seed, 0, "Development fallback preserves zero and negative seeds")
		local weather = WorldSeed.Derive(seed, "weather", 0)
		near(weather, WorldSeed.Derive(seed, "weather", 0), 0, "Subseed derivation is repeatable")
		check(
			weather ~= WorldSeed.Derive(seed, "terrain", 0),
			"Weather and terrain streams are independent"
		)
		check(
			weather ~= WorldSeed.Derive(seed, "weather", 1),
			"Event index selects an independent deterministic stream"
		)
		WorldSeed.Validate(weather)
		for event = 0, 11 do
			local source = Generator.Generate(seed, event, region, { GenerationTick = event * 480 })
			check(
				equal(
					source,
					Generator.Generate(seed, event, region, { GenerationTick = event * 480 })
				),
				"Same seed/settings/region/event reproduces every source parameter"
			)
			check(
				table.isfrozen(source)
					and table.isfrozen(source.Noise)
					and table.isfrozen(source.Noise.XZ),
				"Generation descriptors and cached noise parameters are immutable"
			)
			check(
				source.WorldSeed == seed
					and source.EventIndex == event
					and source.GenerationTick == event * 480,
				"Source records world seed, event and simulation generation tick"
			)
			check(
				source.X >= region.OriginX and source.X < region.OriginX + region.SizeX,
				"Source X lies inside the physical world region"
			)
			check(
				source.Z >= region.OriginZ and source.Z < region.OriginZ + region.SizeZ,
				"Source Z lies inside the physical world region"
			)
			check(
				source.BaseAltitude >= region.OriginY + region.Dy
					and source.TopAltitude <= region.OriginY + region.SizeY - region.Dy + 1e-9,
				"Source altitudes leave sealed boundary layers clear"
			)
			check(
				source.RadiusX >= 2 * region.Dx
					and source.RadiusZ >= 2 * region.Dz
					and source.RadiusY >= 1.5 * region.Dy,
				"Source features span multiple coarse simulation cells"
			)
			check(
				source.TemperaturePerturbation >= 5 and source.TemperaturePerturbation <= 7,
				"Default source has a bounded warm perturbation in kelvin"
			)
			check(
				source.MoisturePerturbation >= 0.018 and source.MoisturePerturbation <= 0.022,
				"Default vapor increment ceiling is stated in kg/kg"
			)
			check(
				source.Intensity >= 0.85 and source.Intensity <= 1,
				"Default formation intensity is bounded"
			)
			near(
				source.TargetRelativeHumidity,
				0.9999,
				0,
				"Cloud source targets near saturation without directly seeding cloud water"
			)
			check(
				source.qc == nil and source.CloudWater == nil,
				"Source descriptor contains no painted cloud water"
			)
			near(
				Density.Sample(source, source.X, source.BaseAltitude, source.Z, region),
				0,
				0,
				"Source geometry vanishes at lower envelope"
			)
			near(
				Density.Sample(source, source.X, source.TopAltitude, source.Z, region),
				0,
				0,
				"Source geometry vanishes at upper envelope"
			)
			check(
				Density.Sample(source, source.X, source.Y, source.Z, region) > 0.95,
				"Resolved source has a broad coherent core"
			)
			near(
				Density.Sample(source, source.X + source.RadiusX, source.Y, source.Z, region),
				0,
				1e-12,
				"Source geometry vanishes outside its horizontal envelope"
			)
		end
	end
	local fallback, fallbackReason = WorldSeed.Resolve(nil, nil)
	near(fallback, 84219, 0, "Missing terrain adapter selects documented development seed")
	check(
		string.find(fallbackReason, "fallback", 1, true) ~= nil,
		"Seed adapter labels missing terrain integration"
	)
	for _, seed in { -2147483649, 2147483648, 0.5, math.huge, 0 / 0, "84219", false } do
		rejects(function()
			WorldSeed.Validate(seed)
		end, "Invalid canonical seed is rejected")
		rejects(function()
			WorldSeed.Resolve(seed, 84219)
		end, "Malformed canonical seed cannot silently select fallback")
	end
	for _, event in { -1, 0.5, math.huge, 2147483648 } do
		rejects(function()
			WorldSeed.Derive(84219, "source", event)
		end, "Subseed event index is bounded and integer")
	end
	rejects(function()
		WorldSeed.Derive(1, "")
	end, "Independent seed stream must be named")
	local baseline = Generator.Generate(84219, 0, region)
	local different = Generator.Generate(-84219, 0, region)
	check(
		baseline.Id ~= different.Id and (baseline.X ~= different.X or baseline.Z ~= different.Z),
		"Different signed world seeds produce different distributions"
	)
	local kinds: { [string]: boolean } = {}
	for event = 0, 31 do
		kinds[Generator.Generate(84219, event, region).Kind] = true
	end
	check(
		kinds.Compact and kinds.Broad and kinds.Broken and kinds.Tower,
		"Seeded event stream produces all four varied formation families"
	)
	local shifted = table.clone(region)
	shifted.OriginX += region.SizeX
	check(
		Generator.Generate(84219, 0, shifted).Id ~= baseline.Id,
		"Future world regions select independent deterministic source streams"
	)
	for _, kind in { "Compact", "Broad", "Broken", "Tower" } do
		local source = Generator.Generate(
			84219,
			9,
			region,
			{ Kind = kind, DomainWarpAmplitude = 0.06, Intensity = 1 }
		)
		local support: { boolean } = {}
		for y = 1, 12 do
			for z = 1, 12 do
				for x = 1, 12 do
					local index = (y - 1) * 144 + (z - 1) * 12 + x
					support[index] = Density.Sample(
						source,
						region.OriginX + (x - 0.5) * region.Dx,
						region.OriginY + (y - 0.5) * region.Dy,
						region.OriginZ + (z - 0.5) * region.Dz,
						region
					) > 0.01
				end
			end
		end
		for y = 1, 12 do
			for z = 1, 12 do
				for x = 1, 12 do
					local index = (y - 1) * 144 + (z - 1) * 12 + x
					if support[index] then
						local left = (y - 1) * 144 + (z - 1) * 12 + (x - 2) % 12 + 1
						local right = (y - 1) * 144 + (z - 1) * 12 + x % 12 + 1
						local front = (y - 1) * 144 + (z - 2) % 12 * 12 + x
						local rear = (y - 1) * 144 + z % 12 * 12 + x
						check(
							support[left]
								or support[right]
								or support[front]
								or support[rear]
								or support[index - 144]
								or support[index + 144],
							"Coarse source support has no disconnected single-cell noise artifacts"
						)
					end
				end
			end
		end
		for y = 0, 12 do
			for z = 0, 12 do
				for x = 0, 12 do
					local px = region.OriginX + x * region.Dx
					local py = region.OriginY + y * region.Dy
					local pz = region.OriginZ + z * region.Dz
					local value = Density.Sample(source, px, py, pz, region)
					check(
						finite(value) and value >= 0 and value <= 1,
						"Three-plane warped procedural source weight is finite and bounded"
					)
					near(
						value,
						Density.Sample(source, px, py, pz, region),
						0,
						"World-coordinate sampling is deterministic"
					)
					near(
						value,
						Density.Sample(source, px + region.SizeX, py, pz - region.SizeZ, region),
						1e-12,
						"Source sampling respects periodic X/Z world coordinates"
					)
				end
			end
		end
		for z = 0, 24 do
			local pz = region.OriginZ + z * 100
			near(
				Density.Sample(source, region.OriginX - 0.0001, source.Y, pz, region),
				Density.Sample(source, region.OriginX + 0.0001, source.Y, pz, region),
				1e-5,
				"Periodic world seam has continuous source density"
			)
		end
		for x = 0, 24 do
			local px = region.OriginX + x * 100
			near(
				Density.Sample(source, px, source.Y, region.OriginZ - 0.0001, region),
				Density.Sample(source, px, source.Y, region.OriginZ + 0.0001, region),
				1e-5,
				"Periodic Z world seam has continuous source density"
			)
		end
		near(
			Density.Sample(source, source.X + region.SizeX * 0.5, source.Y, source.Z, region),
			0,
			0,
			"Minimum-image coordinate cusp lies outside source support"
		)
		local footprint, base, top, side, depth = Heightmaps.Sample(source, 0.25, -0.3, 0.4)
		check(
			footprint >= 0.84
				and footprint <= 1.16
				and base >= 0.04
				and base <= 0.18
				and top >= 0.03
				and top <= 0.19
				and side >= 0.86
				and side <= 1.14
				and depth >= 0.86
				and depth <= 1.14,
			"XZ/XY/YZ planes retain bounded geometric parameters"
		)
		local fpY, baseY, topY = Heightmaps.Sample(source, 0.25, 0.6, 0.4)
		near(fpY, footprint, 0, "XZ footprint is independent of Y")
		near(baseY, base, 0, "XZ cloud base is independent of Y")
		near(topY, top, 0, "XZ cloud top is independent of Y")
		local _, _, _, sideZ = Heightmaps.Sample(source, 0.25, -0.3, -0.8)
		near(sideZ, side, 0, "XY side heightmap is independent of Z")
		local _, _, _, _, depthX = Heightmaps.Sample(source, -0.8, -0.3, 0.4)
		near(depthX, depth, 0, "YZ depth heightmap is independent of X")
		local _, base2, top2 = Heightmaps.Sample(source, -0.8, -0.3, 0.7)
		check(
			base ~= base2 and top ~= top2 and (base - base2) ~= (top - top2),
			"Cloud base and top vary independently instead of being parallel flat planes"
		)
		for coordinate = -10, 10 do
			local px = source.X + coordinate * source.RadiusX / 10
			near(
				Density.Sample(source, px - 0.0001, source.Y, source.Z, region),
				Density.Sample(source, px + 0.0001, source.Y, source.Z, region),
				1e-5,
				"Cloud contour changes smoothly with world coordinates"
			)
		end
	end
	local parameters = Noise.Create(0, "independent-noise-test")
	for index = -25, 25 do
		local x, y, z = index * 0.113, index * -0.31, index * 0.79
		for _, value in
			{
				Noise.Sample2D(parameters, x, y),
				Noise.Sample3D(parameters, x, y, z),
				Noise.Fractal2D(parameters, x, y, 4),
				Noise.Fractal3D(parameters, x, y, z, 4),
			}
		do
			check(
				finite(value) and value >= -1 and value <= 1,
				"Coherent single/multi-octave noise is finite and bounded"
			)
		end
		local boundary = index - parameters.OffsetX
		near(
			Noise.Sample3D(parameters, boundary - 0.0001, y, z),
			Noise.Sample3D(parameters, boundary + 0.0001, y, z),
			1e-9,
			"Quintic lattice interpolation has smooth value and slope across lattice boundaries"
		)
	end
	for _, coordinate in { math.huge, -math.huge, 0 / 0 } do
		rejects(function()
			Noise.Sample3D(parameters, coordinate, 0, 0)
		end, "Noise rejects nonfinite world coordinates")
		rejects(function()
			Density.Sample(baseline, coordinate, baseline.Y, baseline.Z, region)
		end, "Source geometry rejects nonfinite world coordinates")
	end
	for _, settings in
		{
			{ Kind = "Invalid" },
			{ Intensity = 0 },
			{ Intensity = 1.1 },
			{ TemperaturePerturbation = 8 },
			{ TargetRelativeHumidity = 1.1 },
			{ MoisturePerturbation = -0.001 },
			{ DomainWarpAmplitude = 0.1 },
			{ GenerationTick = 0.25 },
		}
	do
		rejects(function()
			Generator.Generate(84219, 0, region, settings)
		end, "Source settings reject invalid perturbation and bounded work parameters")
	end
	local smallest = table.clone(region)
	smallest.SizeX, smallest.SizeY, smallest.SizeZ = 5 * region.Dx, 5 * region.Dy, 5 * region.Dz
	local smallSource = Generator.Generate(-1, 0, smallest)
	for y = 0, 5 do
		near(
			Density.Sample(smallSource, smallest.OriginX, y * smallest.Dy, smallSource.Z, smallest),
			Density.Sample(
				smallSource,
				smallest.OriginX + smallest.SizeX,
				y * smallest.Dy,
				smallSource.Z,
				smallest
			),
			1e-12,
			"Minimum resolved domain preserves periodicity"
		)
	end
	local invalidRegion = table.clone(region)
	invalidRegion.SizeX = 4 * region.Dx
	rejects(function()
		Generator.Generate(84219, 0, invalidRegion)
	end, "Unresolved single-cell source geometry is rejected")
	invalidRegion.SizeX = 0
	rejects(function()
		Density.Sample(baseline, baseline.X, baseline.Y, baseline.Z, invalidRegion)
	end, "Periodic source sampling rejects zero domain extent instead of returning NaN")
	local overflowRegion = table.clone(region)
	overflowRegion.OriginX, overflowRegion.SizeX = 1e308, 1e308
	rejects(function()
		Generator.Generate(84219, 0, overflowRegion)
	end, "Finite fields cannot overflow a source's world-coordinate bounds")
	print(
		"PASS: signed world seeds, independent deterministic streams, coherent multi-axis cloud geometry, smooth boundaries and periodic source sampling"
	)
end
