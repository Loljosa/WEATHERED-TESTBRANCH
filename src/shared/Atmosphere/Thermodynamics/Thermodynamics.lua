--!strict

local Constants = require(script.Parent.Parent.Core.Constants)

local Thermodynamics = {}
local KAPPA = Constants.DryAirGasConstant / Constants.SpecificHeatDryAir

local function positiveFinite(value: number): boolean
	return value > 0 and value < math.huge
end

-- Dimensionless Exner function for absolute pressure in Pa.
function Thermodynamics.Exner(pressure: number): number
	assert(positiveFinite(pressure), "Pressure must be finite and positive (Pa)")
	local exner = (pressure / Constants.ReferencePressure) ^ KAPPA
	assert(positiveFinite(exner), "Exner calculation overflowed or underflowed")
	return exner
end

-- Potential temperature and absolute temperature are both in Kelvin.
function Thermodynamics.Temperature(theta: number, pressure: number): number
	assert(positiveFinite(theta), "Potential temperature must be finite and positive (K)")
	local temperature = theta * Thermodynamics.Exner(pressure)
	assert(positiveFinite(temperature), "Temperature conversion overflowed")
	return temperature
end

function Thermodynamics.PotentialTemperature(temperature: number, pressure: number): number
	assert(positiveFinite(temperature), "Temperature must be finite and positive (K)")
	local theta = temperature / Thermodynamics.Exner(pressure)
	assert(positiveFinite(theta), "Potential temperature conversion overflowed")
	return theta
end

return table.freeze(Thermodynamics)
