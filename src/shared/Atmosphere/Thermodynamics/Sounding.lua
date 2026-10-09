--!strict

local Constants = require(script.Parent.Parent.Core.Constants)
local AtmosphereState = require(script.Parent.Parent.Core.AtmosphereState)
local Saturation = require(script.Parent.Saturation)
local Validation = require(script.Parent.Parent.Utilities.Validation)

local Sounding = {}

export type Options = {
	BackgroundU: number?, -- m/s at the model bottom
	BackgroundV: number?, -- m/s at the model bottom
	ShearU: number?, -- (m/s)/m of physical height
	ShearV: number?, -- (m/s)/m of physical height
	BubbleRelativeHumidity: number?, -- fraction in (0, 1]; core default remains 0.98.
	BubbleTemperaturePerturbation: number?, -- warm-core potential-temperature excess, K; default 2.
	BubbleShape: string?, -- Round, Wide or Tower; shapes initialize theta/qv, never qc.
	BubbleScale: number?, -- dimensionless radius multiplier, 0.5..1.5; default 1.
}

export type Profile = {
	Theta: buffer,
	Qv: buffer,
	U: buffer,
	V: buffer,
	CellHeightMeters: number,
}

-- A dry-stable, conditionally unstable warm sounding. Height is above the
-- model's bottom, not workspace Y. Pressure is an absolute background (Pa).
local SURFACE_THETA = 300 -- K
local THETA_GRADIENT = 0.003 -- K/m
local SURFACE_RH = 0.85
local MOISTURE_SCALE_HEIGHT = 3000 -- m
local MAX_FLOAT32 = 3.4028234663852886e38

function Sounding.Initialize(
	state: AtmosphereState.AtmosphereState,
	cellHeightMeters: number,
	options: Options?
): Profile
	assert(
		cellHeightMeters > 0 and cellHeightMeters < math.huge,
		"Physical cell height must be positive and finite"
	)
	local settings: Options = options or {}
	local backgroundU = settings.BackgroundU or 0
	local backgroundV = settings.BackgroundV or 0
	local shearU = settings.ShearU or 0
	local shearV = settings.ShearV or 0
	local bubbleRH = settings.BubbleRelativeHumidity or 0.98
	local bubbleTemperature = settings.BubbleTemperaturePerturbation or 2
	local shape = settings.BubbleShape or "Round"
	local scale = settings.BubbleScale or 1
	assert(shape == "Round" or shape == "Wide" or shape == "Tower", "Unknown BubbleShape")
	assert(
		Validation.IsFinite(scale) and scale >= 0.5 and scale <= 1.5,
		"BubbleScale must be 0.5..1.5"
	)
	assert(Validation.IsFinite(backgroundU), "BackgroundU must be finite")
	assert(Validation.IsFinite(backgroundV), "BackgroundV must be finite")
	assert(Validation.IsFinite(shearU), "ShearU must be finite")
	assert(Validation.IsFinite(shearV), "ShearV must be finite")
	assert(
		Validation.IsFinite(bubbleRH) and bubbleRH > 0 and bubbleRH <= 1,
		"BubbleRelativeHumidity must be finite and in (0, 1]"
	)
	assert(
		Validation.IsFinite(bubbleTemperature) and bubbleTemperature >= 0,
		"BubbleTemperaturePerturbation must be finite and nonnegative (K)"
	)

	local grid = state.Grid
	local profile: Profile = {
		Theta = buffer.create(grid.SizeY * 4),
		Qv = buffer.create(grid.SizeY * 4),
		U = buffer.create(grid.SizeY * 4),
		V = buffer.create(grid.SizeY * 4),
		CellHeightMeters = cellHeightMeters,
	}

	state:Fill("w", 0)
	state:Fill("qc", 0)
	state:Fill("qr", 0)

	local centerX = (grid.SizeX + 1) * 0.5
	local centerZ = (grid.SizeZ + 1) * 0.5
	local centerY = math.min(if shape == "Tower" then 4 else 3, (grid.SizeY + 1) * 0.5)
	local width = if shape == "Wide" then 0.3 else 0.1875
	local radiusX = math.max(1, grid.SizeX * width * scale)
	local radiusZ = math.max(1, grid.SizeZ * width * scale)
	local radiusY = (if shape == "Tower" then 3 else 2) * scale -- physical height = radiusY * Dy.
	local layerStride = grid.SizeX * grid.SizeZ

	for y = 1, grid.SizeY do
		local height = (y - 0.5) * cellHeightMeters
		local u = backgroundU + shearU * height
		local v = backgroundV + shearV * height
		assert(
			Validation.IsFinite(u) and math.abs(u) <= MAX_FLOAT32,
			"Sounding U must be finite and representable as float32"
		)
		assert(
			Validation.IsFinite(v) and math.abs(v) <= MAX_FLOAT32,
			"Sounding V must be finite and representable as float32"
		)
		local theta = SURFACE_THETA + THETA_GRADIENT * height
		-- Integrate d(Pi)/dz = -g/(cp*theta(z)) for linear theta(z).
		local exner = 1
			- Constants.Gravity
				/ (Constants.SpecificHeatDryAir * THETA_GRADIENT)
				* math.log(theta / SURFACE_THETA)
		assert(exner > 0, "Sounding exceeds hydrostatic profile height range")
		local pressure = Constants.ReferencePressure
			* exner ^ (Constants.SpecificHeatDryAir / Constants.DryAirGasConstant)
		local rh = SURFACE_RH * math.exp(-height / MOISTURE_SCALE_HEIGHT)
		local qv = rh * Saturation.MixingRatio(theta * exner, pressure)
		local rowOffset = (y - 1) * 4
		buffer.writef32(profile.Theta, rowOffset, theta)
		buffer.writef32(profile.Qv, rowOffset, qv)
		buffer.writef32(profile.U, rowOffset, u)
		buffer.writef32(profile.V, rowOffset, v)

		for z = 1, grid.SizeZ do
			for x = 1, grid.SizeX do
				local dx = (x - centerX) / radiusX
				local dy = (y - centerY) / radiusY
				local dz = (z - centerZ) / radiusZ
				local radiusSquared = dx * dx + dy * dy + dz * dz
				local strength = 0
				if radiusSquared < 1 and y > 1 and y < grid.SizeY then
					-- A moist core with a smooth edge survives coarse-grid upwind
					-- dilution; a narrow Gaussian disappears before it can rise.
					if radiusSquared <= 0.25 then
						strength = 1
					else
						local edge = (radiusSquared - 0.25) / 0.75
						strength = 1 - edge * edge * (3 - 2 * edge)
					end
				end
				local parcelTheta = theta + bubbleTemperature * strength -- K; no prescribed w or qc.
				local parcelRH = rh + (bubbleRH - rh) * strength
				local parcelQv = parcelRH * Saturation.MixingRatio(parcelTheta * exner, pressure)
				local offset = ((y - 1) * layerStride + (z - 1) * grid.SizeX + x - 1) * 4
				buffer.writef32(state.Fields.u, offset, u)
				buffer.writef32(state.Fields.v, offset, v)
				buffer.writef32(state.Fields.theta, offset, parcelTheta)
				buffer.writef32(state.Fields.qv, offset, parcelQv)
				buffer.writef32(state.Fields.pressure, offset, pressure)
			end
		end
	end

	return profile
end

return table.freeze(Sounding)
