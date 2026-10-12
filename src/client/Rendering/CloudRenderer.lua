--!strict

-- Complete authoritative qc -> sparse, truly three-dimensional cubic voxels.
-- The 48-stud world-aligned construction lattice is never drawn as a tile:
-- occupied nodes are subdivided in X, Y AND Z into 12/16/24/48-stud cubes.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rendering = ReplicatedStorage.Shared.Atmosphere.Rendering
local Config = require(Rendering.CloudRenderConfig)
local Detail = require(Rendering.CloudDetailNoise)
local Lighting = require(Rendering.CloudLighting)
local LOD = require(Rendering.CloudRenderLOD)
local Surface = require(Rendering.CloudSurfaceAnalysis)
local Pool = require(script.Parent.CloudClusterPool)
local Renderer = {}
Renderer.__index = Renderer
local SIDE, MIN_SIDE = 48, 12
local MAX_CONSTRUCTION_NODES = 262144
local STRIDE = 80
local ID, COLUMN, X, Y, Z, HEIGHT, SIZE, UNUSED, SCORE, TIME = 0, 8, 16, 24, 32, 40, 48, 56, 64, 72
local ENTER, LEAVE, FADE_SECONDS = 0.035, 0.022, 0.35
export type CameraInfo = {
	X: number,
	Y: number,
	Z: number,
	LookX: number?,
	LookY: number?,
	LookZ: number?,
}
export type LightingInfo = { SunX: number?, SunY: number?, SunZ: number?, Ambient: number? }
export type Options = {
	Quality: string?,
	Factory: ((string) -> any)?,
	Parent: any?,
	Clock: (() -> number)?,
	Layers: any?,
}
local function finite(v: number): boolean
	return v == v and math.abs(v) < math.huge
end
-- Geometry metadata is finite but may still describe an impractically tall
-- future atmosphere. Reject before allocating either a lattice or resources.
local function rootGeometry(snapshot: any): (number, number, number, number)
	local nx, nz, ny =
		math.ceil(snapshot.WidthStuds / SIDE),
		math.ceil(snapshot.DepthStuds / SIDE),
		math.ceil(snapshot.LayerHeightStuds * snapshot.SizeY / SIDE)
	local count = nx * nz * ny
	assert(
		finite(count) and count >= 1 and count <= MAX_CONSTRUCTION_NODES,
		"Cubic rendering geometry exceeds the 262144 construction-node budget"
	)
	return nx, nz, ny, count
end
local function read(b: buffer, i: number, f: number): number
	return buffer.readf64(b, (i - 1) * STRIDE + f)
end
local function write(b: buffer, i: number, f: number, v: number)
	buffer.writef64(b, (i - 1) * STRIDE + f, v)
end
local function resetScan(self: any)
	self.ScanIndex, self.RootCount, self.CandidateCount, self.RefineCursor, self.ChildCursor =
		1, 0, 0, 1, 1
	self.Phase = "Roots"
	self.EarlyRoot = nil
	self.RootsComplete = false
	table.clear(self.RootHeap)
	table.clear(self.Heap)
end
local function invalidate(self: any)
	self.Pool:Hide()
	self.SelectedCount, self.ClusterCount, self.UpdateCursor = 0, 0, 1
	self.SelectionMature = false
	table.clear(self.Wanted)
	table.clear(self.Clusters)
	table.clear(self.Flow)
	resetScan(self)
