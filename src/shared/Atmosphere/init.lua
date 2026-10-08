--!strict

local Simulation = require(script.Simulation)
local Grid3D = require(script.Core.Grid3D)

export type Simulation = Simulation.Simulation
export type Diagnostics = Simulation.Diagnostics
export type Config = Simulation.Config

local Atmosphere = {}

Atmosphere.Version = "0.2.0-alpha"
Atmosphere.FixedDt = Simulation.FixedDt
Atmosphere.CellHeightMeters = Simulation.CellHeightMeters

function Atmosphere.new(grid: Grid3D.Grid3D, config: Simulation.Config?): Simulation.Simulation
	return Simulation.new(grid, config)
end

function Atmosphere.GetVersion(): string
	return Atmosphere.Version
end

return Atmosphere
