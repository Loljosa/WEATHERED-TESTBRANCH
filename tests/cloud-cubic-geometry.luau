--!strict

local Spy = require("./CloudRenderInstanceSpy")
local fixture = require("./CloudRenderFixture")

-- Real renderer/codec/transport modules run unchanged. Only Roblox Instances
-- are replaced by a property-recording spy; this makes no GPU or FPS claim.
return function(root: any, load: any, check: any, near: any, _rejects: any, quick: boolean?)
	local Config = load(root.Rendering.CloudRenderConfig)
	local Reconstruction = load(root.Rendering.CloudDensityReconstruction)
	local Snapshot = load(root.Rendering.CloudRenderSnapshot)
	local function savedFields(field: any): { [string]: string }
		local result = {}
		for name, values in field.Fields do
			result[name] = buffer.tostring(values)
		end
		return result
	end
	local function unchanged(field: any, before: { [string]: string })
		for name, values in before do
			check(
				buffer.tostring(field.Fields[name]) == values,
				"Cubic rendering never changes authoritative " .. name
			)
		end
	end
	local function geometry(renderer: any, spy: any, sideLimit: number): any
		local count, sx, sy, sz = 0, 0, 0, 0
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		local positions = {}
		for id, proxy in renderer.Pool.Active do
			if proxy.Opacity <= 1 / 255 then
				continue
			end
			local anchor = proxy.Anchor
			check(
				anchor.ClassName == "Part" and anchor.Shape == "Block",
				"Visible cloud resources are genuine three-dimensional Block Parts"
			)
			check(
				anchor.Size.X > 0 and anchor.Size.X < math.huge,
				"Cube side is finite and positive"
			)
			check(anchor.Size.X >= 12, "Cubic detail retains the intended twelve-stud minimum")
			near(anchor.Size.X, anchor.Size.Y, 0, "Every cloud cube has equal X/Y dimensions")
			near(anchor.Size.Y, anchor.Size.Z, 0, "Every cloud cube has equal Y/Z dimensions")
			check(
				anchor.Size.X <= sideLimit + 1e-9,
				"Cloud cube never grows into an enormous coarse-grid tile"
			)
			check(
				not anchor.CanCollide and not anchor.CanTouch and not anchor.CanQuery,
				"Cloud blocks have no gameplay collision authority"
			)
			-- Roblox Vector3 properties represent positions at float32 precision.
			near(
				anchor.Position.X,
				proxy.X,
				math.max(1, math.abs(proxy.X)) * 2 ^ -23,
				"Displayed cube follows renderer world X"
			)
			near(
				anchor.Position.Y,
				proxy.Y,
				math.max(1, math.abs(proxy.Y)) * 2 ^ -23,
				"Displayed cube follows renderer altitude"
			)
			near(
				anchor.Position.Z,
				proxy.Z,
				math.max(1, math.abs(proxy.Z)) * 2 ^ -23,
				"Displayed cube follows renderer world Z"
			)
			count += 1
			sx, sy, sz = sx + proxy.X, sy + proxy.Y, sz + proxy.Z
			minX, minY, minZ =
				math.min(minX, proxy.X), math.min(minY, proxy.Y), math.min(minZ, proxy.Z)
			maxX, maxY, maxZ =
				math.max(maxX, proxy.X), math.max(maxY, proxy.Y), math.max(maxZ, proxy.Z)
			positions[id] = { X = proxy.X, Y = proxy.Y, Z = proxy.Z }
		end
		check(
			count >= 4,
			"One connected atmospheric formation produces several visible cubic samples"
		)
		local mx, my, mz = sx / count, sy / count, sz / count
		local xx, yy, zz, xy, xz, yz = 0, 0, 0, 0, 0, 0
		for _, point in positions do
			local x, y, z = point.X - mx, point.Y - my, point.Z - mz
			xx, yy, zz = xx + x * x, yy + y * y, zz + z * z
			xy, xz, yz = xy + x * y, xz + x * z, yz + y * z
		end
		local determinant = xx * yy * zz
			+ 2 * xy * xz * yz
			- xx * yz * yz
			- yy * xz * xz
			- zz * xy * xy
		local scale = math.max(xx * yy * zz, 1)
		check(
			maxX - minX > 12 and maxZ - minZ > 12,
			"Cloud formation occupies both horizontal directions"
		)
		check(
			maxY - minY >= 24 - 1e-9,
			"Cloud formation has meaningful vertical depth across multiple levels"
		)
		check(
			determinant / scale > 1e-6,
			"Cube centers form a three-dimensional volume instead of a single sprite plane"
		)
		for _, instance in spy.Instances do
			check(
				instance.ClassName ~= "BillboardGui"
					and instance.ClassName ~= "ImageLabel"
					and instance.ClassName ~= "ParticleEmitter"
					and instance.ClassName ~= "Attachment",
				"Cubic cloud path never allocates sprite cards, emitters or particle attachments"
			)
		end
		return {
			Count = count,
			Positions = positions,
			SpanX = maxX - minX,
			SpanY = maxY - minY,
			SpanZ = maxZ - minZ,
			MeanX = mx,
			MeanY = my,
			MeanZ = mz,
			NormalizedVolumeDeterminant = determinant / scale,
		}
	end
	local results = {}
	local decoded, field = fixture(root, load, {
		SizeX = 32,
		SizeZ = 32,
		QC = function(x: number, y: number, z: number): number
			-- Manufactured connected liquid support for graphics QA only. The
			-- production atmospheric source system still never paints qc.
			return if x >= 15
					and x <= 18
					and z >= 15
					and z <= 18
					and y >= 2
					and y <= 5
				then 0.0001
				else 0
		end,
	})
	local physicalBefore, packetBefore = savedFields(field), buffer.tostring(decoded.Payload)
	local lower, middle, upper = Config.Layer(0), Config.Layer(0.40), Config.Layer(1)
	near(lower, 12, 0, "Near lower-cloud detail begins with twelve-stud cubes")
	check(
		middle >= 14 and middle <= 20 and middle > lower,
		"Middle-cloud cubes transition gradually around sixteen studs"
	)
	near(upper, 24, 0, "Upper-cloud cubes use the intended twenty-four-stud scale")
	for _, name in { "Mobile", "Balanced", "High", "Ultra" } do
		local quality = Config.GetQuality(name)
		check(
			quality.MaxCubeSize <= 48,
			"Every graphics preset caps distant cube side at forty-eight studs"
		)
		local spy = Spy.Create()
		local Renderer = spy:Load(root, load)
		local reconstruction = Reconstruction.new({ VelocityAssist = false, StaleAfter = 60 })
		reconstruction:Push(decoded, 0)
		local renderer = Renderer.new(reconstruction, {
			Quality = name,
			Factory = spy.Factory,
			Parent = spy.Workspace,
			Clock = function(): number
				return 0
			end,
		})
		local updates = if quick then 48 else 96
		local interval = 1 / quality.UpdateHz
		local settledIds = {}
		local stableFrames = 0
		for update = 1, updates do
			renderer:Update(update * interval, interval, { X = 0, Y = 490, Z = 0 })
			local stats = renderer:GetDiagnostics()
			check(
				stats.ActiveCubes <= quality.MaxCubes
					and stats.ActiveClusters <= quality.MaxClusters,
				"Cubic quality selection honors active geometry and column budgets"
			)
			check(
				stats.CreatedThisUpdate <= quality.MaxCreatesPerUpdate,
				"Cube Instance construction is bounded per update"
			)
			if stats.CompletedScans >= 2 then
				-- Identical paused weather and camera have no reason to lose
				-- already selected cubes while a partial frontier is rebuilt.
				for id in settledIds do
					check(
						renderer.Pool.Active[id] ~= nil,
						"Partial rebuilds preserve established cubes in unchanged paused clouds"
					)
				end
				for id, proxy in renderer.Pool.Active do
					if proxy.Opacity > 1 / 255 then
						settledIds[id] = true
					end
				end
				stableFrames += 1
			end
		end
		local observed = geometry(renderer, spy, quality.MaxCubeSize)
		unchanged(field, physicalBefore)
		check(
			buffer.tostring(decoded.Payload) == packetBefore,
			"Client reconstruction and cubic detail leave received snapshots immutable"
		)
		renderer:SetEnabled(false)
		near(
			renderer:GetDiagnostics().ActiveCubes,
			0,
			0,
			"Off mode releases every active cubic cloud resource"
		)
		renderer:Destroy()
		near(
			spy:GetDiagnostics().LiveInstances,
			0,
			0,
			"Cubic renderer destroys all owned Instances"
		)
		observed.Positions = nil
		observed.StaticFramesChecked = stableFrames
		results[name] = observed
	end
	-- Actual conservative field transport and moved cube carriers are tested
	-- together. Visual interpolation alone is not evidence of water transport.
	local initial, moving = fixture(root, load, {
		SizeX = 8,
		SizeZ = 8,
		U = 8,
		QC = function(x: number, y: number, z: number): number
			return if (x == 3 or x == 4)
					and (z == 4 or z == 5)
					and y >= 2
					and y <= 5
				then 0.0001
				else 0
		end,
	}, { Seed = 84219, Generation = 3, Sequence = 1, Time = 0, WallTime = 0 })
	moving:ResetWaterBaseline()
	local spy = Spy.Create()
	local Renderer = spy:Load(root, load)
	local reconstruction = Reconstruction.new({ VelocityAssist = false, StaleAfter = 60 })
	reconstruction:Push(initial, 0)
	local renderer = Renderer.new(reconstruction, {
		Quality = "Balanced",
		Factory = spy.Factory,
		Parent = spy.Workspace,
		Clock = function(): number
			return 0
		end,
	})
	local interval = 1 / Config.GetQuality("Balanced").UpdateHz
	local wallNow = 0
	for _ = 1, 64 do
		wallNow += interval
		renderer:Update(wallNow, interval, { X = -350, Y = 490, Z = 0 })
	end
	local before = geometry(renderer, spy, 48)
	local start = moving:GetDiagnostics()
	for _ = 1, 4 do
		moving:Step(0.25)
	end
	local afterOneSecond = savedFields(moving)
	local second = Snapshot.Decode(
		Snapshot.Encode(
			moving,
			{ Seed = 84219, Generation = 3, Sequence = 2, Time = moving.Time, WallTime = 1 }
		)
	)
	reconstruction:Push(second, wallNow)
	for _ = 1, 16 do
		wallNow += interval
		renderer:Update(wallNow, interval, { X = -350, Y = 490, Z = 0 })
	end
	local moved = 0
	for id, original in before.Positions do
		local proxy = renderer.Pool.Active[id]
		if proxy and proxy.Opacity > 1 / 255 and proxy.X > original.X + 1e-6 then
			moved += 1
		end
	end
	check(moved > 0, "Stable cubic detail moves in the direction of authoritative wind")
	unchanged(moving, afterOneSecond)
	local steps = if quick then 240 else 480
	for _ = 5, steps do
		moving:Step(0.25)
	end
	local finish = moving:GetDiagnostics()
	check(
		finish.CloudCentroidX > start.CloudCentroidX + 300,
		"Actual liquid-water centroid advances across a logical region under wind"
	)
	check(
		finish.InternalRegionCrossingQcSum > 0,
		"Numerical shared-face cloud-water flux crosses internal weather regions"
	)
	near(
		finish.WaterSum,
		start.WaterSum,
		start.WaterSum * 1e-12,
		"Region crossings conserve unweighted total water independently of visual cubes"
	)
	local finalBefore = savedFields(moving)
	local finalPacket = Snapshot.Decode(Snapshot.Encode(moving, {
		Seed = 84219,
		Generation = 3,
		Sequence = 3,
		Time = moving.Time,
		WallTime = moving.Time,
	}))
	reconstruction:Push(finalPacket, wallNow)
	for _ = 1, 32 do
		wallNow += interval
		renderer:Update(wallNow, interval, { X = 0, Y = 490, Z = 0 })
	end
	geometry(renderer, spy, 48)
	unchanged(moving, finalBefore)
	renderer:Destroy()
	near(
		spy:GetDiagnostics().LiveInstances,
		0,
		0,
		"Transported cloud renderer releases every Block Part"
	)
	return {
		QualityGeometry = results,
		WindMovedStableCubes = moved,
		SimulatedSeconds = finish.Time,
		TravelXMeters = finish.CloudCentroidX - start.CloudCentroidX,
		InternalQcTransferSum = finish.InternalRegionCrossingQcSum,
		WaterDriftFraction = finish.WaterDriftFraction,
		RobloxStudioTested = false,
	}
end