end
local function heapOffer(
	data: buffer,
	heap: { number },
	count: number,
	capacity: number,
	id: number,
	column: number,
	x: number,
	y: number,
	z: number,
	h: number,
	size: number,
	score: number,
	time: number
): (number, number?)
	local slot, position
	local inserting = count < capacity
	if inserting then
		count += 1
		slot, position = count, count
		heap[position] = slot
	else
		slot, position = heap[1], 1
		if score <= read(data, slot, SCORE) then
			return count, nil
		end
	end
	write(data, slot, ID, id)
	write(data, slot, COLUMN, column)
	write(data, slot, X, x)
	write(data, slot, Y, y)
	write(data, slot, Z, z)
	write(data, slot, HEIGHT, h)
	write(data, slot, SIZE, size)
	write(data, slot, SCORE, score)
	write(data, slot, TIME, time)
	if inserting then
		while position > 1 do
			local parent = math.floor(position / 2)
			if read(data, heap[parent], SCORE) <= score then
				break
			end
			heap[position], heap[parent] = heap[parent], heap[position]
			position = parent
		end
	else
		while position * 2 <= count do
			local child = position * 2
			if
				child < count
				and read(data, heap[child + 1], SCORE) < read(data, heap[child], SCORE)
			then
				child += 1
			end
			if read(data, heap[position], SCORE) <= read(data, heap[child], SCORE) then
				break
			end
			heap[position], heap[child] = heap[child], heap[position]
			position = child
		end
	end
	return count, slot
end
local function publishCandidates(self: any, wallNow: number, final: boolean?)
	-- Once a complete selection exists, keep it during partial future scans.
	-- Existing cubes continue resampling qc, so evaporation is never delayed.
	-- Cold starts still publish their first occupied region immediately.
	if self.SelectionMature and not final then
		return
	end
	-- No uninterruptible sort of thousands of candidate records. The bounded
	-- heap already holds the best samples; publication copies at most MaxCubes.
	table.clear(self.Wanted)
	table.clear(self.Clusters)
	local count, clusters = 0, 0
	for _, slot in self.Heap do
		count += 1
		buffer.copy(
			self.Selected,
			(count - 1) * STRIDE,
			self.Candidates,
			(slot - 1) * STRIDE,
			STRIDE
		)
		local id, root = read(self.Selected, count, ID), read(self.Selected, count, COLUMN)
		self.Wanted[id] = true
		if not self.Clusters[root] then
			self.Clusters[root] = true
			clusters += 1
		end
	end
	for id in self.Pool.Active do
		if not self.Wanted[id] then
			self.Pool:Release(id)
			self.Flow[id] = nil
		end
	end
	self.Pool:EndUpdate()
	self.SelectedCount, self.ClusterCount = count, clusters
	self.UpdateCursor = 1
	self.LastCommitWall = wallNow
	self.CandidatesSinceCommit = 0
	self.PublishedChunks += 1
	if final then
		self.SelectionMature = true
	end
end
function Renderer.new(reconstruction: any, options: Options?): any
	assert(
		type(reconstruction) == "table" and type(reconstruction.SampleDensity) == "function",
		"Cubic clouds require authoritative density reconstruction"
	)
	if reconstruction.Current then
		rootGeometry(reconstruction.Current)
	end
	local settings = options or {}
	local q = Config.GetQuality(settings.Quality)
	local self = setmetatable({
		Reconstruction = reconstruction,
		Quality = q,
		Pool = Pool.new({
			Limit = q.MaxCubes,
			InactiveLimit = q.MaxInactiveCubes,
			Factory = settings.Factory,
			Parent = settings.Parent,
		}),
		Clock = settings.Clock or os.clock,
		Layers = settings.Layers,
		Surface = Surface.new(),
		LastSnapshot = nil,
		Generation = nil,
		Seed = nil,
		DetailParameters = nil,
		Enabled = true,
		Destroyed = false,
		DebugMode = "None",
		Roots = buffer.create(q.MaxClusters * STRIDE),
		Candidates = buffer.create(q.MaxCubes * STRIDE),
		Selected = buffer.create(q.MaxCubes * STRIDE),
		RootHeap = table.create(q.MaxClusters),
		Heap = table.create(q.MaxCubes),
		Wanted = {},
		Clusters = {},
		Flow = {},
		LODHistory = buffer.create(0),
		ScanIndex = 1,
		RootCount = 0,
		CandidateCount = 0,
		RefineCursor = 1,
		ChildCursor = 1,
		Phase = "Roots",
		EarlyRoot = nil,
		RootsComplete = false,
		SelectedCount = 0,
		SelectionMature = false,
		ClusterCount = 0,
		UpdateCursor = 1,
		Accumulator = 0,
		CompletedScans = 0,
		PublishedChunks = 0,
		CandidatesSinceCommit = 0,
		LastCommitWall = 0,
		TotalUpdates = 0,
		BudgetOverruns = 0,
		LastUpdateMilliseconds = 0,
		MaxUpdateMilliseconds = 0,
		LastSourceQueries = 0,
		LastCubeUpdates = 0,
		LastNoiseEvaluations = 0,
		LastLightIntegrations = 0,
		ProjectedAreaProxy = 0,
		CameraRejected = 0,
		LastSampleWall = 0,
		OpticalSampler = nil,
		ScanCameraX = 0,
		ScanCameraZ = 0,
	}, Renderer)
	self.OpticalSampler = function(x: number, y: number, z: number): number
		return reconstruction:SampleDensity(x, y, z, self.LastSampleWall)
	end
	return self
