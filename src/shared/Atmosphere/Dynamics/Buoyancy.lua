--!native
--!strict

local Constants = require(script.Parent.Parent.Core.Constants)

local Buoyancy = {}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- Dilute virtual-potential-temperature approximation includes liquid loading.
-- theta: K; qv/qc: kg/kg dry air; return acceleration in physical m/s^2.
function Buoyancy.Calculate(
	theta: number,
	qv: number,
	qc: number,
	environmentTheta: number,
	environmentQv: number
): number
	assert(finite(theta) and theta > 0, "Potential temperature must be finite and positive (K)")
	assert(
		finite(environmentTheta) and environmentTheta > 0,
		"Environment theta must be finite and positive (K)"
	)
	assert(
		finite(qv) and qv >= 0 and finite(qc) and qc >= 0,
		"Parcel water must be finite and nonnegative"
	)
	assert(
		finite(environmentQv) and environmentQv >= 0,
		"Environment vapor must be finite and nonnegative"
	)
	local virtualTheta = theta * (1 + Constants.VirtualTemperatureVaporFactor * qv - qc)
	local referenceVirtualTheta = environmentTheta
		* (1 + Constants.VirtualTemperatureVaporFactor * environmentQv)
	assert(finite(virtualTheta) and virtualTheta > 0, "Virtual theta must be finite and positive")
	assert(
		finite(referenceVirtualTheta) and referenceVirtualTheta > 0,
		"Reference virtual theta must be finite and positive"
	)
	local acceleration = Constants.Gravity
		* (virtualTheta - referenceVirtualTheta)
		/ referenceVirtualTheta
	assert(finite(acceleration), "Buoyancy calculation overflowed")
	return acceleration
end

-- Exact constant-buoyancy integration of dw/dt = b - w/tau.
-- w m/s, buoyancy m/s^2, dt seconds, dragTimescale seconds.
function Buoyancy.UpdateVelocity(
	w: number,
	buoyancy: number,
	dt: number,
	dragTimescale: number
): number
	assert(finite(w) and finite(buoyancy), "Velocity and buoyancy must be finite")
	assert(finite(dt) and dt >= 0, "Timestep must be finite and nonnegative (s)")
	assert(
		finite(dragTimescale) and dragTimescale > 0,
		"Drag timescale must be finite and positive (s)"
	)
	local ratio = dt / dragTimescale
	local decay = math.exp(-ratio)
	local responseTime = dragTimescale * (1 - decay)
	if ratio < 1e-5 then
		-- Avoid loss of significance in 1 - exp(-ratio) for very small dt.
		responseTime = dt * (1 - ratio * 0.5 + ratio * ratio / 6)
	end
	local velocity = w * decay + buoyancy * responseTime
	assert(finite(velocity), "Vertical velocity update overflowed")
	return velocity
end

return table.freeze(Buoyancy)
