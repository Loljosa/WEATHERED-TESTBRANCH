--!strict

local Config = require(script.Parent.CloudRenderConfig)
local LOD = {}
local HYSTERESIS = 0.12

-- Levels: 0 culled, 1 near, 2 medium, 3 distant. Hysteresis only changes
-- subdivision budgets, never the authoritative field or deterministic placement.
-- Returns level, maximum 3D per-axis subdivision, size multiplier and priority (0..1).
function LOD.Decide(
	distance: number,
	previous: number?,
	quality: Config.Quality
): (number, number, number, number)
	assert(
		distance == distance and distance >= 0 and distance < math.huge,
		"Cloud LOD distance must be finite and nonnegative"
	)
	local old = previous
	assert(old == nil or (old % 1 == 0 and old >= 0 and old <= 3), "Cloud LOD history must be 0..3")
	local view = quality.ViewDistance
	local near, middle = view * 0.25, view * 0.60
	local level
	if old == 0 and distance >= view * (1 - HYSTERESIS) then
		level = 0
	elseif distance > view * (if old == nil then 1 else 1 + HYSTERESIS) then
		level = 0
	elseif old == 1 and distance <= near * (1 + HYSTERESIS) then
		level = 1
	elseif
		old == 2
		and distance >= near * (1 - HYSTERESIS)
		and distance <= middle * (1 + HYSTERESIS)
	then
		level = 2
	elseif old == 3 and distance >= middle * (1 - HYSTERESIS) then
		level = 3
	else
		level = if distance < near then 1 elseif distance < middle then 2 else 3
	end
	if level == 0 then
		return 0, 0, 1, 0
	end
	local samples = if level == 1
		then quality.NearSubdivisions
		elseif level == 2 then quality.MediumSubdivisions
		else quality.FarSubdivisions
	local scale = 1 -- Cube geometry determines size from a stable 48-stud 3D lattice.
	return level, samples, scale, math.clamp(1 - distance / (view * (1 + HYSTERESIS)), 0, 1)
end

return table.freeze(LOD)