end
function Renderer:SetQuality(name: string)
	assert(not self.Destroyed, "Cloud renderer was destroyed")
	local q = Config.GetQuality(name)
	if q == self.Quality then
		return
	end
	self.Quality = q
	self.Pool:SetLimit(q.MaxCubes, q.MaxInactiveCubes)
	self.Roots, self.Candidates, self.Selected =
		buffer.create(q.MaxClusters * STRIDE),
		buffer.create(q.MaxCubes * STRIDE),
		buffer.create(q.MaxCubes * STRIDE)
	self.RootHeap, self.Heap = table.create(q.MaxClusters), table.create(q.MaxCubes)
	invalidate(self)
end
function Renderer:SetDebugMode(mode: string)
	local m = string.lower(mode)
	assert(
		m == "none" or m == "density" or m == "gradients" or m == "bounds",
		"Cloud debug mode must be None, Density, Gradients, or Bounds"
	)
	self.DebugMode = if m == "none"
		then "None"
		elseif m == "density" then "Density"
		elseif m == "gradients" then "Gradients"
		else "Bounds"
end
function Renderer:SetEnabled(enabled: boolean)
	assert(type(enabled) == "boolean", "Visibility must be boolean")
	self.Enabled = enabled
	if not enabled then
		self:Hide()
	end
end
function Renderer:Hide()
	invalidate(self)
end
local function zigzag(index: number): number
	return if index % 2 == 0 then -index / 2 else (index + 1) / 2
