--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Atmosphere = require(ReplicatedStorage.Shared.Atmosphere)

local SimulationController = require(
	script.Parent.Simulation.SimulationController
)

local VoxelDebugRenderer = require(
	script.Parent.Debug.VoxelDebugRenderer
)

print(
	"[WEATHERED] Starting atmosphere engine",
	Atmosphere.GetVersion()
)

SimulationController.Initialize()

local state = SimulationController.GetState()

VoxelDebugRenderer.Render(
	state,
	0.00025,
	1200
)
