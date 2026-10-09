--!native
--!strict

local Constants = require(script.Parent.Parent.Core.Constants)

local Saturation = {}

local function validateTemperature(temperature: number)
	assert(
		-- Allow only roundoff at a bounded root-solver temperature endpoint.
		temperature >= Constants.SaturationMinimumTemperature - 1e-10
			and temperature <= Constants.SaturationMaximumTemperature + 1e-10,
		"Temperature outside supported liquid-water saturation domain (180-350 K)"
	)
end

-- Bolton liquid-water approximation. Input K, outputs Pa and Pa/K.
-- Supercooled water is represented as liquid; this milestone has no ice phase.
function Saturation.VaporPressureAndDerivative(temperature: number): (number, number)
	validateTemperature(temperature)
	local celsius = temperature - 273.15
	local denominator = celsius + 243.5
	local vaporPressure = 611.2 * math.exp(17.67 * celsius / denominator)
	local derivative = vaporPressure * 17.67 * 243.5 / (denominator * denominator)
	return vaporPressure, derivative
end

function Saturation.VaporPressure(temperature: number): number
	local vaporPressure = Saturation.VaporPressureAndDerivative(temperature)
	return vaporPressure
end

-- Dry-air mixing ratio epsilon * e_s / (p - e_s), in kg/kg.
function Saturation.MixingRatioAndDerivative(
	temperature: number,
	pressure: number
): (number, number)
	assert(pressure > 0 and pressure < math.huge, "Pressure must be finite and positive (Pa)")
	local vaporPressure, vaporDerivative = Saturation.VaporPressureAndDerivative(temperature)
	assert(pressure > vaporPressure, "Pressure must exceed saturation vapor pressure")
	local denominator = pressure - vaporPressure
	local mixingRatio = Constants.Epsilon * vaporPressure / denominator
	local derivative = Constants.Epsilon * pressure * vaporDerivative / (denominator * denominator)
	assert(mixingRatio < math.huge and derivative < math.huge, "Saturation calculation overflowed")
	return mixingRatio, derivative
end

function Saturation.MixingRatio(temperature: number, pressure: number): number
	local mixingRatio = Saturation.MixingRatioAndDerivative(temperature, pressure)
	return mixingRatio
end

return table.freeze(Saturation)