end
local function scanRoot(self: any, s: any, wallNow: number, time: number, camera: CameraInfo)
	local nx, nz, ny = self.RootNX, self.RootNZ, self.RootNY
	local column = math.floor((self.ScanIndex - 1) / ny)
	local iy = (self.ScanIndex - 1) % ny
	local ix = (self.ScanCameraX + zigzag(column % nx)) % nx
	local iz = (self.ScanCameraZ + zigzag(math.floor(column / nx))) % nz
	local rootId = ix + iz * nx + iy * nx * nz + 1
	local bx, by, bz = s.MinXStuds + ix * SIDE, s.BottomYStuds + iy * SIDE, s.MinZStuds + iz * SIDE
	local cx, cy, cz = bx + SIDE / 2, by + SIDE / 2, bz + SIDE / 2
	local base, top, thickness, present = self.Surface:Sample(cx, cz)
	if not present or math.min(top, by + SIDE) - math.max(base, by) < MIN_SIDE then
		return
	end
	cy = math.clamp(cy, math.max(base, by) + MIN_SIDE / 2, math.min(top, by + SIDE) - MIN_SIDE / 2)
	local distance = math.sqrt((cx - camera.X) ^ 2 + (cy - camera.Y) ^ 2 + (cz - camera.Z) ^ 2)
	local previous = buffer.readu8(self.LODHistory, rootId - 1)
	local level, maxDiv, _, priority =
		LOD.Decide(distance, if previous == 255 then nil else previous, self.Quality)
	buffer.writeu8(self.LODHistory, rootId - 1, level)
	if level == 0 then
		self.CameraRejected += 1
		return
	end
	if camera.LookX and camera.LookY and camera.LookZ and distance > 160 then
		if
			(
					(cx - camera.X) * camera.LookX
					+ (cy - camera.Y) * camera.LookY
					+ (cz - camera.Z) * camera.LookZ
				)
				/ distance
			< -0.25
		then
			self.CameraRejected += 1
			return
		end
	end
	local density = self.Reconstruction:SampleDensity(cx, cy, cz, wallNow)
	self.LastSourceQueries += 1
	if density < LEAVE then
		return
	end
	local h = math.clamp((cy - base) / thickness, 0, 1)
	local preferred = Config.Layer(h, self.Layers)
	local gx, gy, gz = self.Reconstruction:Gradient(cx, cy, cz, wallNow)
	local edge = math.sqrt(gx * gx + gy * gy + gz * gz) * SIDE / math.max(0.03, density)
	local desired = SIDE / preferred
	if edge > 0.3 then
		desired = 4
	elseif density > 0.65 and h > 0.25 then
		desired = math.max(1, desired - 1)
	end
	-- Seeded dithering blends adjacent cubic subdivision levels without a
	-- camera-dependent placement seed or rigid global horizontal stripes.
	local jitter = Detail.Offsets(self.DetailParameters, rootId, 1) + 0.42
	local divisions = math.floor(desired) + (if jitter / 0.84 < desired % 1 then 1 else 0)
	divisions = math.clamp(math.min(divisions, maxDiv), 1, 4)
	if thickness < SIDE / divisions then
		divisions = math.min(4, math.max(divisions, math.ceil(SIDE / thickness)))
	end
	local score = density * (0.25 + priority)
	local slot
	self.RootCount, slot = heapOffer(
		self.Roots,
		self.RootHeap,
		self.RootCount,
		self.Quality.MaxClusters,
		rootId,
		rootId,
		bx,
		by,
		bz,
		h,
		divisions,
		score,
		time
	)
	-- Publish an early real volume before scanning the whole world. The normal
	-- global frontier continues afterwards and can replace this provisional ROI.
	if slot and self.SelectedCount == 0 and self.CandidateCount == 0 and not self.EarlyRoot then
		buffer.copy(self.Early, 0, self.Roots, (slot - 1) * STRIDE, STRIDE)
		self.EarlyRoot = true
		self.ChildCursor = 1
		self.Phase = "Early"
	end
end
local function sampleChild(
	self: any,
	s: any,
	node: buffer,
	slot: number,
	wallNow: number,
	time: number
)
	local n = read(node, slot, SIZE)
	local side = SIDE / n
	local child = self.ChildCursor - 1
	local ix, iz, iy = child % n, math.floor(child / n) % n, math.floor(child / (n * n))
	local x, y, z =
		read(node, slot, X) + (ix + 0.5) * side,
		read(node, slot, Y) + (iy + 0.5) * side,
		read(node, slot, Z) + (iz + 0.5) * side
	local base, top, thickness, known = self.Surface:Sample(x, z)
	local half = side / 2
	if
		not known
		or y - half < base - 0.001
		or y + half > top + 0.001
		or y - half < s.BottomYStuds - 0.001
		or y + half > s.BottomYStuds + s.LayerHeightStuds * s.SizeY + 0.001
		or x - half < s.MinXStuds - 0.001
		or x + half > s.MinXStuds + s.WidthStuds + 0.001
		or z - half < s.MinZStuds - 0.001
		or z + half > s.MinZStuds + s.DepthStuds + 0.001
	then
		return
	end
	local density = self.Reconstruction:SampleDensity(x, y, z, wallNow)
	self.LastSourceQueries += 1
	if density < LEAVE then
		return
	end
	local h = math.clamp((y - base) / math.max(0.001, thickness), 0, 1)
	local detailed = Detail.Sample(self.DetailParameters, x, y, z, h, density, self.Quality)
	self.LastNoiseEvaluations += self.Quality.NoiseSamples
	local rootId = read(node, slot, ID)
	local id = rootId * 512 + n * 64 + child
	if detailed < (if self.Wanted[id] then LEAVE else ENTER) then
		return
	end
	local score = read(node, slot, SCORE) * (0.4 + detailed)
	self.CandidateCount = heapOffer(
		self.Candidates,
		self.Heap,
		self.CandidateCount,
		self.Quality.MaxCubes,
		id,
		rootId,
		x,
		y,
		z,
		h,
		side,
		score,
		time
	)
	self.CandidatesSinceCommit += 1
