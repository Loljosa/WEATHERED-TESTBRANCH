--!strict
local Spy = require("./CloudRenderInstanceSpy")
local fixture = require("./CloudRenderFixture")
return function(root: any, load: any, check: any, near: any, rejects: any, quick: boolean?)
	local Config = load(root.Rendering.CloudRenderConfig)
	local Reconstruction = load(root.Rendering.CloudDensityReconstruction)
	local spy = Spy.Create()
	local Renderer, Pool = spy:Load(root, load)
	local pool =
		Pool.new({ Limit = 8, InactiveLimit = 2, Factory = spy.Factory, Parent = spy.Workspace })
	pool:BeginUpdate(2)
	local one, two = pool:Acquire(1), pool:Acquire(2)
	check(one ~= nil and two ~= nil, "Cube pool creates allowed genuine Block Parts")
	check(pool:Acquire(3) == nil, "Cube creation is bounded per update")
	check(pool:Acquire(1) == one, "Stable voxel identity preserves its pooled Part")
	check(
		pool:GetDiagnostics().AllocatedInstances == 3,
		"Two cubes allocate exactly two Parts and one folder"
	)
	pool:Apply(one, 0, 480, 0, 12, 0.4, 1, 1, 1)
	check(
		one.Anchor.Shape == "Block"
			and one.Anchor.Size.X == 12
			and one.Anchor.Size.Y == 12
			and one.Anchor.Size.Z == 12,
		"Primary geometry is a genuine equal-axis 12-stud cube"
	)
	check(
		one.Anchor.Color.R == 1 and one.Anchor.Color.G == 1 and one.Anchor.Color.B == 1,
		"First exact-white shade does not inherit Roblox default stone gray"
	)
	check(
		not one.Anchor.CanCollide
			and not one.Anchor.CanQuery
			and not one.Anchor.CanTouch
			and not one.Anchor.CastShadow,
		"Cubes add no gameplay collision or shadow workloads"
	)
	local oldWrites = spy:GetDiagnostics().PropertyWrites
	pool:Apply(one, 0, 480, 0, 12, 0.4, 1, 1, 1)
	check(
		spy:GetDiagnostics().PropertyWrites == oldWrites,
		"Unchanged cube creates no property writes or datatype allocations"
	)
	pool:Apply(one, 0, 480, 0, 12, 0.5, 1, 1, 1)
	check(
		spy:GetDiagnostics().PropertyWrites == oldWrites + 1,
		"Opacity-only update writes only transparency"
	)
	pool:BeginUpdate(6)
	for id = 3, 8 do
		check(pool:Acquire(id) ~= nil, "Allowed cube creations fill bounded pool")
	end
	check(pool.ActiveCount == 8 and pool:Acquire(9) == nil, "Active cube cap cannot be exceeded")
	pool:Hide()
	check(
		#pool.Proxies == 2 and #pool.Free == 2,
		"Hidden cubes retain only the configured inactive cache"
	)
	pool:BeginUpdate(0)
	check(
		pool:Acquire(20) ~= nil and pool:Acquire(21) ~= nil and pool:Acquire(22) == nil,
		"Cached cubes reuse with zero creation budget"
	)
	pool:SetLimit(1, 0)
	check(
		pool.ActiveCount == 1 and #pool.Proxies == 1,
		"Quality downgrade trims active and inactive Parts"
	)
	pool:Destroy()
	pool:Destroy()
	check(spy:GetDiagnostics().LiveInstances == 0, "Pool cleanup is complete and idempotent")
	rejects(function()
		Pool.new({ Limit = 1281 })
	end, "Pool rejects unbounded cube counts")
	rejects(function()
		Pool.new({ Limit = 8, InactiveLimit = 129 })
	end, "Pool rejects unbounded inactive cache")
	rejects(function()
		local p = Pool.new({ Limit = 1, Factory = spy.Factory, Parent = spy.Workspace })
		p:BeginUpdate(1)
		local a = p:Acquire(1)
		local ok = pcall(function()
			p:Apply(a, 0, 480, 0, 125, 0.4, 1, 1, 1)
		end)
		p:Destroy()
		assert(ok)
	end, "Pool rejects the old enormous tile size")
	local _, geometryField = fixture(root, load)
	local Coordinates = load(root.World.WorldCoordinates)
	local Codec = load(root.Rendering.CloudRenderSnapshot)
	local tallCoordinates = Coordinates.new({ HeightMeters = 10000000 })
	local tallPayload = Codec.Encode({
		State = geometryField.State,
		Coordinates = tallCoordinates,
		ValueBytes = 8,
		Boundary = "Periodic",
		Time = 0,
	}, { Seed = 1, Generation = 1, Sequence = 1, Time = 0, WallTime = 0 })
	local tallPacket = Codec.Decode(tallPayload)
	local hugeReconstruction = Reconstruction.new()
	check(
		hugeReconstruction:Push(tallPacket, 0),
		"Finite complete very-tall packet is valid independently of client geometry budgets"
	)
	local liveBeforeHuge = spy:GetDiagnostics().LiveInstances
	rejects(function()
		Renderer.new(hugeReconstruction, { Factory = spy.Factory, Parent = spy.Workspace })
	end, "Oversized construction lattice reports a bounded numerical/graphics failure")
	check(
		spy:GetDiagnostics().LiveInstances == liveBeforeHuge,
		"Oversized geometry rejection happens before any render Instance allocation"
	)
	local lateReconstruction = Reconstruction.new()
	local lateRenderer = Renderer.new(lateReconstruction, {
		Factory = spy.Factory,
		Parent = spy.Workspace,
		Clock = function()
			return 0
		end,
	})
	lateReconstruction:Push(tallPacket, 0)
	rejects(function()
		lateRenderer:Update(0, 0.2, { X = 0, Y = 70, Z = 0 })
	end, "Later oversized snapshot rejects before construction-buffer allocation")
	check(
		buffer.len(lateRenderer.LODHistory) == 0 and lateRenderer.Pool.ActiveCount == 0,
		"Later geometry failure cannot allocate an enormous lattice or cubes"
	)
	lateRenderer:Destroy()
	check(
		spy:GetDiagnostics().LiveInstances == liveBeforeHuge,
		"Failure cleanup removes its bounded ownership folder"
	)
	local empty = fixture(root, load, { SizeX = 32, SizeZ = 32 })
	local recon = Reconstruction.new({ VelocityAssist = false })
	recon:Push(empty, 0)
	local renderer = Renderer.new(recon, {
		Quality = "Mobile",
		Factory = spy.Factory,
		Parent = spy.Workspace,
		Clock = function()
			return 0
		end,
	})
	local camera = { X = 0, Y = 70, Z = 0 }
	for i = 1, 16 do
		renderer:Update(i * 0.2, 0.2, camera)
	end
	check(
		renderer:GetDiagnostics().ActiveCubes == 0
			and renderer:GetDiagnostics().AllocatedInstances == 1,
		"Known clear sky creates no geometric clouds"
	)
	local uniform, field = fixture(root, load, {
		SizeX = 32,
		SizeZ = 32,
		U = 8,
		V = 2,
		QC = function()
			return 0.0001
		end,
	}, { Seed = 84219, Generation = 2, Sequence = 1, Time = 0, WallTime = 0 })
	local before = buffer.tostring(field.Fields.qc)
	recon:Push(uniform, 4)
	local maxCreated, maxActive, maxInstances = 0, 0, 0
	for i = 1, (if quick then 60 else 100) do
		renderer:Update(
			4 + i * 0.2,
			0.2,
			camera,
			{ SunX = 0.2, SunY = 0.8, SunZ = 0.3, Ambient = 0.5 }
		)
		local stats = renderer:GetDiagnostics()
		maxCreated = math.max(maxCreated, stats.CreatedThisUpdate)
		maxActive = math.max(maxActive, stats.ActiveCubes)
		maxInstances = math.max(maxInstances, stats.AllocatedInstances)
		check(
			stats.ActiveCubes <= 256 and stats.ActiveClusters <= 32,
			"Mobile cube and construction-cluster caps hold"
		)
		check(
			stats.RetainedInactiveCubes <= 32 and stats.AllocatedInstances <= 289,
			"Mobile retains only bounded real Parts"
		)
		check(stats.CubeUpdatesLastUpdate <= 64, "Mobile per-update cube work is bounded")
		check(
			stats.RootQueriesLastUpdate <= 1536 and stats.ChildQueriesLastUpdate <= 128,
			"Adaptive reconstruction has hard root/fine query caps"
		)
	end
	check(maxActive > 0, "Actual density produces a nonempty cubic volume")
	check(maxCreated <= 6, "Mobile creates at most six real cubes/update")
	check(
		buffer.tostring(field.Fields.qc) == before,
		"Procedural volume rendering never changes qc"
	)
	for _, proxy in renderer.Pool.Active do
		check(
			proxy.Anchor.Shape == "Block"
				and proxy.Anchor.Size.X == proxy.Anchor.Size.Y
				and proxy.Anchor.Size.Y == proxy.Anchor.Size.Z,
			"All rendered elements retain equal nonzero XYZ depth"
		)
		check(
			proxy.Size >= 12 and proxy.Size <= 48,
			"No rendered element is a giant tile or thin sheet"
		)
		check(
			proxy.Y - proxy.Size / 2 >= 424 - 1e-8 and proxy.Y + proxy.Size / 2 <= 568 + 1e-8,
			"All cube vertices respect truthful physical altitude"
		)
		check(
			proxy.X - proxy.Size / 2 >= -2014 - 1e-8
				and proxy.X + proxy.Size / 2 <= 2014 + 1e-8
				and proxy.Z - proxy.Size / 2 >= -2014 - 1e-8
				and proxy.Z + proxy.Size / 2 <= 2014 + 1e-8,
			"Partial outer construction nodes never stretch or extend world coverage"
		)
	end
	for _, instance in spy.Instances do
		check(
			instance.ClassName == "Workspace"
				or instance.ClassName == "Folder"
				or instance.ClassName == "Part",
			"Renderer never creates cards, images, particles, meshes or planes"
		)
	end
	renderer:SetDebugMode("gradients")
	renderer:Update(18, 0.2, camera)
	check(renderer:GetDiagnostics().DebugMode == "Gradients", "Local density-gradient mode works")
	renderer:SetDebugMode("bounds")
	renderer:Update(18.2, 0.2, camera)
	check(renderer:GetDiagnostics().DebugMode == "Bounds", "Local envelope-height diagnostics work")
	renderer:SetEnabled(false)
	check(
		renderer.Pool.ActiveCount == 0 and #renderer.Pool.Free <= 32,
		"Off hides all cubes without an unbounded cache"
	)
	renderer:Update(100, 0.2, camera)
	check(renderer.Pool.ActiveCount == 0, "Off does not recreate cube geometry")
	renderer:SetEnabled(true)
	local presetStats = {}
	for _, qualityName in { "Balanced", "High", "Ultra", "Mobile" } do
		renderer:SetQuality(qualityName)
		renderer:SetDebugMode("None")
		local q = Config.GetQuality(qualityName)
		for i = 1, 50 do
			renderer:Update(4 + i * 0.2, 0.2, camera)
		end
		local stats = renderer:GetDiagnostics()
		presetStats[qualityName] = stats
		check(
			stats.ActiveCubes <= q.MaxCubes and stats.ActiveClusters <= q.MaxClusters,
			"Every quality honors exact cubic geometry caps"
		)
		check(
			stats.AllocatedInstances <= 1 + q.MaxPoolCubes
				and stats.RetainedInactiveCubes <= q.MaxInactiveCubes,
			"Every quality bounds both active and cached real Instances"
		)
		check(
			buffer.tostring(field.Fields.qc) == before,
			"Graphics quality never selects a different physical atmosphere"
		)
	end
	local paused, pausedField = fixture(root, load, {
		U = 8,
		V = 2,
		QC = function()
			return 0.0001
		end,
	}, { Seed = 17, Generation = 5, Sequence = 1, Time = 20, WallTime = 0 })
	local pausedBefore = buffer.tostring(pausedField.Fields.qc)
	local pausedRecon = Reconstruction.new({ VelocityAssist = false })
	pausedRecon:Push(paused, 0)
	local stableSpy = Spy.Create()
	local Actual = stableSpy:Load(root, load)
	local a = Actual.new(pausedRecon, {
		Quality = "Balanced",
		Factory = stableSpy.Factory,
		Parent = stableSpy.Workspace,
		Clock = function()
			return 0
		end,
	})
	for i = 1, 50 do
		a:Update(i * 0.125, 0.125, camera)
	end
	local locations = {}
	for id, p in a.Pool.Active do
		locations[id] = { p.X, p.Y, p.Z }
	end
	for i = 51, 55 do
		a:Update(i * 0.125, 0.125, camera)
	end
	for id, p in a.Pool.Active do
		local old = locations[id]
		if old then
			near(p.X, old[1], 1e-12, "Paused physics preserves cube X")
			near(p.Y, old[2], 1e-12, "Paused physics preserves cube Y")
			near(p.Z, old[3], 1e-12, "Paused physics preserves cube Z")
		end
	end
	local b = Actual.new(pausedRecon, {
		Quality = "Balanced",
		Factory = stableSpy.Factory,
		Parent = stableSpy.Workspace,
		Clock = function()
			return 0
		end,
	})
	for i = 1, 55 do
		b:Update(i * 0.125, 0.125, camera)
	end
	local common = 0
	for id, p in a.Pool.Active do
		local other = b.Pool.Active[id]
		if other then
			common += 1
			near(p.X, other.X, 1e-12, "Two clients reproduce cubic X")
			near(p.Y, other.Y, 1e-12, "Two clients reproduce cubic Y")
			near(p.Z, other.Z, 1e-12, "Two clients reproduce cubic Z")
			near(p.Size, other.Size, 1e-12, "Two clients reproduce cubic side")
		end
	end
	check(common > 0, "Independent clients share seed-stable volumetric positions")
	b:Destroy()
	local codec = load(root.Rendering.CloudRenderSnapshot)
	local continued = codec.Decode(
		codec.Encode(
			pausedField,
			{ Seed = 17, Generation = 5, Sequence = 2, Time = 21, WallTime = 7 }
		)
	)
	pausedRecon:Push(continued, 7)
	for i = 57, 63 do
		a:Update(i * 0.125, 0.125, camera)
	end
	local moved = 0
	for id, old in locations do
		local p = a.Pool.Active[id]
		if p and p.X > old[1] + 0.001 then
			moved += 1
		end
	end
	check(
		moved > 0,
		"Authoritative wind in m/s moves genuine cube centers with the validated conversion"
	)
	check(
		buffer.tostring(pausedField.Fields.qc) == pausedBefore,
		"Visual movement never moves atmospheric mass independently"
	)
	local reset = fixture(root, load, {
		QC = function()
			return 0.0001
		end,
	}, { Seed = -17, Generation = 6, Sequence = 1, Time = 0, WallTime = 8 })
	pausedRecon:Push(reset, 8)
	a:Update(8, 0.125, camera)
	check(a.Generation == 6 and a.Seed == -17, "Regeneration invalidates old volumetric history")
	local clear = fixture(
		root,
		load,
		nil,
		{ Seed = -17, Generation = 6, Sequence = 2, Time = 1, WallTime = 9 }
	)
	pausedRecon:Push(clear, 9)
	a:Update(9, 0.125, camera)
	check(
		a.Pool.ActiveCount == 0 and #a.Pool.Free <= 64,
		"Cloud disappearance releases its cubic volume"
	)
	a:Destroy()
	a:Destroy()
	check(
		stableSpy:GetDiagnostics().LiveInstances == 0,
		"Cubic renderer shutdown has no leaked Instances"
	)
	renderer:Destroy()
	check(spy:GetDiagnostics().LiveInstances == 0, "Main cubic renderer cleanup is complete")
	rejects(function()
		renderer:Update(0, 0.2, camera)
	end, "Destroyed renderer cannot recreate cubes")
	print(
		"PASS: genuine cubic geometry, adaptive 3D reconstruction, resource caps, deterministic clients, field-driven motion and cleanup"
	)
	return {
		MobileMaxActive = maxActive,
		MobileMaxCreatedPerUpdate = maxCreated,
		MobileMaxAllocatedInstances = maxInstances,
		Presets = presetStats,
		StudioGpuTested = false,
	}
end
