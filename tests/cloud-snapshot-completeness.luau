--!strict

local createLoader = require("./RobloxModuleLoader")

return function(root: any, loadModule: any, check: any, near: any, rejects: any, _quick: boolean?)
	local Snapshot = loadModule(root.Rendering.CloudRenderSnapshot)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local Field = loadModule(root.World.WeatherField)
	local Diagnostic = loadModule(root.World.WeatherSnapshot)
	local coordinates = Coordinates.new()
	local function field(nx: number, ny: number, nz: number): any
		return Field.new(coordinates, {
			SizeX = nx,
			SizeY = ny,
			SizeZ = nz,
			BackgroundU = 8,
			BackgroundV = -2,
			ShearU = 0,
			ShearV = 0,
			StreamfunctionAmplitude = 0,
			Microphysics = false,
		})
	end
	local source = field(8, 3, 12)
	local count = source.Grid.Count
	for index = 1, count do
		source.State:Set("qc", index, 0.0003 * (index / count) ^ 2)
	end
	local original: { [string]: string } = {}
	for name, values in source.Fields do
		original[name] = buffer.tostring(values)
	end
	local payload = Snapshot.Encode(source, { Seed = -84219, WallTime = 0.5, DroppedTime = 0.25 })
	local snapshot = Snapshot.Decode(payload)
	near(snapshot.Version, 1, 0, "Complete render data has its own versioned protocol")
	check(snapshot.Complete, "The render codec requires a complete density field")
	near(snapshot.Count, count, 0, "All world cells are represented, including low-liquid edges")
	near(snapshot.Seed, -84219, 0, "Complete snapshot preserves negative canonical seeds")
	near(snapshot.QcOffset, 128, 0, "Version 1 complete density begins after its documented header")
	near(
		snapshot.VelocityOffset,
		128 + count,
		0,
		"Complete velocity data follows every density byte"
	)
	near(
		snapshot.VelocityCount,
		2 * 3 * 3,
		0,
		"Independent velocity lattice is complete at one-quarter horizontal resolution"
	)
	near(
		buffer.len(payload),
		128 + count + 18 * 6,
		0,
		"Actual packet follows the bounded density and vector layout"
	)
	check(
		buffer.tostring(payload)
			== buffer.tostring(
				Snapshot.Encode(source, { Seed = -84219, WallTime = 0.5, DroppedTime = 0.25 })
			),
		"Identical field and metadata encode byte-identically"
	)
	local errorBound = snapshot.MaxQc * (1 / 255 + 1 / (4 * 255 ^ 2))
	local observedError = 0
	for index = 1, count do
		local qc, known = Snapshot.ReadQC(snapshot, index)
		local exact = source.State:Get("qc", index)
		check(known, "Every valid render cell is known, rather than absent sparse data")
		check(
			qc >= 0 and qc <= snapshot.MaxQc and qc == qc,
			"Quantized cloud water is nonnegative, bounded and finite"
		)
		check(
			math.abs(qc - exact) <= errorBound,
			"Square-root concentration companding respects its analytical error bound"
		)
		observedError = math.max(observedError, math.abs(qc - exact))
	end
	local unknown, known = Snapshot.ReadQC(snapshot, count + 1)
	near(unknown, 0, 0, "An unknown read has a safe numeric placeholder")
	check(not known, "An out-of-domain cell is explicitly unknown, never a known zero")
	for _, invalid in { 0, -1, 1.5, 0 / 0, math.huge } do
		local _, valid = Snapshot.ReadQC(snapshot, invalid)
		check(not valid, "Malformed indices never claim data completeness")
	end
	for y = 1, source.SizeY do
		for z = 1, source.SizeZ do
			for x = 1, source.SizeX do
				local index = source.Grid:Index(x, y, z)
				local sx, sy, sz = Snapshot.CellCenter(snapshot, index)
				local wx, wy, wz =
					coordinates:CellCenterWorld(x, y, z, source.SizeX, source.SizeY, source.SizeZ)
				near(sx, wx, 0, "Encoded X-fast coordinates agree with the real world geometry")
				near(sy, wy, 0, "Encoded altitude remains distinct from physical meters")
				near(sz, wz, 0, "Encoded Z-next coordinates agree across logical regions")
			end
		end
	end
	for name, values in source.Fields do
		check(
			buffer.tostring(values) == original[name],
			"Encoding and decoding never mutate authoritative " .. name
		)
	end
	local decodedBytesBefore = buffer.tostring(payload)
	for index = 1, snapshot.VelocityCount do
		local u, v, w = Snapshot.ReadVelocity(snapshot, index)
		near(u, 8, snapshot.VelocityScale / 2, "Velocity quantization retains physical X m/s")
		near(v, -2, snapshot.VelocityScale / 2, "Velocity quantization retains physical Z m/s")
		near(w, 0, 0, "Velocity quantization retains physical Y m/s")
	end
	check(
		buffer.tostring(payload) == decodedBytesBefore,
		"Client sampling leaves the retained wire buffer unchanged"
	)
	check(
		snapshot.Payload == payload,
		"Decoding retains compact wire bytes without expanding a full cell table"
	)

	-- Asymmetric gradients expose incorrect lattice spacing and axis ordering.
	for y = 1, source.SizeY do
		for z = 1, source.SizeZ do
			for x = 1, source.SizeX do
				local index = source.Grid:Index(x, y, z)
				source.State:Set("u", index, x + 2 * z + 3 * y)
				source.State:Set("v", index, -x + 3 * z - y)
				source.State:Set("w", index, y * 0.1)
			end
		end
	end
	local gradient = Snapshot.Decode(Snapshot.Encode(source))
	for y = 1, gradient.VelocitySizeY do
		for z = 1, gradient.VelocitySizeZ do
			for x = 1, gradient.VelocitySizeX do
				local index = ((y - 1) * gradient.VelocitySizeZ + z - 1) * gradient.VelocitySizeX
					+ x
				local wx = gradient.MinXStuds
					+ (x - 0.5) * gradient.WidthStuds / gradient.VelocitySizeX
				local wy = gradient.BottomYStuds + (y - 0.5) * gradient.LayerHeightStuds
				local wz = gradient.MinZStuds
					+ (z - 0.5) * gradient.DepthStuds / gradient.VelocitySizeZ
				local u, v, w = Snapshot.ReadVelocity(gradient, index)
				near(
					u,
					source:SampleWorld(wx, wy, wz, "u"),
					gradient.VelocityScale / 2,
					"Coarse u is sampled at its actual shared-world cell center"
				)
				near(
					v,
					source:SampleWorld(wx, wy, wz, "v"),
					gradient.VelocityScale / 2,
					"Coarse v uses Z coordinates rather than an aliased qc index"
				)
				near(
					w,
					source:SampleWorld(wx, wy, wz, "w"),
					gradient.VelocityScale / 2,
					"Coarse w uses the unchanged authoritative altitude layer"
				)
			end
		end
	end
	local empty = field(8, 3, 12)
	local clear = Snapshot.Decode(Snapshot.Encode(empty, { Seed = 0 }))
	near(clear.MaxQc, 0, 0, "A clear field has exactly zero concentration scale")
	near(clear.Seed, 0, 0, "Seed zero is not replaced by a development fallback")
	for index = 1, count do
		local qc, available = Snapshot.ReadQC(clear, index)
		near(qc, 0, 0, "Empty weather remains exactly empty after complete quantization")
		check(available, "Transmitted clear cells are explicitly known quantized zeros")
	end
	empty.State:Set("qc", 1, 1e-15)
	empty.State:Set("qc", 2, 1e-4)
	local roundedTiny = Snapshot.Decode(Snapshot.Encode(empty))
	local tiny, tinyKnown = Snapshot.ReadQC(roundedTiny, 1)
	near(tiny, 0, 0, "Concentrations below the specified quantization floor round to zero")
	check(
		tinyKnown,
		"A quantized zero remains known data, not a claim that the physical cell was exactly empty"
	)
	empty.State:Fill("qc", 0)
	-- The wire format also accepts existing float32 core-state buffers. This
	-- fixture is storage only; production codec math is exercised unchanged.
	local f32: any = {
		State = { Grid = { SizeX = 2, SizeY = 2, SizeZ = 2 }, Fields = {} },
		Coordinates = coordinates,
		ValueBytes = 4,
		Time = 0,
	}
	for _, name in { "qc", "u", "v", "w" } do
		f32.State.Fields[name] = buffer.create(8 * 4)
	end
	buffer.writef32(f32.State.Fields.qc, 0, 1e-4)
	local fromF32 = Snapshot.Decode(Snapshot.Encode(f32))
	near(
		Snapshot.ReadQC(fromF32, 1),
		1e-4,
		fromF32.MaxQc / 255,
		"The complete codec preserves the packed float32 storage boundary"
	)
	local diagMeta = {
		SizeX = source.SizeX,
		SizeY = source.SizeY,
		SizeZ = source.SizeZ,
		Seed = 0,
		Time = 0,
		WidthStuds = 4028,
		DepthStuds = 4028,
		StudsPerMeter = 2,
		MinXStuds = -2014,
		MinZStuds = -2014,
		BottomYStuds = 424,
		LayerHeightStuds = 48,
	}
	local diagnosticPayload =
		Diagnostic.Encode(source.Fields, diagMeta, Diagnostic.NewWorkspace(1), 1e-8)
	local sparse = Diagnostic.Decode(diagnosticPayload)
	near(sparse.Count, 1, 0, "Existing top-K diagnostics remain available and explicitly sparse")
	rejects(function()
		Snapshot.Decode(diagnosticPayload)
	end, "Sparse diagnostic snapshots cannot enter complete reconstruction")
	local edgeQc, edgeKnown = Snapshot.ReadQC(snapshot, 1)
	check(
		edgeKnown and edgeQc > 0,
		"Complete rendering retains weak source edges omitted by top-K selection"
	)

	local laptop = field(32, 6, 32)
	local full = field(48, 6, 48)
	near(
		buffer.len(Snapshot.Encode(laptop)),
		8576,
		0,
		"Laptop complete data is 8,576 bytes per publication"
	)
	near(
		buffer.len(Snapshot.Encode(full)),
		19136,
		0,
		"Full complete data is 19,136 bytes per publication"
	)
	local function corrupt(offset: number, writer: any, value: number): buffer
		local copy = buffer.create(buffer.len(payload))
		buffer.copy(copy, 0, payload)
		writer(copy, offset, value)
		return copy
	end
	for _, change in
		{
			{ 0, buffer.writeu32, 0 },
			{ 4, buffer.writeu8, 99 },
			{ 5, buffer.writeu8, 2 },
			{ 5, buffer.writeu8, 255 },
			{ 6, buffer.writeu16, 64 },
			{ 8, buffer.writeu16, 0 },
			{ 14, buffer.writeu16, 0 },
			{ 16, buffer.writeu16, 1 },
			{ 32, buffer.writef64, 0 / 0 },
			{ 40, buffer.writef64, -1 },
			{ 48, buffer.writef64, math.huge },
			{ 56, buffer.writef32, 1e15 },
			{ 64, buffer.writef32, 0 },
			{ 76, buffer.writef32, -1 },
			{ 80, buffer.writef32, 0 },
			{ 84, buffer.writef32, math.huge },
			{ 88, buffer.writef32, -1 },
			{ 88, buffer.writef32, 0 },
			{ 92, buffer.writef32, 0 },
			{ 96, buffer.writeu32, count - 1 },
			{ 100, buffer.writeu32, 1 },
			{ 104, buffer.writeu32, 999 },
			{ 108, buffer.writeu32, 1 },
		}
	do
		rejects(function()
			Snapshot.Decode(corrupt(change[1], change[2], change[3]))
		end, "Invalid or incomplete cloud-render headers are rejected")
	end
	rejects(function()
		Snapshot.Decode(buffer.create(127))
	end, "Truncated complete header is rejected")
	local truncated = buffer.create(buffer.len(payload) - 1)
	buffer.copy(truncated, 0, payload, 0, buffer.len(truncated))
	rejects(function()
		Snapshot.Decode(truncated)
	end, "Missing density or velocity payload bytes remain unknown, not empty")
	rejects(function()
		Snapshot.Decode(buffer.create(65537))
	end, "Packets beyond the hard 64 KiB limit are rejected")
	rejects(function()
		Snapshot.Encode({
			State = { Grid = { SizeX = 128, SizeY = 4, SizeZ = 128 }, Fields = {} },
			Coordinates = coordinates,
		})
	end, "Encoding cannot expand beyond the configured packet budget")
	for _, invalid in { 0 / 0, math.huge, -0.1 } do
		local saved = empty.State:Get("qc", 1)
		buffer.writef64(empty.Fields.qc, 0, invalid)
		rejects(function()
			Snapshot.Encode(empty)
		end, "Invalid physical water is rejected before publication")
		buffer.writef64(empty.Fields.qc, 0, saved)
	end
	buffer.writef64(empty.Fields.u, 0, 0 / 0)
	rejects(function()
		Snapshot.Encode(empty)
	end, "Invalid velocity is rejected even when liquid is absent")
	buffer.writef64(empty.Fields.u, 0, 8)
	rejects(function()
		Snapshot.Encode(empty, { Seed = 0.5 })
	end, "Render generation rejects fractional seeds")

	local a = Snapshot.Decode(
		Snapshot.Encode(source, { Generation = 0, Sequence = 1, Time = 1, WallTime = 1 })
	)
	local b = Snapshot.Decode(
		Snapshot.Encode(source, { Generation = 0, Sequence = 2, Time = 1, WallTime = 2 })
	)
	check(
		Snapshot.Compatible(a, b) and Snapshot.IsNewer(a, b),
		"Paused simulation still accepts new wall-clock snapshots without extrapolating"
	)
	check(
		not Snapshot.IsNewer(b, a) and not Snapshot.IsNewer(a, a),
		"Duplicate and out-of-order sequences cannot replace current state"
	)
	local oldTime = Snapshot.Decode(
		Snapshot.Encode(source, { Generation = 0, Sequence = 3, Time = 0, WallTime = 3 })
	)
	check(
		not Snapshot.IsNewer(b, oldTime),
		"A later sequence cannot secretly roll back the atmospheric timeline"
	)
	local reset = Snapshot.Decode(
		Snapshot.Encode(source, { Seed = 1, Generation = 1, Sequence = 0, Time = 0, WallTime = 3 })
	)
	check(
		Snapshot.IsNewer(b, reset) and not Snapshot.IsNewer(reset, b),
		"Weather regeneration accepts a new epoch and rejects late old-epoch data"
	)
	check(
		not Snapshot.Compatible(b, reset),
		"New world seed and generation invalidate interpolation history"
	)
	local sealed = field(8, 3, 12)
	sealed.Boundary = "Sealed"
	local closed = Snapshot.Decode(Snapshot.Encode(sealed))
	check(
		closed.Boundary == "Sealed" and not Snapshot.Compatible(clear, closed),
		"Outer boundary conditions are transmitted and included in compatibility"
	)

	local serverRoot, loadServer = createLoader("src/server/Simulation", {
		game = {
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage")
				return { Shared = { Atmosphere = root } }
			end,
		},
	})
	local Replication = loadServer(serverRoot.CloudRenderReplication)
	local broadcasts: { buffer } = {}
	local handler: any = nil
	local destroyed = 0
	local transport = {
		Broadcast = function(data: buffer)
			table.insert(broadcasts, data)
		end,
		SetRequestHandler = function(callback: any)
			handler = callback
		end,
		Destroy = function()
			destroyed += 1
		end,
	}
	local replication = Replication.new(laptop, { Seed = 0 }, transport)
	near(
		#broadcasts,
		1,
		0,
		"Complete render replication immediately caches one current-world snapshot"
	)
	local playerA, playerB = {}, {}
	local joinedA, joinedB = handler(playerA), handler(playerB)
	check(
		joinedA == joinedB and joinedA == replication.Latest,
		"Late joins in distant regions receive the exact same authoritative packet"
	)
	near(Snapshot.Decode(joinedA).Seed, 0, 0, "Late-join generation preserves canonical zero seed")
	check(
		handler(playerA) == nil,
		"Repeated read-only requests are limited to one per player per two wall seconds"
	)
	for _ = 1, 9 do
		replication:Update(0.1)
	end
	near(#broadcasts, 1, 0, "Render data is not broadcast every Heartbeat")
	replication:Update(0.11)
	near(#broadcasts, 2, 0, "Default render publication is one Hz for every preset")
	replication:Update(10)
	near(
		#broadcasts,
		3,
		0,
		"A stalled server sends one current snapshot instead of a catch-up burst"
	)
	near(
		replication:GetDiagnostics().RenderDataUpdatesDropped,
		9,
		0,
		"Skipped publication opportunities are explicitly counted"
	)
	check(
		handler(playerA) ~= nil,
		"Late-join retry is available after the bounded request interval"
	)
	handler({ RemovedPlayer = playerA })
	check(
		replication.LastRequests[playerA] == nil,
		"Departed players release request-limiter storage"
	)
	local oldField, oldPacket = replication.Field, replication.Latest
	rejects(function()
		replication:SetField(full, 1.5)
	end, "An invalid replacement generation is not published")
	check(
		replication.Field == oldField and replication.Latest == oldPacket,
		"Failed replacement preserves the last complete usable field"
	)
	replication:SetField(full, -1)
	local replaced = Snapshot.Decode(replication.Latest)
	near(replaced.Generation, 1, 0, "Safe regeneration increments the render generation")
	near(replaced.Seed, -1, 0, "Safe regeneration may choose a negative world seed")
	near(
		buffer.len(replication.Latest),
		19136,
		0,
		"Regeneration immediately supplies a complete Full-preset silhouette"
	)
	local diag = replication:GetDiagnostics()
	near(
		diag.RenderDataBytesPerSecond,
		19136,
		0,
		"Rate diagnostics report actual bytes before transport compression and per-player fanout"
	)
	check(
		diag.RenderDataComplete and diag.RenderDataLastEncodeMilliseconds >= 0,
		"Publication exposes completeness and measured encoding CPU time"
	)
	rejects(function()
		Replication.new(source, { RateHz = 2.1 }, transport)
	end, "Server render rate cannot exceed two Hz")
	rejects(function()
		replication:Update(-1)
	end, "Invalid wall time cannot influence publication scheduling")
	replication:Destroy()
	replication:Destroy()
	near(destroyed, 1, 0, "Shutdown releases its channel exactly once")
	check(
		replication.Latest == nil and handler(playerB) == nil,
		"Shutdown releases cached bytes and refuses subsequent requests"
	)
	rejects(function()
		replication:Publish()
	end, "Destroyed render replication cannot broadcast")
	local failingDestroyed = false
	rejects(function()
		Replication.new(source, { Seed = 0.5 }, {
			Broadcast = function(_data: buffer) end,
			SetRequestHandler = function(_handler: any) end,
			Destroy = function()
				failingDestroyed = true
			end,
		})
	end, "Invalid initialization reports a meaningful failure")
	check(failingDestroyed, "Failed render initialization cleans up the newly created channel")
	local LegacyReplication = loadServer(serverRoot.WeatherReplication)
	local legacyFailureDestroyed, legacyFailurePublished = false, false
	local savedQc = source.State:Get("qc", 1)
	buffer.writef64(source.Fields.qc, 0, 0 / 0)
	rejects(function()
		LegacyReplication.new(source, { Seed = 0, MaxRecords = 8 }, {
			Broadcast = function(_data: buffer)
				legacyFailurePublished = true
			end,
			SetRequestHandler = function(_handler: any) end,
			Destroy = function()
				legacyFailureDestroyed = true
			end,
		})
	end, "Existing diagnostic replication rejects an invalid authoritative initial field")
	buffer.writef64(source.Fields.qc, 0, savedQc)
	check(
		legacyFailureDestroyed and not legacyFailurePublished,
		"Failed diagnostic initialization releases ownership without publishing invalid data"
	)
	return {
		Format = "WCR2 v1 complete uint8 sqrt(qc/MaxQc), coarse signed-int16 m/s lattice",
		HeaderBytes = 128,
		LaptopBytes = 8576,
		FullBytes = 19136,
		RateHz = 1,
		MaxBytes = Snapshot.MaxPayloadBytes,
		MeasuredQuantizationMaxErrorKgKg = observedError,
		AnalyticalQuantizationBoundKgKg = errorBound,
		SparseDiagnosticCodecUnchanged = true,
		PhysicalBuffersMutated = false,
	}
end
