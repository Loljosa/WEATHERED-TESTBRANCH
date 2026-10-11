--!strict

-- Client-owned pooled diagnostics. Cubes stay at authoritative world cell
-- centers; their interpolated liquid density changes. No visual displacement
-- is added to the physical field. This is deliberately not a cloud renderer.
local WeatherSnapshot = require(script.Parent.WeatherSnapshot)
local WorldVoxelDebugRenderer = {}
WorldVoxelDebugRenderer.__index = WorldVoxelDebugRenderer

local MAX_PARTS = 512
local CREATIONS_PER_UPDATE = 16
local VECTOR_LIMIT = 16
local VECTOR_SECONDS = 5 -- displayed line = velocity * conversion * five seconds

export type Renderer = typeof(setmetatable(
	{} :: {
		Folder: Folder,
		Limit: number,
		Pool: { Part },
		CellSlots: { [number]: number },
		SlotCells: { number },
		SlotOpacity: { number },
		FreeSlots: { number },
		Geometry: WeatherSnapshot.Snapshot?,
		Seen: { [number]: boolean },
		Candidates: { number },
		Water: { [number]: number },
		Regions: { Part },
		Vectors: { Part },
		Generation: number,
		Visible: number,
		Destroyed: boolean,
	},
	WorldVoxelDebugRenderer
))

local function configure(part: Part)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromRGB(225, 230, 235)
	part.Transparency = 1
end

local function line(part: Part, from: Vector3, to: Vector3, width: number)
	local length = (to - from).Magnitude
	if length <= 0.001 then
		part.Transparency = 1
		return
	end
	part.Size = Vector3.new(width, width, length)
	part.CFrame = CFrame.lookAt((from + to) * 0.5, to)
	part.Transparency = 0.25
end

function WorldVoxelDebugRenderer.new(maxParts: number?): Renderer
	local limit = maxParts or 256
	assert(
		limit % 1 == 0 and limit >= 1 and limit <= MAX_PARTS,
		"World debug Part limit must be 1..512"
	)
	local folder = Instance.new("Folder")
	folder.Name = "WEATHERED_WORLD_DEBUG_VOXELS"
	folder:SetAttribute("VectorScaleSeconds", VECTOR_SECONDS)
	folder:SetAttribute("DiagnosticOnly", true)
	folder.Parent = workspace
	return setmetatable({
		Folder = folder,
		Limit = limit,
		Pool = {},
		CellSlots = {},
		SlotCells = {},
		SlotOpacity = {},
		FreeSlots = {},
		Geometry = nil,
		Seen = {},
		Candidates = table.create(MAX_PARTS * 2),
		Water = {},
		Regions = {},
		Vectors = {},
		Generation = -1,
		Visible = 0,
		Destroyed = false,
	}, WorldVoxelDebugRenderer)
end

function WorldVoxelDebugRenderer:SetLimit(limit: number)
	assert(
		limit % 1 == 0 and limit >= 1 and limit <= MAX_PARTS,
		"World debug Part limit must be 1..512"
	)
	self.Limit = limit
	-- Retain allocated Parts for reuse, but never display more than the new cap.
end

function WorldVoxelDebugRenderer:Hide()
	for slot, part in self.Pool do
		if self.SlotOpacity[slot] ~= 1 then
			part.Transparency = 1
			self.SlotOpacity[slot] = 1
		end
	end
	for _, part in self.Vectors do
		part.Transparency = 1
	end
	for _, part in self.Regions do
		part.Transparency = 1
	end
	self.Visible = 0
end

