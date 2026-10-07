--!strict

local Simulation = require(script.Simulation)
local Grid3D = require(script.Core.Grid3D)

export type Simulation = Simulation.Simulation
export type Diagnostics = Simulation.Diagnostics

local Atmosphere = {}

Atmosphere.Version = "0.1.0-alpha"
Atmosphere.FixedDt = Simulation.FixedDt
Atmosphere.CellHeightMeters = Simulation.CellHeightMeters

function Atmosphere.new(grid: Grid3D.Grid3D): Simulation.Simulation
	return Simulation.new(grid)
end

function Atmosphere.GetVersion(): string
	return Atmosphere.Version
end

return Atmosphere
