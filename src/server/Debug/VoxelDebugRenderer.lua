--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere
local AtmosphereState = require(AtmosphereRoot.Core.AtmosphereState)
local Grid3D = require(AtmosphereRoot.Core.Grid3D)

local VoxelDebugRenderer = {}

local FOLDER_NAME = "WEATHERED_DEBUG_VOXELS"
local POOL_LIMIT = 1200
local CREATIONS_PER_UPDATE = 32
local CLOUD_COLOR = Color3.fromRGB(225, 230, 235)

local folder: Folder? = nil
local pool: { Part } = {}
-- Parallel arrays keep ownership/cache data separate from Roblox Instances.
-- The selected-cell scratch arrays are reused, with no per-render cell tables.
local cellSlots: { [number]: number } = {}
local slotCells: { number } = {}
local slotOpacity: { number } = {}
local slotSize: { number } = {}
local slotSeen: { number } = {}
local freeSlots: { number } = {}
local selectedCells: { number } = table.create(POOL_LIMIT, 0)
local selectedWater: { number } = table.create(POOL_LIMIT, 0)
local generation = 0
local lastGrid: Grid3D.Grid3D? = nil
local lastOrigin = Vector3.zero
local lastCellSize = 0

local function clearOwnership()
	table.clear(cellSlots)
	table.clear(slotCells)
	table.clear(slotOpacity)
	table.clear(slotSize)
	table.clear(slotSeen)
	table.clear(freeSlots)
	lastGrid = nil
end

local function releaseSlot(slot: number)
	local cell = slotCells[slot]
	if cell and cell ~= 0 then
		cellSlots[cell] = nil
		slotCells[slot] = 0
		table.insert(freeSlots, slot)
		if slotOpacity[slot] ~= 1 then
			pool[slot].Transparency = 1
			slotOpacity[slot] = 1
		end
	end
end

local function configurePart(voxel: Part)
	voxel.Anchored = true
	voxel.CanCollide = false
	voxel.CanTouch = false
	voxel.CanQuery = false
	voxel.CastShadow = false
	voxel.Material = Enum.Material.SmoothPlastic
	voxel.Color = CLOUD_COLOR
	voxel.Transparency = 1
end

local function getFolder(): Folder
	local current = folder
	if current and current.Parent == workspace then
		return current
	end

	-- A Studio script reload may leave the previous debug folder behind.
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		assert(
			existing:IsA("Folder"),
			"WEATHERED debug folder name is occupied by another Instance"
		)
		current = existing
	else
		current = Instance.new("Folder")
		current.Name = FOLDER_NAME
		current.Parent = workspace
	end

	table.clear(pool)
	clearOwnership()
	for _, child in current:GetChildren() do
		if child:IsA("Part") then
			configurePart(child)
			if #pool < POOL_LIMIT then
				table.insert(pool, child)
				local slot = #pool
				slotCells[slot] = 0
				slotOpacity[slot] = 1
				slotSize[slot] = 0
				slotSeen[slot] = 0
				table.insert(freeSlots, slot)
			end
		end
	end
	folder = current
	return current
end

-- Call only at debug frequency. Retained cells keep their Part rather than moving
-- every later pool entry when an earlier cell appears/disappears. Unchanged
-- geometry and 0.01-quantized opacity produce no redundant replicated writes.
function VoxelDebugRenderer.Render(
	state: AtmosphereState.AtmosphereState,
	threshold: number?,
	maxParts: number?
): number
	local minimumCloudWater = threshold or 0.00005 -- kg water / kg dry air
	local limit = maxParts or POOL_LIMIT
	assert(minimumCloudWater > 0 and minimumCloudWater < math.huge, "Invalid debug qc threshold")
	assert(limit > 0 and limit % 1 == 0 and limit <= POOL_LIMIT, "Invalid debug Part limit")

	local currentFolder = getFolder()
	local grid = state.Grid
	local voxelSize = Vector3.new(grid.CellSize, grid.CellSize, grid.CellSize)
	local cloudField = state.Fields.qc
	if grid ~= lastGrid or grid.CellSize ~= lastCellSize or grid.Origin ~= lastOrigin then
		for slot = 1, #pool do
			releaseSlot(slot)
		end
		lastGrid = grid
		lastCellSize = grid.CellSize
		lastOrigin = grid.Origin
	end

	generation += 1
	local selected = 0
	for index = 1, grid.Count do
		local cloudWater = buffer.readf32(cloudField, (index - 1) * 4)
		if cloudWater >= minimumCloudWater then
			selected += 1
			selectedCells[selected] = index
			selectedWater[selected] = cloudWater
			local existing = cellSlots[index]
			if existing then
				slotSeen[existing] = generation
			end
			if selected >= limit then
				break
			end
		end
	end

	-- Release first, so disappearing cells immediately supply slots for new ones.
	for slot = 1, #pool do
		if slotCells[slot] ~= 0 and slotSeen[slot] ~= generation then
			releaseSlot(slot)
		end
	end

	local rendered = 0
	local created = 0
	for selection = 1, selected do
		local index = selectedCells[selection]
		local slot = cellSlots[index]
		local assigned = slot == nil
		local isNew = false
		if not slot then
			local freeCount = #freeSlots
			if freeCount > 0 then
				slot = freeSlots[freeCount]
				freeSlots[freeCount] = nil
			else
				if created >= CREATIONS_PER_UPDATE then
					-- Later selected cells may already own a retained Part.
					continue
				end
				slot = #pool + 1
				local voxel = Instance.new("Part")
				voxel.Name = "VoxelDebug_" .. tostring(slot)
				configurePart(voxel)
				pool[slot] = voxel
				slotSize[slot] = 0
				slotOpacity[slot] = 1
				created += 1
				isNew = true
			end
			cellSlots[index] = slot
			slotCells[slot] = index
		end
		local voxel = pool[slot]
		if slotSize[slot] ~= grid.CellSize then
			voxel.Size = voxelSize
			slotSize[slot] = grid.CellSize
		end
		if assigned then
			local x, y, z = grid:Coordinates(index)
			voxel.Position = grid:GridToWorld(x, y, z)
		end
		-- Quantization is display-only; no atmospheric value is modified.
		local density = math.clamp(selectedWater[selection] / 0.0005, 0, 1)
		local opacity = math.floor(math.clamp(0.85 - density * 0.65, 0.15, 0.9) * 100 + 0.5) / 100
		if slotOpacity[slot] ~= opacity then
			voxel.Transparency = opacity
			slotOpacity[slot] = opacity
		end
		if isNew then
			-- Publish configured Parts once rather than replicate interim properties.
			voxel.Parent = currentFolder
		end
		rendered += 1
	end

	return rendered
end

function VoxelDebugRenderer.Destroy()
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(pool)
	clearOwnership()
end

return VoxelDebugRenderer
