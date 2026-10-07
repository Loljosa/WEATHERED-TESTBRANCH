--!strict

local Constants = require(script.Parent.Parent.Core.Constants)
local AtmosphereState = require(script.Parent.Parent.Core.AtmosphereState)
local Saturation = require(script.Parent.Saturation)

local Sounding = {}

export type Profile = {
	Theta: buffer,
	Qv: buffer,
	CellHeightMeters: number,
}

-- A dry-stable, conditionally unstable warm sounding. Height is above the
-- model's bottom, not workspace Y. Pressure is an absolute background (Pa).
local SURFACE_THETA = 300 -- K
local THETA_GRADIENT = 0.003 -- K/m
local SURFACE_RH = 0.85
local MOISTURE_SCALE_HEIGHT = 3000 -- m

function Sounding.Initialize(
	state: AtmosphereState.AtmosphereState,
	cellHeightMeters: number
): Profile
	assert(
		cellHeightMeters > 0 and cellHeightMeters < math.huge,
		"Physical cell height must be positive and finite"
	)
	local grid = state.Grid
	local profile: Profile = {
		Theta = buffer.create(grid.SizeY * 4),
		Qv = buffer.create(grid.SizeY * 4),
		CellHeightMeters = cellHeightMeters,
	}

	state:Fill("u", 0)
	state:Fill("v", 0)
	state:Fill("w", 0)
	state:Fill("qc", 0)
	state:Fill("qr", 0)

	local centerX = (grid.SizeX + 1) * 0.5
	local centerZ = (grid.SizeZ + 1) * 0.5
	local centerY = math.min(3, (grid.SizeY + 1) * 0.5)
	local radiusX = math.max(1, grid.SizeX * 0.1875)
	local radiusZ = math.max(1, grid.SizeZ * 0.1875)
	local layerStride = grid.SizeX * grid.SizeZ

	for y = 1, grid.SizeY do
		local height = (y - 0.5) * cellHeightMeters
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

		for z = 1, grid.SizeZ do
			for x = 1, grid.SizeX do
				local dx = (x - centerX) / radiusX
				local dy = (y - centerY) / 2
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
				local parcelTheta = theta + 2 * strength -- K warm bubble; no prescribed w or qc.
				local parcelRH = rh + (0.98 - rh) * strength
				local parcelQv = parcelRH * Saturation.MixingRatio(parcelTheta * exner, pressure)
				local offset = ((y - 1) * layerStride + (z - 1) * grid.SizeX + x - 1) * 4
				buffer.writef32(state.Fields.theta, offset, parcelTheta)
				buffer.writef32(state.Fields.qv, offset, parcelQv)
				buffer.writef32(state.Fields.pressure, offset, pressure)
			end
		end
	end

	return profile
end

return table.freeze(Sounding)
