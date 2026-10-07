--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AtmosphereRoot = ReplicatedStorage.Shared.Atmosphere

local Grid3D = require(AtmosphereRoot.Core.Grid3D)
local AtmosphereState = require(AtmosphereRoot.Core.AtmosphereState)

local SimulationController = {}

local grid = Grid3D.new(
	24,
	12,
	24,
	64,
	Vector3.new(-768, 128, -768)
)

local state = AtmosphereState.new(grid)

local initialized = false

local function seedPrototypeCloud()
	local center = Vector3.new(
		(grid.SizeX + 1) * 0.5,
		(grid.SizeY + 1) * 0.5,
		(grid.SizeZ + 1) * 0.5
	)

	local radiusX = 7
	local radiusY = 4
	local radiusZ = 7

	for y = 1, grid.SizeY do
		for z = 1, grid.SizeZ do
			for x = 1, grid.SizeX do
				local dx = (x - center.X) / radiusX
				local dy = (y - center.Y) / radiusY
				local dz = (z - center.Z) / radiusZ

				local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

				if distance < 1 then
					local density = math.clamp(1 - distance, 0, 1)

					state:SetCell("qc", x, y, z, density * 0.004)
					state:SetCell("qv", x, y, z, 0.014)
					state:SetCell("theta", x, y, z, 302 + density * 2)
					state:SetCell("w", x, y, z, density * 8)
				end
			end
		end
	end
end

function SimulationController.Initialize()
	if initialized then
		return
	end

	initialized = true

	seedPrototypeCloud()

	print(
		string.format(
			"[WEATHERED] Prototype atmosphere initialized: %dx%dx%d (%d cells)",
			grid.SizeX,
			grid.SizeY,
			grid.SizeZ,
			grid.Count
		)
	)
end

function SimulationController.GetState()
	return state
end

function SimulationController.GetGrid()
	return grid
end

return SimulationController
