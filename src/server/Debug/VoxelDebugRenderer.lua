--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere
local AtmosphereState = require(AtmosphereRoot.Core.AtmosphereState)

local VoxelDebugRenderer = {}

local FOLDER_NAME = "WEATHERED_DEBUG_VOXELS"

local function getFolder(): Folder
	local existing = workspace:FindFirstChild(FOLDER_NAME)

	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace

	return folder
end

function VoxelDebugRenderer.Render(
	state: AtmosphereState.AtmosphereState,
	threshold: number?,
	maxParts: number?
)
	local folder = getFolder()

	local grid = state.Grid

	local minimumCloudWater = threshold or 0.00025
	local limit = maxParts or 1200

	local rendered = 0

	for index = 1, grid.Count do
		if rendered >= limit then
			break
		end

		local cloudWater = state:Get("qc", index)

		if cloudWater >= minimumCloudWater then
			local x, y, z = grid:Coordinates(index)

			local normalizedDensity = math.clamp(cloudWater / 0.004, 0, 1)

			local voxel = Instance.new("Part")

			voxel.Name = string.format("Voxel_%d_%d_%d", x, y, z)

			voxel.Anchored = true
			voxel.CanCollide = false
			voxel.CanTouch = false
			voxel.CanQuery = false

			voxel.Size = Vector3.new(
				grid.CellSize * 0.9,
				grid.CellSize * 0.9,
				grid.CellSize * 0.9
			)

			voxel.Position = grid:GridToWorld(x, y, z)

			voxel.Material = Enum.Material.SmoothPlastic
			voxel.Color = Color3.fromRGB(225, 230, 235)

			voxel.Transparency = math.clamp(
				0.85 - normalizedDensity * 0.65,
				0.15,
				0.9
			)

			voxel.Parent = folder

			rendered += 1
		end
	end

	print(
		string.format(
			"[WEATHERED] Debug voxel renderer created %d parts",
			rendered
		)
	)
end

return VoxelDebugRenderer