function WorldVoxelDebugRenderer:Update(
	previous: WeatherSnapshot.Snapshot,
	current: WeatherSnapshot.Snapshot,
	alpha: number
): number
	assert(not self.Destroyed, "World debug renderer was destroyed")
	if not current.DebugEnabled then
		self:Hide()
		return 0
	end
	if not WeatherSnapshot.Compatible(previous, current) then
		previous = current
		alpha = 1
	end
	if not self.Geometry or not WeatherSnapshot.Compatible(self.Geometry, current) then
		self.Generation = current.Generation
		table.clear(self.CellSlots)
		table.clear(self.SlotCells)
		table.clear(self.FreeSlots)
		for slot, part in self.Pool do
			part.Transparency = 1
			self.SlotOpacity[slot] = 1
			table.insert(self.FreeSlots, slot)
		end
	end
	self.Geometry = current
	table.clear(self.Candidates)
	table.clear(self.Water)
	table.clear(self.Seen)
	-- A sorted merge produces at most twice the network cap. Values below the
	-- cutoff fade briefly instead of disappearing on a snapshot boundary.
	local a, b = 1, 1
	while a <= previous.Count or b <= current.Count do
		local ai = if a <= previous.Count then WeatherSnapshot.Record(previous, a) else math.huge
		local bi = if b <= current.Count then WeatherSnapshot.Record(current, b) else math.huge
		local index = math.min(ai, bi)
		if ai == index then
			a += 1
		end
		if bi == index then
			b += 1
		end
		local water = WeatherSnapshot.Interpolate(previous, current, index, alpha)
		if water >= current.Threshold * 0.1 then
			table.insert(self.Candidates, index)
			self.Water[index] = water
		end
	end
	table.sort(self.Candidates, function(aIndex: number, bIndex: number): boolean
		local aq, bq = self.Water[aIndex], self.Water[bIndex]
		return aq > bq or (aq == bq and aIndex < bIndex)
	end)
	local selected = math.min(#self.Candidates, self.Limit)
	for choice = 1, selected do
		self.Seen[self.Candidates[choice]] = true
	end
	for slot = 1, #self.Pool do
		local cell = self.SlotCells[slot]
		if cell and not self.Seen[cell] then
			self.CellSlots[cell] = nil
			self.SlotCells[slot] = nil
			table.insert(self.FreeSlots, slot)
			if self.SlotOpacity[slot] ~= 1 then
				self.Pool[slot].Transparency = 1
				self.SlotOpacity[slot] = 1
			end
		end
	end
	local created, visible = 0, 0
	local dimensions = Vector3.new(
		current.WidthStuds / current.SizeX * 0.95,
		current.LayerHeightStuds * 0.95,
		current.DepthStuds / current.SizeZ * 0.95
	)
	for choice = 1, selected do
		local cell = self.Candidates[choice]
		local slot = self.CellSlots[cell]
		local assigned = slot == nil
		if not slot then
			local available = #self.FreeSlots
			if available > 0 then
				slot = self.FreeSlots[available]
				self.FreeSlots[available] = nil
			end
			if not slot and #self.Pool < self.Limit and created < CREATIONS_PER_UPDATE then
				local part = Instance.new("Part")
				part.Name = "WorldQc_" .. tostring(#self.Pool + 1)
				configure(part)
				part.Parent = self.Folder
				table.insert(self.Pool, part)
				slot = #self.Pool
				self.SlotOpacity[slot] = 1
				created += 1
			end
			if not slot then
				continue
			end
			self.CellSlots[cell], self.SlotCells[slot] = slot, cell
		end
		local part = self.Pool[slot]
		if assigned then
			local x, y, z = WeatherSnapshot.CellCenter(current, cell)
			part.Position = Vector3.new(x, y, z)
			part.Size = dimensions
		end
		local opacity = math.floor(
			math.clamp(0.9 - 0.7 * self.Water[cell] / 0.0005, 0.15, 0.94) * 100 + 0.5
		) / 100
		if self.SlotOpacity[slot] ~= opacity then
			part.Transparency = opacity
			self.SlotOpacity[slot] = opacity
		end
		visible += 1
	end
	self.Visible = visible
	self.Folder:SetAttribute("VisibleCells", visible)
	self.Folder:SetAttribute("CroppedCells", current.AboveThreshold - current.Count)
	self.Folder:SetAttribute("SimulationTime", current.Time)
	self.Folder:SetAttribute("WallTime", current.WallTime)
	self.Folder:SetAttribute("DroppedSimulationTime", current.DroppedTime)
	self.Folder:SetAttribute("DroppedPhysicsSteps", math.floor(current.DroppedTime / 0.25 + 0.5))
	self.Folder:SetAttribute("CloudCentroidDefined", current.CentroidDefined)
	self.Folder:SetAttribute(
		"CloudCentroidXStuds",
		if current.CentroidDefined then current.CentroidXStuds else nil
	)
	self.Folder:SetAttribute(
		"CloudCentroidYStuds",
		if current.CentroidDefined then current.CentroidYStuds else nil
	)
	self.Folder:SetAttribute(
		"CloudCentroidZStuds",
		if current.CentroidDefined then current.CentroidZStuds else nil
	)
	self:UpdateRegions(current)
	self:UpdateVectors(previous, current, alpha)
	return visible
end

function WorldVoxelDebugRenderer:UpdateRegions(snapshot: WeatherSnapshot.Snapshot)
	if not snapshot.DebugRegions then
		for _, part in self.Regions do
			part.Transparency = 1
		end
		return
	end
	for axis = 1, 2 do
		for border = 0, 4 do
			local slot = (axis - 1) * 5 + border + 1
			local part = self.Regions[slot]
			if not part then
				part = Instance.new("Part")
				part.Name = "WeatherRegionBorder_" .. tostring(slot)
				configure(part)
				part.Color = Color3.fromRGB(90, 190, 240)
				part.Parent = self.Folder
				self.Regions[slot] = part
			end
			local y = snapshot.BottomYStuds - 2
			if axis == 1 then
				local x = snapshot.MinXStuds + border * snapshot.WidthStuds / 4
				line(
					part,
					Vector3.new(x, y, snapshot.MinZStuds),
					Vector3.new(x, y, snapshot.MinZStuds + snapshot.DepthStuds),
					0.75
				)
			else
				local z = snapshot.MinZStuds + border * snapshot.DepthStuds / 4
				line(
					part,
					Vector3.new(snapshot.MinXStuds, y, z),
					Vector3.new(snapshot.MinXStuds + snapshot.WidthStuds, y, z),
					0.75
				)
			end
		end
	end
end

function WorldVoxelDebugRenderer:UpdateVectors(
	previous: WeatherSnapshot.Snapshot,
	current: WeatherSnapshot.Snapshot,
	alpha: number
)
	if not current.DebugVectors then
		for _, part in self.Vectors do
			part.Transparency = 1
		end
		return
	end
	local count = math.min(VECTOR_LIMIT, self.Visible)
	for slot = 1, VECTOR_LIMIT do
		local part = self.Vectors[slot]
		if slot > count then
			if part then
				part.Transparency = 1
			end
			continue
		end
		if not part then
			part = Instance.new("Part")
			part.Name = "WeatherVelocity_" .. tostring(slot)
			configure(part)
			part.Color = Color3.fromRGB(245, 170, 60)
			part.Parent = self.Folder
			self.Vectors[slot] = part
		end
		local cell = self.Candidates[slot]
		local _, u, v, w = WeatherSnapshot.Interpolate(previous, current, cell, alpha)
		local x, y, z = WeatherSnapshot.CellCenter(current, cell)
		local from = Vector3.new(x, y, z)
		local offset = Vector3.new(u, w, v) * current.StudsPerMeter * VECTOR_SECONDS
		-- Cap visual line length only; velocity values and physical transport
		-- remain unchanged. A vector is not a cloud displacement measurement.
		if offset.Magnitude > 200 then
			offset = offset.Unit * 200
		end
		line(part, from, from + offset, 1)
	end
end

function WorldVoxelDebugRenderer:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Folder:Destroy()
	table.clear(self.Pool)
	table.clear(self.Regions)
	table.clear(self.Vectors)
	table.clear(self.CellSlots)
	table.clear(self.SlotCells)
	table.clear(self.SlotOpacity)
	table.clear(self.FreeSlots)
	self.Geometry = nil
end

WorldVoxelDebugRenderer.CreationsPerUpdate = CREATIONS_PER_UPDATE
WorldVoxelDebugRenderer.VectorLimit = VECTOR_LIMIT
WorldVoxelDebugRenderer.RegionLineLimit = 10
return table.freeze(WorldVoxelDebugRenderer)
