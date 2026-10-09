--!strict

local Constants = require(script.Parent.Parent.Core.Constants)
local Saturation = require(script.Parent.Parent.Thermodynamics.Saturation)
local Thermodynamics = require(script.Parent.Parent.Thermodynamics.Thermodynamics)

local WarmCloud = {}
local LATENT_TEMPERATURE = Constants.LatentHeatVaporization / Constants.SpecificHeatDryAir
local WATER_TOLERANCE = 1e-10 -- kg/kg, below float32 field precision at cloud mixing ratios
local MAX_ITERATIONS = 40
local MAX_FLOAT32 = 3.4028234663852886e38

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

local function roundFloat32(value: number, rounding: buffer): number
	assert(
		value == value and math.abs(value) <= MAX_FLOAT32,
		"Phase adjustment cannot represent a finite float32 value"
	)
	buffer.writef32(rounding, 0, value)
	return buffer.readf32(rounding, 0)
end

-- Quantize a phase transfer as one coupled operation for float32 state fields.
-- The caller owns reusable scratch of at least four bytes; this module has no
-- mutable global scratch. Adjust remains the double-precision mathematical API.
-- Vapor is rounded first, liquid compensates the represented vapor change, and
-- latent heat uses that same change. An unrepresentable sub-ULP vapor transfer
-- cannot repeatedly create liquid while vapor and theta stay fixed.
function WarmCloud.AdjustFloat32(
	theta: number,
	qv: number,
	qc: number,
	pressure: number,
	rounding: buffer
): (number, number, number)
	assert(buffer.len(rounding) >= 4, "Phase rounding scratch must contain at least four bytes")
	local _, targetVapor = WarmCloud.Adjust(theta, qv, qc, pressure)
	local vapor = roundFloat32(targetVapor, rounding)
	local totalWater = qv + qc
	if vapor > totalWater then
		-- Nearest rounding can exceed available water after complete evaporation.
		-- Choose its lower float32 neighbor, leaving a nonnegative residual liquid
		-- reservoir instead of creating water or clipping a cell afterwards.
		buffer.writef32(rounding, 0, totalWater)
		if buffer.readf32(rounding, 0) > totalWater then
			buffer.writeu32(rounding, 0, buffer.readu32(rounding, 0) - 1)
		end
		vapor = buffer.readf32(rounding, 0)
	end
	local delta = qv - vapor
	-- qc+delta equals totalWater-vapor but preserves tiny existing qc when
	-- delta==0, avoiding its loss when adding it to a much larger vapor reservoir.
	local cloud = roundFloat32(qc + delta, rounding)
	local adjustedTheta =
		roundFloat32(theta + LATENT_TEMPERATURE / Thermodynamics.Exner(pressure) * delta, rounding)
	assert(
		nonnegativeFinite(vapor) and nonnegativeFinite(cloud),
		"Coupled phase adjustment produced invalid water"
	)
	return adjustedTheta, vapor, cloud
end

return table.freeze(WarmCloud)
