--!strict

local Constants = require(script.Parent.Parent.Core.Constants)
local Saturation = require(script.Parent.Parent.Thermodynamics.Saturation)
local Thermodynamics = require(script.Parent.Parent.Thermodynamics.Thermodynamics)

local WarmCloud = {}
local LATENT_TEMPERATURE = Constants.LatentHeatVaporization / Constants.SpecificHeatDryAir
local WATER_TOLERANCE = 1e-10 -- kg/kg, below float32 field precision at cloud mixing ratios
local MAX_ITERATIONS = 40

local function nonnegativeFinite(value: number): boolean
	return value >= 0 and value < math.huge
end

-- Residual equivalent to q_v - delta = q_sat(T + L_v/c_p * delta, p).
-- This form avoids the q_sat pole when a trial temperature gives e_s >= p.
local function residual(
	delta: number,
	temperature: number,
	qv: number,
	pressure: number
): (number, number)
	local trialTemperature = temperature + LATENT_TEMPERATURE * delta
	local vaporPressure, vaporDerivative = Saturation.VaporPressureAndDerivative(trialTemperature)
	local remainingVapor = qv - delta
	local vaporFraction = vaporPressure / pressure
	local value = remainingVapor - (Constants.Epsilon + remainingVapor) * vaporFraction
	local derivative = -1
		+ vaporFraction
		- (Constants.Epsilon + remainingVapor) * vaporDerivative / pressure * LATENT_TEMPERATURE
	return value, derivative
end

-- Instantaneous, reversible liquid-water saturation adjustment at fixed pressure.
-- Inputs/outputs: theta K; qv and qc kg/kg dry air; absolute pressure Pa.
-- Positive delta condenses vapor and heats air; negative delta evaporates and cools.
function WarmCloud.Adjust(
	theta: number,
	qv: number,
	qc: number,
	pressure: number
): (number, number, number)
	assert(nonnegativeFinite(qv), "Water vapor must be finite and nonnegative (kg/kg)")
	assert(nonnegativeFinite(qc), "Cloud water must be finite and nonnegative (kg/kg)")
	local temperature = Thermodynamics.Temperature(theta, pressure)
	local saturation = Saturation.MixingRatio(temperature, pressure)
	local totalWater = qv + qc
	assert(totalWater < math.huge, "Total water overflowed")

	if math.abs(qv - saturation) <= WATER_TOLERANCE or (qv < saturation and qc == 0) then
		return theta, qv, qc
	end

	-- These bounds conserve water and keep trial temperatures in the declared
	-- saturation domain. Reaching a temperature bound is an error, not a clamp.
	local lower =
		math.max(-qc, (Constants.SaturationMinimumTemperature - temperature) / LATENT_TEMPERATURE)
	local upper =
		math.min(qv, (Constants.SaturationMaximumTemperature - temperature) / LATENT_TEMPERATURE)
	if qv > saturation then
		lower = 0
		local upperResidual = residual(upper, temperature, qv, pressure)
		assert(
			upperResidual <= 0,
			"Condensation would exceed supported saturation temperature domain"
		)
	else
		upper = 0
		local lowerResidual = residual(lower, temperature, qv, pressure)
		if lowerResidual <= 0 then
			assert(lower == -qc, "Evaporation would exceed supported saturation temperature domain")
			return Thermodynamics.PotentialTemperature(
				temperature - LATENT_TEMPERATURE * qc,
				pressure
			),
				totalWater,
				0
		end
	end

	local delta = 0
	local converged = false
	for _ = 1, MAX_ITERATIONS do
		local value, derivative = residual(delta, temperature, qv, pressure)
		if math.abs(value) <= WATER_TOLERANCE then
			converged = true
			break
		end

		if value > 0 then
			lower = delta
		else
			upper = delta
		end

		local candidate = delta - value / derivative
		if candidate > lower and candidate < upper then
			delta = candidate
		else
			delta = 0.5 * (lower + upper)
		end
	end
	assert(converged, "Warm-cloud saturation solve did not converge")

	local newCloudWater = qc + delta
	local newVapor = totalWater - newCloudWater
	local newTheta =
		Thermodynamics.PotentialTemperature(temperature + LATENT_TEMPERATURE * delta, pressure)
	assert(
		nonnegativeFinite(newCloudWater) and nonnegativeFinite(newVapor),
		"Saturation adjustment produced invalid water"
	)
	return newTheta, newVapor, newCloudWater
end

return table.freeze(WarmCloud)
