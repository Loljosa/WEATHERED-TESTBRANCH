--!native
--!strict

local AtmosphereState = require(script.Parent.Parent.Core.AtmosphereState)

local Validation = {}

local FIELD_NAMES: { AtmosphereState.FieldName } =
	{ "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" }

function Validation.IsFinite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

-- Fail at the source instead of concealing instability with velocity/moisture caps.
-- Invalid-cell messages are only constructed on failure.
function Validation.CheckState(state: AtmosphereState.AtmosphereState)
	for _, name in FIELD_NAMES do
		local field = state.Fields[name]
		assert(
			field ~= nil and buffer.len(field) == state.Grid.Count * 4,
			"Invalid atmospheric field buffer: " .. name
		)
		local isWater = name == "qv" or name == "qc" or name == "qr"
		local isPositive = name == "theta" or name == "pressure"
		for index = 1, state.Grid.Count do
			local value = buffer.readf32(field, (index - 1) * 4)
			local valid = Validation.IsFinite(value)
			if isWater then
				valid = valid and value >= 0
			elseif isPositive then
				valid = valid and value > 0
			end
			if not valid then
				error(string.format("Invalid %s at cell %d: %s", name, index, tostring(value)))
			end
		end
	end
end

return table.freeze(Validation)
