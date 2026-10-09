--!strict

-- Startup-only server preview presets. Both cover the same physical domain;
-- the laptop preset coarsens X/Z rather than shortening the atmosphere.
local PerformanceSettings = {}

export type Settings = {
	SizeX: number,
	SizeY: number,
	SizeZ: number,
	Dx: number,
	Dy: number,
	Dz: number,
	MaxCatchUpSteps: number,
	FrameBudgetMilliseconds: number,
	DebugRenderInterval: number,
}

local LAPTOP: Settings = table.freeze({
	SizeX = 16,
	SizeY = 12,
	SizeZ = 16,
	Dx = 150,
	Dy = 100,
	Dz = 150,
	MaxCatchUpSteps = 1,
	FrameBudgetMilliseconds = 8,
	DebugRenderInterval = 1, -- wall-clock seconds; physical timestep stays 0.25 s.
})

local FULL: Settings = table.freeze({
	SizeX = 24,
	SizeY = 12,
	SizeZ = 24,
	Dx = 100,
	Dy = 100,
	Dz = 100,
	MaxCatchUpSteps = 2,
	FrameBudgetMilliseconds = 8,
	DebugRenderInterval = 0.5,
})

function PerformanceSettings.Resolve(preset: string): Settings
	assert(preset == "Laptop" or preset == "Full", "PerformancePreset must be Laptop or Full")
	return if preset == "Laptop" then LAPTOP else FULL
end

return table.freeze(PerformanceSettings)