end
local function updateCube(
	self: any,
	record: number,
	s: any,
	wallNow: number,
	time: number,
	dt: number,
	camera: CameraInfo,
	light: LightingInfo
)
	local id = read(self.Selected, record, ID)
	local p = self.Pool:Acquire(id)
	if not p then
		return
	end
	local x, y, z, side =
		read(self.Selected, record, X),
		read(self.Selected, record, Y),
		read(self.Selected, record, Z),
		read(self.Selected, record, SIZE)
	local flow = self.Flow[id]
	if not flow then
		flow = {
			X = 0,
			Y = 0,
			Z = 0,
			Time = time,
			Wall = wallNow,
			Retiring = false,
			OpticalDepth = nil,
			OpticalSequence = nil,
		}
		self.Flow[id] = flow
	end
	local delta = math.clamp(time - flow.Time, 0, 2)
	local u, v, w = self.Reconstruction:SampleVelocity(x + flow.X, y + flow.Y, z + flow.Z, wallNow)
	local convert = s.StudsPerMeter
	local cage = SIDE * 0.48
	flow.X = math.clamp(flow.X + u * delta * convert, -cage, cage)
	flow.Y = math.clamp(flow.Y + w * delta * convert, -cage, cage)
	flow.Z = math.clamp(flow.Z + v * delta * convert, -cage, cage)
	flow.Time = time
	if math.max(math.abs(flow.X), math.abs(flow.Y), math.abs(flow.Z)) >= SIDE * 0.45 then
		flow.Retiring = true
	end
	x, y, z = x + flow.X, y + flow.Y, z + flow.Z
	if s.Boundary == "Periodic" then
		x = s.MinXStuds + (x - s.MinXStuds) % s.WidthStuds
		z = s.MinZStuds + (z - s.MinZStuds) % s.DepthStuds
	end
	local half = side / 2
	x = math.clamp(x, s.MinXStuds + half, s.MinXStuds + s.WidthStuds - half)
	z = math.clamp(z, s.MinZStuds + half, s.MinZStuds + s.DepthStuds - half)
	local base, top, thickness, present = self.Surface:Sample(x, z)
	local canFit = present and thickness >= side
	if not canFit then
		self.Pool:Release(id)
		self.Flow[id] = nil
		return
	end
	if canFit then
		y = math.clamp(
			y,
			math.max(base, s.BottomYStuds) + half,
			math.min(top, s.BottomYStuds + s.LayerHeightStuds * s.SizeY) - half
		)
	end
	local density = if canFit then self.Reconstruction:SampleDensity(x, y, z, wallNow) else 0
	local h = if present then math.clamp((y - base) / math.max(0.001, thickness), 0, 1) else 0
	local detailed = Detail.Sample(self.DetailParameters, x, y, z, h, density, self.Quality)
	self.LastNoiseEvaluations += self.Quality.NoiseSamples
	if detailed < LEAVE then
		detailed = 0
	end
	local target = if canFit and not flow.Retiring
		then math.min(0.88, 1 - math.exp(-detailed * 2.8))
		else 0
	local distance = math.sqrt((x - camera.X) ^ 2 + (y - camera.Y) ^ 2 + (z - camera.Z) ^ 2)
	self.ProjectedAreaProxy += side * side / math.max(64, distance * distance) * target
	local elapsed = math.max(dt, math.clamp(wallNow - flow.Wall, 0, 0.5))
	flow.Wall = wallNow
	local opacity = p.Opacity + (target - p.Opacity) * math.min(1, elapsed / FADE_SECONDS)
	if flow.Retiring and opacity < 1 / 255 then
		flow.X, flow.Y, flow.Z, flow.Retiring = 0, 0, 0, false
		self.Pool:Apply(p, x, y, z, side, 0, p.R, p.G, p.B)
		return
	end
	if target == 0 and opacity < 1 / 255 then
		self.Pool:Release(id)
		self.Flow[id] = nil
		return
	end
	local gx, gy, gz = self.Reconstruction:Gradient(x, y, z, wallNow)
	if
		self.Quality.LightingSamples > 0
		and flow.OpticalSequence ~= s.Sequence
		and self.LastLightIntegrations
			< math.max(1, math.floor(self.Quality.MaxUpdatesPerUpdate / 8))
	then
		self.LastSampleWall = wallNow
		flow.OpticalDepth = Lighting.OpticalDepth(
			self.OpticalSampler,
			x,
			y,
			z,
			light.SunX or 0,
			light.SunY or 1,
			light.SunZ or 0,
			side * 0.35,
			self.Quality.LightingSamples
		)
		flow.OpticalSequence = s.Sequence
		self.LastLightIntegrations += 1
	end
	local r, g, b = Lighting.Shade(
		detailed,
		h,
		gx,
		gy,
		gz,
		light.SunX or 0,
		light.SunY or 1,
		light.SunZ or 0,
		light.Ambient or 0.5,
		flow.OpticalDepth
	)
	if self.DebugMode == "Density" then
		r, g, b = detailed, 0.25, 1 - detailed
	elseif self.DebugMode == "Gradients" then
		local length = math.sqrt(gx * gx + gy * gy + gz * gz)
		if length > 1e-8 then
			r, g, b = 0.5 + gx / length * 0.5, 0.5 + gy / length * 0.5, 0.5 + gz / length * 0.5
		end
	elseif self.DebugMode == "Bounds" then
		r, g, b = 1 - h, h, 0.3
	end
	self.Pool:Apply(p, x, y, z, side, opacity, r, g, b)
	self.LastCubeUpdates += 1
