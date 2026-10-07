--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere
local AtmosphereState = require(AtmosphereRoot.Core.AtmosphereState)

local VoxelDebugRenderer = {}

local FOLDER_NAME = "WEATHERED_DEBUG_VOXELS"
local POOL_LIMIT = 1200
local CREATIONS_PER_UPDATE = 128
local CLOUD_COLOR = Color3.fromRGB(225, 230, 235)

local folder: Folder? = nil
local pool: { Part } = {}

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
	for _, child in current:GetChildren() do
		if child:IsA("Part") then
			configurePart(child)
			if #pool < POOL_LIMIT then
				table.insert(pool, child)
			end
		end
	end
	folder = current
	return current
end

-- Call at debug frequency (2 Hz). Pool entries represent the current visible selection;
-- Parts are retained and reassigned as qc changes, never recreated every physics step.
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
	local voxelSize = Vector3.new(grid.CellSize * 0.9, grid.CellSize * 0.9, grid.CellSize * 0.9)
	local cloudField = state.Fields.qc
	local rendered = 0
	local created = 0

	for index = 1, grid.Count do
		if rendered >= limit then
			break
		end

		local cloudWater = buffer.readf32(cloudField, (index - 1) * 4)
		if cloudWater >= minimumCloudWater then
			local slot = rendered + 1
			local voxel = pool[slot]
			if not voxel then
				if created >= CREATIONS_PER_UPDATE then
					break
				end

				voxel = Instance.new("Part")
				voxel.Name = "VoxelDebug_" .. tostring(slot)
				configurePart(voxel)
				voxel.Parent = currentFolder
				pool[slot] = voxel
				created += 1
			end

			local x, y, z = grid:Coordinates(index)
			-- Visual normalization lets thin prototype clouds show clearly.
			local normalizedDensity = math.clamp(cloudWater / 0.0005, 0, 1)
			voxel.Size = voxelSize
			voxel.Position = grid:GridToWorld(x, y, z)
			voxel.Transparency = math.clamp(0.85 - normalizedDensity * 0.65, 0.15, 0.9)
			rendered += 1
		end
	end

	for slot = rendered + 1, #pool do
		pool[slot].Transparency = 1
	end

	return rendered
end

function VoxelDebugRenderer.Destroy()
	if folder then
		folder:Destroy()
		folder = nil
	end
	table.clear(pool)
end

return VoxelDebugRenderer
