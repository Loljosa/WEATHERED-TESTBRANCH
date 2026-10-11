--!strict

local createLoader = require("./RobloxModuleLoader")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

return function(root: any, loadModule: any, check: any, near: any, rejects: any, _quick: boolean?)
	local Snapshot = loadModule(root.World.WeatherSnapshot)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local function metadata(nx: number, ny: number, nz: number): any
		return {
			SizeX = nx,
			SizeY = ny,
			SizeZ = nz,
			Seed = 0,
			Generation = 0,
			Sequence = 0,
			Time = 0,
			WallTime = 0,
			DroppedTime = 0,
			WidthStuds = 4028,
			DepthStuds = 4028,
			StudsPerMeter = 2,
			MinXStuds = -2014,
			MinZStuds = -2014,
			BottomYStuds = 424,
			LayerHeightStuds = 24,
		}
	end
	local function fields(count: number, stride: number?): any
		local size = stride or 8
		return {
			qc = buffer.create(count * size),
			u = buffer.create(count * size),
			v = buffer.create(count * size),
			w = buffer.create(count * size),
		}
	end
	local source = fields(8)
	local liquid = { 0, 0.0002, 0.0004, 0.0001, 0, 0.0004, 0.00005, 0 }
	for index = 1, 8 do
		buffer.writef64(source.qc, (index - 1) * 8, liquid[index])
		buffer.writef64(source.u, (index - 1) * 8, 8)
		buffer.writef64(source.v, (index - 1) * 8, -2)
		buffer.writef64(source.w, (index - 1) * 8, 0.5)
	end
	local before = {}
	for name, field in source do
		before[name] = buffer.tostring(field)
	end
	local work = Snapshot.NewWorkspace(2)
	local meta = metadata(2, 2, 2)
	meta.Seed = -84219
	meta.DebugRegions = true
	meta.DebugVectors = true
	local payload = Snapshot.Encode(source, meta, work)
	local a = Snapshot.Decode(payload)
	near(buffer.len(payload), 140, 0, "Two sparse cells use the documented bounded binary layout")
	near(a.Count, 2, 0, "Sparse snapshot never exceeds its record cap")
	near(
		a.AboveThreshold,
		5,
		0,
		"Snapshot explicitly counts liquid cells omitted by diagnostic cropping"
	)
	near(a.Seed, -84219, 0, "Snapshot retains signed negative seeds")
	check(
		a.DebugRegions and a.DebugVectors and a.DebugEnabled,
		"Snapshot flags describe optional client diagnostics"
	)
	local first, q, u, v, w = Snapshot.Record(a, 1)
	near(first, 3, 0, "Deterministic strongest-qc selection retains the first maximum")
	near(q, 0.0004, 1e-10, "Snapshot liquid is float32-quantized kg/kg")
	near(u, 8, 0, "Snapshot u remains physical m/s")
	near(v, -2, 0, "Snapshot v remains Z-directed physical m/s")
	near(w, 0.5, 0, "Snapshot w remains Y-directed physical m/s")
	near(Snapshot.Record(a, 2), 6, 0, "Record indices are sorted for deterministic binary sampling")
	for name, field in source do
		check(buffer.tostring(field) == before[name], "Codec never changes authoritative " .. name)
	end
	check(
		buffer.tostring(payload) == buffer.tostring(Snapshot.Encode(source, meta, work)),
		"Same authoritative snapshot produces identical bytes"
	)
	near(
		Snapshot.Sample(a, 2),
		0,
		0,
		"Cropped liquid is omitted from diagnostics without changing physics"
	)
	local one = Snapshot.Decode(Snapshot.Encode(source, meta, Snapshot.NewWorkspace(1)))
	near(Snapshot.Record(one, 1), 3, 0, "Equal-water selection consistently favors the lower index")
	local previousPayload = buffer.tostring(a.Payload)
	buffer.writef64(source.qc, 2 * 8, 0)
	buffer.writef64(source.qc, 3 * 8, 0.0008)
	meta.Time, meta.WallTime, meta.Sequence = 1, 1, 1
	local b = Snapshot.Decode(Snapshot.Encode(source, meta, work))
	local currentPayload = buffer.tostring(b.Payload)
	near(
		Snapshot.Interpolate(a, b, 3, 0.5),
		0.0002,
		1e-10,
		"Departing liquid cells fade between authoritative snapshots"
	)
	near(
		Snapshot.Interpolate(a, b, 4, 0.5),
		0.0004,
		1e-10,
		"Arriving liquid cells appear through field interpolation"
	)
	near(
		Snapshot.Interpolate(a, b, 6, 0.5),
		0.0004,
		1e-10,
		"Retained liquid cells preserve authoritative density"
	)
	for alpha = 0, 1, 0.1 do
		for index = 1, 8 do
			local water = Snapshot.Interpolate(a, b, index, alpha)
			check(
				water >= 0 and water == water and water < math.huge,
				"Diagnostic interpolation remains finite and nonnegative"
			)
		end
	end
	check(
		buffer.tostring(a.Payload) == previousPayload
			and buffer.tostring(b.Payload) == currentPayload,
		"Interpolation never writes into network snapshots"
	)
	check(Snapshot.IsNewer(a, b), "New authoritative sequence is accepted")
	check(not Snapshot.IsNewer(b, a), "Late bootstrap response cannot replace newer live state")
	check(not Snapshot.IsNewer(a, a), "Duplicate network sequence is ignored")
	local newerMeta = table.clone(meta)
	newerMeta.Generation, newerMeta.Sequence, newerMeta.Time = 1, 2, 0
	local reset = Snapshot.Decode(Snapshot.Encode(source, newerMeta, work))
	check(
		not Snapshot.Compatible(b, reset),
		"Regeneration invalidates interpolation across weather worlds"
	)
	check(
		Snapshot.IsNewer(b, reset) and not Snapshot.IsNewer(reset, b),
		"Old-generation bootstrap responses cannot resurrect a prior world"
	)
	near(
		Snapshot.Interpolate(b, reset, 4, 0),
		Snapshot.Sample(reset, 4),
		0,
		"Regenerated state snaps to its own field rather than mixing old cloud water"
	)
	local x, y, z = Snapshot.CellCenter(a, 1)
	near(x, -1007, 0, "Snapshot cell centers use world-wide X coordinates")
	near(y, 436, 0, "Snapshot altitude follows the explicit stud mapping")
	near(z, -1007, 0, "Snapshot cell centers use world-wide Z coordinates")
	local coordinate = Coordinates.new()
	local cx, cy, cz = coordinate:CellCenterWorld(2, 2, 2, 2, 2, 2)
	local sx, sy, sz = Snapshot.CellCenter(a, 8)
	near(sx, cx, 0, "Codec agrees with production world coordinates in X")
	-- This fixture uses two 24-stud layers, so compare its own vertical spacing.
	near(sy, 460, 0, "Codec keeps configurable vertical layers independent of horizontal extent")
	near(sz, cz, 0, "Codec agrees with production world coordinates in Z")
	check(
		cy > coordinate.BottomStuds,
		"Production coordinate altitude is independent of record ordering"
	)

	local asymmetric = Snapshot.Decode(Snapshot.Encode(fields(2 * 3 * 4), metadata(2, 3, 4), work))
	for iy = 1, 3 do
		for iz = 1, 4 do
			for ix = 1, 2 do
				local index = ((iy - 1) * 4 + iz - 1) * 2 + ix
				local px, py, pz = Snapshot.CellCenter(asymmetric, index)
				near(
					px,
					-2014 + (ix - 0.5) * 4028 / 2,
					0,
					"Snapshot X index matches the production X-fastest layout"
				)
				near(
					py,
					424 + (iy - 0.5) * 24,
					0,
					"Snapshot Y advances after complete horizontal layers"
				)
				near(
					pz,
					-2014 + (iz - 0.5) * 4028 / 4,
					0,
					"Snapshot Z is the second-fastest production axis"
				)
			end
		end
	end

	local large = fields(32 * 6 * 32)
	for index = 1, 32 * 6 * 32 do
		buffer.writef64(large.qc, (index - 1) * 8, 0.0001 + index * 1e-9)
	end
	local laptop =
		Snapshot.Decode(Snapshot.Encode(large, metadata(32, 6, 32), Snapshot.NewWorkspace(256)))
	near(
		buffer.len(laptop.Payload),
		4712,
		0,
		"Laptop global summary remains 4,712 bytes at its fixed cap"
	)
	near(
		laptop.AboveThreshold,
		6144,
		0,
		"All-world candidate count remains explicit even when capped"
	)
	near(
		Snapshot.Record(laptop, 1),
		6144 - 255,
		0,
		"Strongest-cell selection scans the full world instead of its origin corner"
	)
	local full = fields(48 * 6 * 48)
	for index = 1, 48 * 6 * 48 do
		buffer.writef64(full.qc, (index - 1) * 8, 0.0001)
	end
	local fullPayload = Snapshot.Encode(full, metadata(48, 6, 48), Snapshot.NewWorkspace(512))
	near(
		buffer.len(fullPayload),
		9320,
		0,
		"Full global summary remains 9,320 bytes at its fixed cap"
	)
	local f32 = fields(8, 4)
	buffer.writef32(f32.qc, 0, 0.0001)
	near(
		Snapshot.Decode(Snapshot.Encode(f32, metadata(2, 2, 2), work, nil, 4)).Count,
		1,
		0,
		"Codec can summarize existing float32 local diagnostic fields"
	)

	local function corrupt(offset: number, writer: any, value: number): buffer
		local copy = buffer.create(buffer.len(payload))
		buffer.copy(copy, 0, payload)
		writer(copy, offset, value)
		return copy
	end
	rejects(function()
		Snapshot.Decode(buffer.create(10))
	end, "Truncated network header is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(0, buffer.writeu32, 0))
	end, "Incorrect network magic is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(4, buffer.writeu8, 99))
	end, "Unsupported snapshot version is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(5, buffer.writeu8, 255))
	end, "Unexpected debug flag bits are rejected")
	rejects(function()
		Snapshot.Decode(corrupt(12, buffer.writeu16, 500))
	end, "Invalid snapshot record count is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(14, buffer.writeu16, 513))
	end, "Network cap above the agreed bound is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(40, buffer.writef32, 0))
	end, "Invalid physical/stud ratio is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(24, buffer.writef64, 0 / 0))
	end, "NaN snapshot time is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(104, buffer.writeu16, 0))
	end, "Out-of-range network cell index is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(122, buffer.writeu16, 3))
	end, "Repeated cell records are rejected")
	rejects(function()
		Snapshot.Decode(corrupt(106, buffer.writef32, -0.1))
	end, "Negative network cloud water is rejected")
	rejects(function()
		Snapshot.Decode(corrupt(110, buffer.writef32, math.huge))
	end, "Infinite network velocity is rejected")
	rejects(function()
		Snapshot.NewWorkspace(513)
	end, "Snapshot workspace cannot expand beyond the hard cap")
	rejects(function()
		Snapshot.Interpolate(a, b, 1, 1.01)
	end, "Interpolation cannot extrapolate beyond authoritative summaries")
	local nanFields = fields(8)
	buffer.writef64(nanFields.qc, 0, 0 / 0)
	rejects(function()
		Snapshot.Encode(nanFields, metadata(2, 2, 2), work)
	end, "Invalid authoritative liquid cannot silently enter a snapshot")

	local hugeOrigin = metadata(2, 2, 2)
	hugeOrigin.MinXStuds = 1e15
	rejects(function()
		Snapshot.Encode(source, hugeOrigin, work)
	end, "Snapshot geometry rejects origins that collapse neighboring cells in float32")
	local hugeHeight = metadata(2, 2, 2)
	hugeHeight.LayerHeightStuds = 1e40
	rejects(function()
		Snapshot.Encode(source, hugeHeight, work)
	end, "Snapshot header rejects finite float64 heights that overflow float32")

	-- Real client renderer with Instance spies: this validates allocation and
	-- interpolation ownership, not Studio graphics performance.
	local graphics: { any } = {}
	local writes: { [string]: number } = {}
	local function newGraphic(className: string): any
		local props: any = { ClassName = className, Attributes = {}, Destroyed = false }
		local instance = setmetatable({}, {
			__index = function(_self: any, key: string): any
				if key == "SetAttribute" then
					return function(_same: any, name: string, value: any)
						props.Attributes[name] = value
					end
				elseif key == "Destroy" then
					return function(same: any)
						props.Destroyed = true
						for _, child in graphics do
							if child.Parent == same and not child.Destroyed then
								child:Destroy()
							end
						end
					end
				end
				return props[key]
			end,
			__newindex = function(_self: any, key: string, value: any)
				writes[key] = (writes[key] or 0) + 1
				props[key] = value
			end,
		})
		table.insert(graphics, instance)
		return instance
	end
	local executeGraphics = luau.load(
		"return function(script,require,Instance,Color3,Enum,Vector3,CFrame,workspace)\n"
			.. fs.readFile("src/shared/Atmosphere/World/WorldVoxelDebugRenderer.lua")
			.. "\nend",
		{
			debugName = "@src/shared/Atmosphere/World/WorldVoxelDebugRenderer.lua",
			codegenEnabled = true,
		}
	)
	local GraphicRenderer = executeGraphics()(
		root.World.WorldVoxelDebugRenderer,
		loadModule,
		{ new = newGraphic },
		roblox.Color3,
		{ Material = { SmoothPlastic = "SmoothPlastic" } },
		roblox.Vector3,
		roblox.CFrame,
		{}
	)
	local diagnostic = GraphicRenderer.new(32)
	local denseBytesBefore = buffer.tostring(large.qc)
	near(
		diagnostic:Update(laptop, laptop, 1),
		16,
		0,
		"Client debug pool creates at most sixteen qc Parts per update"
	)
	near(
		diagnostic:Update(laptop, laptop, 1),
		32,
		0,
		"Bounded later updates complete the selected diagnostic pool"
	)
	near(#diagnostic.Pool, 32, 0, "World debug graphics never instantiate the global grid")
	table.clear(writes)
	diagnostic:Update(laptop, laptop, 1)
	near(
		writes.Position or 0,
		0,
		0,
		"Retained fixed world cells do not receive repeated position writes"
	)
	near(writes.Size or 0, 0, 0, "Retained world cells reuse their geometry")
	near(writes.Transparency or 0, 0, 0, "Unchanged interpolated water reuses quantized opacity")
	check(
		buffer.tostring(large.qc) == denseBytesBefore,
		"Diagnostic graphics never modify authoritative physical liquid"
	)
	diagnostic:SetLimit(8)
	near(
		diagnostic:Update(laptop, laptop, 1),
		8,
		0,
		"Client visual limit can decrease without resetting physics"
	)
	near(#diagnostic.Pool, 32, 0, "Inactive Parts remain pooled for reuse instead of recreation")
	local flagMeta = metadata(32, 6, 32)
	flagMeta.DebugRegions, flagMeta.DebugVectors = true, true
	local visualFlags =
		Snapshot.Decode(Snapshot.Encode(large, flagMeta, Snapshot.NewWorkspace(256)))
	diagnostic:Update(visualFlags, visualFlags, 1)
	near(#diagnostic.Regions, 10, 0, "The four-by-four region grid uses only ten diagnostic lines")
	near(
		#diagnostic.Vectors,
		8,
		0,
		"Velocity-vector graphics are bounded by visible selected cells"
	)
	near(
		GraphicRenderer.VectorLimit,
		16,
		0,
		"Velocity-vector debug mode has a fixed sixteen-Part cap"
	)
	local folderBefore = diagnostic.Folder
	diagnostic:Destroy()
	check(folderBefore.Destroyed, "Client cleanup destroys its own diagnostic folder")
	for _, graphic in graphics do
		check(graphic.Destroyed, "Client cleanup releases every allocated diagnostic Instance")
	end
	rejects(function()
		GraphicRenderer.new(513)
	end, "Client graphics cannot exceed the hard debug Instance cap")

	local serverRoot, loadServer = createLoader("src/server/Simulation", {
		game = {
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage")
				return { Shared = { Atmosphere = root } }
			end,
		},
	})
	local Replication = loadServer(serverRoot.WeatherReplication)
	local broadcasts: { buffer } = {}
	local handler: any = nil
	local destroyed = false
	local transport = {
		Broadcast = function(message: buffer)
			table.insert(broadcasts, message)
		end,
		SetRequestHandler = function(callback: any)
			handler = callback
		end,
		Destroy = function()
			destroyed = true
		end,
	}
	local world = {
		Dims = { SizeX = 2, SizeY = 2, SizeZ = 2 },
		Coordinates = coordinate,
		State = { Fields = source, Grid = { SizeX = 2, SizeY = 2, SizeZ = 2 } },
		Time = 0,
		ValueBytes = 8,
		GetDiagnostics = function()
			return { MaxCourant = 0.1 }
		end,
	}
	local replication = Replication.new(world, { Seed = 0, MaxRecords = 2, RateHz = 1 }, transport)
	near(#broadcasts, 1, 0, "Replication publishes one initial authoritative summary")
	local playerA = { Position = { -1900, 70, -1900 } }
	local playerB = { Position = { 1900, 70, 1900 } }
	local joinedA, joinedB = handler(playerA), handler(playerB)
	check(
		joinedA == joinedB and joinedA == replication.Latest,
		"Distant simultaneous players receive one identical cached authoritative payload"
	)
	check(
		buffer.tostring(joinedA) == buffer.tostring(joinedB),
		"Multiplayer field summaries are byte-identical"
	)
	near(
		Snapshot.Decode(joinedA).Seed,
		0,
		0,
		"Canonical seed zero survives read-only late-join replication"
	)
	check(handler(playerA) == nil, "Repeated late-join requests are rate limited per player")
	for _ = 1, 9 do
		replication:Update(0.1)
	end
	near(#broadcasts, 1, 0, "Network updates do not run each Heartbeat")
	replication:Update(0.11)
	near(#broadcasts, 2, 0, "Laptop network summary is broadcast at its bounded one-Hz cadence")
	world.Time = 15
	replication:Update(20)
	near(
		#broadcasts,
		3,
		0,
		"Stalled Heartbeat sends only one latest state instead of a network catch-up burst"
	)
	near(
		replication:GetDiagnostics().SnapshotUpdatesDropped,
		19,
		0,
		"Skipped snapshot opportunities are explicitly diagnosed"
	)
	near(
		Snapshot.Decode(broadcasts[3]).Time,
		15,
		0,
		"Network stall does not advance or reset authoritative physics time"
	)
	check(
		handler(playerA) == replication.Latest,
		"Late client refresh reads current server cache after its rate-limit interval"
	)
	local old = Snapshot.Decode(replication.Latest)
	local replacement = table.clone(world)
	replacement.Time = 0
	replication:SetField(replacement, -1)
	near(
		#broadcasts,
		4,
		0,
		"Explicit regeneration updates clients without replacing network Instances"
	)
	local changed = Snapshot.Decode(replication.Latest)
	near(
		changed.Generation,
		old.Generation + 1,
		0,
		"World regeneration increments the snapshot epoch"
	)
	check(
		not Snapshot.Compatible(old, changed),
		"Clients cannot mix old-world liquid with regenerated fields"
	)
	replication:SetDebugFlags(true, true)
	replication:Update(1)
	local flagged = Snapshot.Decode(replication.Latest)
	check(
		flagged.DebugRegions and flagged.DebugVectors,
		"Live server diagnostic flags propagate on the existing snapshot channel"
	)
	replication:SetDebugEnabled(false)
	replication:Update(1)
	check(
		not Snapshot.Decode(replication.Latest).DebugEnabled,
		"Disabling diagnostic graphics does not disable world transport"
	)
	handler({ RemovedPlayer = playerA })
	check(handler(playerA) ~= nil, "Departed players release request-limiter storage")
	near(
		replication:GetDiagnostics().SnapshotLastBytes,
		140,
		0,
		"Replication reports actual payload bytes"
	)
	near(
		replication:GetDiagnostics().SnapshotRequestsRejected,
		1,
		0,
		"Read-only request throttling is measurable"
	)
	replication:Destroy()
	check(
		destroyed and replication.Latest == nil,
		"Replication cleanup releases transport and snapshot ownership"
	)
	check(handler(playerB) == nil, "Destroyed replication cannot serve stale field state")
	rejects(function()
		Replication.new(world, { RateHz = 10 }, transport)
	end, "Unsupported high-rate world snapshots are rejected")

	local ProductionField = loadModule(root.World.WeatherField)
	local actualField = ProductionField.new(
		coordinate,
		{ SizeX = 4, SizeY = 3, SizeZ = 4, BackgroundU = 8, BackgroundV = 2 }
	)
	local actualPacket: buffer? = nil
	local actualReplication = Replication.new(
		actualField,
		{ Seed = -3, MaxRecords = 2, RateHz = 1 },
		{
			Broadcast = function(message: buffer)
				actualPacket = message
			end,
			SetRequestHandler = function() end,
		}
	)
	local actualDecoded = Snapshot.Decode(actualPacket :: buffer)
	near(
		actualDecoded.SizeX,
		actualField.State.Grid.SizeX,
		0,
		"Replication reads the production world field's actual grid contract"
	)
	near(
		actualDecoded.Count,
		0,
		0,
		"A newly initialized production world snapshot never paints cloud water"
	)
	near(
		actualDecoded.LayerHeightStuds,
		coordinate.HeightMeters * coordinate.StudsPerMeter / 3,
		0,
		"Production replication uses the single physical-to-stud vertical conversion"
	)
	actualField:Step(0.25)
	actualReplication:Update(1)
	near(
		Snapshot.Decode(actualPacket :: buffer).Time,
		0.25,
		0,
		"Production physics evolution reaches the existing authoritative snapshot channel"
	)
	actualReplication:Destroy()

	local alternate: { buffer } = {}
	local alternateTransport = {
		Broadcast = function(p: buffer)
			table.insert(alternate, p)
		end,
		SetRequestHandler = function() end,
	}
	local alternateField = table.clone(world)
	alternateField.Time = 0
	local segmented = Replication.new(
		alternateField,
		{ Seed = 0, MaxRecords = 2, RateHz = 2 },
		alternateTransport
	)
	segmented:Update(0.25)
	segmented:Update(0.25)
	near(#alternate, 2, 0, "Full snapshot cadence remains bounded at two Hz")
	segmented:Destroy()
end