end
function Renderer:Update(
	wallNow: number,
	dt: number,
	cameraInfo: CameraInfo?,
	lightingInfo: LightingInfo?
): any
	assert(not self.Destroyed, "Cloud renderer was destroyed")
	assert(finite(wallNow) and finite(dt) and dt >= 0, "Invalid renderer time")
	if not self.Enabled then
		return nil
	end
	self.Accumulator += dt
	local interval = 1 / self.Quality.UpdateHz
	if self.Accumulator < interval then
		return nil
	end
	local visualDt = math.min(self.Accumulator, 0.5)
	self.Accumulator %= interval
	local started = self.Clock()
	local s = self.Reconstruction.Current
	if not s then
		self:Hide()
		return nil
	end
	local old = self.LastSnapshot
	local reset = self.Generation ~= s.Generation
		or self.Seed ~= s.Seed
		or (
			old
			and (
				old.SizeX ~= s.SizeX
				or old.SizeY ~= s.SizeY
				or old.SizeZ ~= s.SizeZ
				or old.WidthStuds ~= s.WidthStuds
				or old.DepthStuds ~= s.DepthStuds
				or old.MinXStuds ~= s.MinXStuds
				or old.MinZStuds ~= s.MinZStuds
				or old.BottomYStuds ~= s.BottomYStuds
				or old.LayerHeightStuds ~= s.LayerHeightStuds
			)
		)
	if reset then
		local nx, nz, ny, count = rootGeometry(s)
		invalidate(self)
		self.Generation, self.Seed = s.Generation, s.Seed
		self.DetailParameters = Detail.Create(s.Seed)
		self.RootNX, self.RootNZ, self.RootNY, self.RootTotal = nx, nz, ny, count
		self.LODHistory = buffer.create(self.RootTotal)
		buffer.fill(self.LODHistory, 0, 255)
		self.Early = buffer.create(STRIDE)
	end
	if self.LastSnapshot ~= s then
		self.Surface:Update(s)
		self.LastSnapshot = s
	end
	if self.Surface.CloudColumns == 0 then
		invalidate(self)
		return nil
	end
	local camera = cameraInfo or { X = 0, Y = 70, Z = 0 }
	assert(finite(camera.X) and finite(camera.Y) and finite(camera.Z), "Invalid camera position")
	local light = lightingInfo or {}
	local time = self.Reconstruction:GetRenderTime(wallNow)
	self.LastSourceQueries, self.LastCubeUpdates, self.LastNoiseEvaluations, self.LastLightIntegrations, self.ProjectedAreaProxy =
		0, 0, 0, 0, 0
	self.Pool:BeginUpdate(self.Quality.MaxCreatesPerUpdate)
	local deadline = started + self.Quality.UpdateBudgetMilliseconds / 1000
	for _ = 1, math.min(self.SelectedCount, self.Quality.MaxUpdatesPerUpdate) do
		if self.Clock() >= started + self.Quality.UpdateBudgetMilliseconds * 0.0005 then
			break
		end
		if self.UpdateCursor > self.SelectedCount then
			self.UpdateCursor = 1
		end
		updateCube(self, self.UpdateCursor, s, wallNow, time, visualDt, camera, light)
		self.UpdateCursor += 1
	end
	if self.ScanIndex == 1 and self.Phase == "Roots" then
		self.ScanCameraX =
			math.clamp(math.floor((camera.X - s.MinXStuds) / SIDE), 0, self.RootNX - 1)
		self.ScanCameraZ =
			math.clamp(math.floor((camera.Z - s.MinZStuds) / SIDE), 0, self.RootNZ - 1)
	end
	-- Strict work counts supplement the soft clock limit: no monolithic fine
	-- grid scan, and no complete pass is required before first cube publication.
	local rootWork, childWork = 0, 0
	local rootLimit = self.Quality.MaxUpdatesPerUpdate * 24
	local childLimit = self.Quality.MaxUpdatesPerUpdate * 2
	while self.Clock() < deadline do
		if self.Phase == "Roots" then
			if rootWork >= rootLimit then
				break
			end
			scanRoot(self, s, wallNow, time, camera)
			self.ScanIndex += 1
			rootWork += 1
			if self.ScanIndex > self.RootTotal then
				self.RootsComplete = true
				-- The early provisional region may have been evicted from the
				-- bounded root frontier. Keep its visible Parts until the first
				-- new chunk, but rebuild candidates only from final selected roots.
				table.clear(self.Heap)
				self.CandidateCount, self.CandidatesSinceCommit = 0, 0
				self.Phase = "Refine"
				self.RefineCursor, self.ChildCursor = 1, 1
			end
		else
			if childWork >= childLimit then
				break
			end
			local node, slot
			if self.Phase == "Early" then
				node, slot = self.Early, 1
			elseif self.RefineCursor <= #self.RootHeap then
				node, slot = self.Roots, self.RootHeap[self.RefineCursor]
			else
				publishCandidates(self, wallNow, true)
				self.CompletedScans += 1
				resetScan(self)
				break
			end
			sampleChild(self, s, node, slot, wallNow, time)
			self.ChildCursor += 1
			childWork += 1
			local n = read(node, slot, SIZE)
			if self.ChildCursor > n * n * n then
				self.ChildCursor = 1
				if self.Phase == "Early" then
					self.Phase = "Roots"
					publishCandidates(self, wallNow)
				else
					self.RefineCursor += 1
				end
			end
			if not self.SelectionMature and self.CandidatesSinceCommit >= 128 then
				publishCandidates(self, wallNow)
			end
		end
	end
	if
		not self.SelectionMature
		and self.CandidatesSinceCommit > 0
		and wallNow - self.LastCommitWall >= 0.5
	then
		publishCandidates(self, wallNow)
	end
	self.Pool:EndUpdate()
	self.LastRootQueries = rootWork
	self.LastChildQueries = childWork
	self.LastUpdateMilliseconds = (self.Clock() - started) * 1000
	self.MaxUpdateMilliseconds = math.max(self.MaxUpdateMilliseconds, self.LastUpdateMilliseconds)
	if self.LastUpdateMilliseconds > self.Quality.UpdateBudgetMilliseconds then
		self.BudgetOverruns += 1
	end
	self.TotalUpdates += 1
	return nil
