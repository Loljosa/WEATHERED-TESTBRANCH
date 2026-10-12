--!strict

return function(root: any, load: any, check: any, near: any, rejects: any, quick: boolean?)
	local Detail = load(root.Rendering.CloudDetailNoise)
	local Config = load(root.Rendering.CloudRenderConfig)
	local LOD = load(root.Rendering.CloudRenderLOD)
	local quality = Config.GetQuality("High")
	local sameA, sameB, other = Detail.Create(84219), Detail.Create(84219), Detail.Create(-84219)
	local changed = 0
	local samples = if quick then 80 else 360
	for index = 1, samples do
		local x, y, z = -2014 + index * 13.7, 424 + index % 144, 2014 - index * 5.3
		local h, density = (index % 100) / 100, (index % 23) / 23
		local a = Detail.Sample(sameA, x, y, z, h, density, quality)
		local b = Detail.Sample(sameB, x, y, z, h, density, quality)
		near(a, b, 0, "Same seed and world point reproduce the same visual density")
		check(
			a >= 0 and a <= density and a == a,
			"Detail never invents density outside reconstructed support"
		)
		near(
			Detail.Sample(sameA, x, y, z, h, 0, quality),
			0,
			0,
			"Empty physical support remains empty regardless of visual noise"
		)
		if a ~= Detail.Sample(other, x, y, z, h, density, quality) then
			changed += 1
		end
		local aX, aY, aZ, aRotation, aSize = Detail.Offsets(sameA, index - 200, 1 + index % 8)
		local bX, bY, bZ, bRotation, bSize = Detail.Offsets(sameB, index - 200, 1 + index % 8)
		near(aX, bX, 0, "Stable global lattice IDs reproduce X cube offsets")
		near(aY, bY, 0, "Stable global lattice IDs reproduce Y cube offsets")
		near(aZ, bZ, 0, "Stable global lattice IDs reproduce Z cube offsets")
		near(aRotation, bRotation, 0, "Cube rotation is deterministic")
		near(aSize, bSize, 0, "Cube size variation is deterministic")
		check(
			math.abs(aX) <= 0.42 and math.abs(aY) <= 0.42 and math.abs(aZ) <= 0.42,
			"Cube offsets have a bounded subgrid radius"
		)
		check(
			aRotation >= 0 and aRotation < 360 and aSize >= 0.78 and aSize < 1.22,
			"Visual rotation and size remain bounded"
		)
		-- A logical region ID and camera location are absent from these APIs.
		-- Repeating a sample after querying LOD cannot reseed the cloud.
		LOD.Decide(index * 10, nil, quality)
		near(
			Detail.Sample(sameA, x, y, z, h, density, quality),
			a,
			0,
			"Changing camera distance does not modify procedural detail"
		)
	end
	check(
		changed > samples * 0.8,
		"Different world seeds meaningfully change appearance within the same physical support"
	)
	for _, seam in { -1007, 0, 1007 } do
		local left = Detail.Sample(sameA, seam - 1e-5, 480, 112, 0.5, 0.5, quality)
		local right = Detail.Sample(sameA, seam + 1e-5, 480, 112, 0.5, 0.5, quality)
		near(left, right, 1e-6, "Visual noise does not introduce a logical-region seam")
	end
	for _, seed in { 0, -1, 2147483647, -2147483648 } do
		check(
			Detail.Create(seed).Seed % 1 == 0,
			"All canonical signed seeds produce deterministic detail"
		)
	end
	rejects(function()
		Detail.Create(0.5)
	end, "Fractional detail world seeds are rejected")
	rejects(function()
		Detail.Sample(sameA, 0 / 0, 0, 0, 0, 0, quality)
	end, "NaN detail coordinates fail explicitly")
	rejects(function()
		Detail.Sample(sameA, 0, 0, math.huge, 0, 0, quality)
	end, "Infinite detail coordinates fail explicitly")
	rejects(function()
		Detail.Sample(sameA, 0, 0, 0, 0, -1, quality)
	end, "Negative display density is rejected")
	rejects(function()
		Detail.Sample(sameA, 0, 0, 0, 0, 1.1, quality)
	end, "Unnormalized display density is rejected")
	rejects(function()
		Detail.Offsets(sameA, 0.5, 1)
	end, "Fractional spatial IDs are rejected")
	rejects(function()
		Detail.Offsets(sameA, 1, 0)
	end, "Invalid cube ordinals are rejected")
	rejects(function()
		sameA.Seed = 7
	end, "Noise configuration is immutable")
	rejects(function()
		quality.MaxCubes = 1e6
	end, "Quality configuration is immutable")
	return {
		Samples = samples,
		SeedChangedSamples = changed,
		CameraReseeding = false,
		PhysicsWrites = 0,
	}
end
