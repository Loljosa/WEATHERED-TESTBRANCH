--!strict

local Config = require(script.Parent.CloudRenderConfig)
local Lighting = {}

local function finite(value: number)
	assert(value == value and math.abs(value) < math.huge, "Cloud lighting input must be finite")
end

local function unit(x: number, y: number, z: number): (number, number, number)
	-- Scaling first avoids overflow for otherwise valid finite inputs.
	local maximum = math.max(math.abs(x), math.abs(y), math.abs(z))
	if maximum == 0 then
		return 0, 0, 0
	end
	x, y, z = x / maximum, y / maximum, z / maximum
	local length = math.sqrt(x * x + y * y + z * z)
	return x / length, y / length, z / length
end

-- Cheap neutral cloud illumination, not volumetric multiple scattering. The
-- outward normal is -grad(qc); sun is a unit vector towards the sun. Density
-- and local relative height provide a bounded approximate optical depth.
-- ambient is normalized scalar sky brightness, with a neutral gray night floor.
function Lighting.Shade(
	density: number,
	height: number,
	gx: number,
	gy: number,
	gz: number,
	sx: number,
	sy: number,
	sz: number,
	ambient: number,
	opticalDepth: number?
): (number, number, number)
	finite(density)
	finite(height)
	finite(gx)
	finite(gy)
	finite(gz)
	finite(sx)
	finite(sy)
	finite(sz)
	finite(ambient)
	assert(
		density >= 0 and density <= 1 and ambient >= 0 and ambient <= 1,
		"Cloud density and ambient must be 0..1"
	)
	local h = math.clamp(height, 0, 1)
	local _, _, layer = Config.Layer(h)
	local nx, ny, nz = unit(gx, gy, gz)
	local sunX, sunY, sunZ = unit(sx, sy, sz)
	local incidence = math.max(0, -(nx * sunX + ny * sunY + nz * sunZ))
	local depth = if opticalDepth ~= nil then opticalDepth else density * (0.35 + 1.15 * (1 - h))
	finite(depth)
	assert(depth >= 0, "Cloud optical depth must be nonnegative")
	local attenuation = math.exp(-0.30 * math.min(depth, 8))
	local daylight = math.clamp(sunY * 0.65 + 0.35, 0, 1)
	local brightness = (0.44 + 0.34 * ambient + 0.12 * daylight + 0.10 * incidence)
		* layer
		* (0.78 + 0.22 * attenuation)
	brightness = math.clamp(brightness, 0.24, 1)
	return brightness, brightness, brightness
end

-- Optional bounded low-sample attenuation. sample(x,y,z) is display density,
-- stepStuds is a rendering path length; this never reads/writes simulation mass.
-- Use cached selected cube points, not every fragment or every Heartbeat.
function Lighting.OpticalDepth(
	sample: (number, number, number) -> number,
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	stepStuds: number,
	count: number
): number
	finite(x)
	finite(y)
	finite(z)
	finite(sx)
	finite(sy)
	finite(sz)
	finite(stepStuds)
	assert(
		stepStuds > 0 and count % 1 == 0 and count >= 0 and count <= 3,
		"Cloud light integration needs positive step and 0..3 samples"
	)
	local sunX, sunY, sunZ = unit(sx, sy, sz)
	if (sunX == 0 and sunY == 0 and sunZ == 0) or count == 0 then
		return 0
	end
	local depth = 0
	for index = 1, count do
		local distance = stepStuds * (index - 0.5)
		local density = sample(x + sunX * distance, y + sunY * distance, z + sunZ * distance)
		finite(density)
		assert(density >= 0 and density <= 1, "Optical sampling density must be 0..1")
		depth += density * stepStuds / 100
	end
	return depth
end

return table.freeze(Lighting)