end
function Renderer:GetDiagnostics(): any
	local result = self.Pool:GetDiagnostics()
	result.Quality = self.Quality.Name
	result.Enabled = self.Enabled
	result.DebugMode = self.DebugMode
	result.SelectedCandidates = self.SelectedCount
	result.ActiveClusters = self.ClusterCount
	result.CompletedScans = self.CompletedScans
	result.PublishedCandidateChunks = self.PublishedChunks
	result.SelectionMature = self.SelectionMature
	result.PublicationPolicy =
		"Cold-start partial chunks; subsequent topology replacement only after complete bounded frontier"
	result.ScanCellCursor = self.ScanIndex
	result.ScanPhase = self.Phase
	result.SourceQueriesLastUpdate = self.LastSourceQueries
	result.RootQueriesLastUpdate = self.LastRootQueries or 0
	result.ChildQueriesLastUpdate = self.LastChildQueries or 0
	result.CubeUpdatesLastUpdate = self.LastCubeUpdates
	result.NoiseEvaluationsLastUpdate = self.LastNoiseEvaluations
	result.TotalUpdates = self.TotalUpdates
	result.LastUpdateMilliseconds = self.LastUpdateMilliseconds
	result.MaxUpdateMilliseconds = self.MaxUpdateMilliseconds
	result.SoftBudgetOverruns = self.BudgetOverruns
	result.CandidateStorageBytes = buffer.len(self.Roots)
		+ buffer.len(self.Candidates)
		+ buffer.len(self.Selected)
	result.SurfaceStorageBytes = self.Surface:GetStorageBytes()
	result.LODStorageBytes = buffer.len(self.LODHistory)
	result.ProjectedCubeAreaProxy = self.ProjectedAreaProxy
	result.ProjectedAreaMeaning =
		"Updated cube sum opacity*side^2/max(64,distance^2); not GPU pixels or overdraw"
	result.OpticalPointsLastUpdate = self.LastLightIntegrations
	result.OpticalSamplesPerPoint = self.Quality.LightingSamples
	result.ConstructionNodeBudget = MAX_CONSTRUCTION_NODES
	result.MinimumCubeSize = MIN_SIDE
	result.MaximumCubeSize = SIDE
	result.Geometry = "Genuine equal-X/Y/Z Block Parts; sparse adaptive 3D cubic subdivisions"
	result.VerticalRepresentation =
		"Actual local liquid envelope inside the resolved shallow atmospheric layer"
	result.FlowDetail =
		"Bounded m/s-to-studs carriers; sampled authoritative qc, fade/reanchor at half construction node"
	return result
end
function Renderer:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Pool:Destroy()
	table.clear(self.Heap)
	table.clear(self.RootHeap)
	table.clear(self.Wanted)
	table.clear(self.Clusters)
	table.clear(self.Flow)
	self.Roots, self.Candidates, self.Selected, self.LODHistory, self.Early =
		buffer.create(0), buffer.create(0), buffer.create(0), buffer.create(0), buffer.create(0)
	self.Surface:Reset()
	self.Surface.Bases, self.Surface.Tops, self.Surface.Occupied =
		buffer.create(0), buffer.create(0), buffer.create(0)
	self.Surface.Columns = 0
	self.LastSnapshot, self.Reconstruction, self.DetailParameters, self.OpticalSampler =
		nil, nil, nil, nil
	self.SelectedCount, self.ClusterCount = 0, 0
end
return table.freeze(Renderer)
