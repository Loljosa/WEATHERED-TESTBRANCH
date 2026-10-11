--!strict

-- Coverage scenarios configure thermodynamic conditions and forcing, not liquid
-- cloud geometry. These RH values describe the narrow elevated cloud layer,
-- not surface humidity. Real qc coverage is a transport/microphysics outcome.
local Coverage = {}

export type Scenario = {
	Name: string,
	EnvironmentalRH: number,
	InitialSourceCount: number,
	FullInitialSourceCount: number,
	FormationIntervalTicks: number,
	FormationProbability: number,
	Intensity: number,
}

local scenarios: { [string]: Scenario } = {
	clear = table.freeze({
		Name = "Clear",
		EnvironmentalRH = 0.55,
		InitialSourceCount = 0,
		FullInitialSourceCount = 0,
		FormationIntervalTicks = 720,
		FormationProbability = 0,
		Intensity = 0.75,
	}),
	few = table.freeze({
		Name = "Few",
		EnvironmentalRH = 0.98,
		InitialSourceCount = 2,
		FullInitialSourceCount = 3,
		FormationIntervalTicks = 360,
		FormationProbability = 0.4,
		Intensity = 0.85,
	}),
	scattered = table.freeze({
		Name = "Scattered",
		EnvironmentalRH = 0.995,
		InitialSourceCount = 6,
		FullInitialSourceCount = 8,
		FormationIntervalTicks = 180,
		FormationProbability = 0.7,
		Intensity = 1,
	}),
	broken = table.freeze({
		Name = "Broken",
		EnvironmentalRH = 0.997,
		InitialSourceCount = 10,
		FullInitialSourceCount = 12,
		FormationIntervalTicks = 120,
		FormationProbability = 0.8,
		Intensity = 1,
	}),
	overcast = table.freeze({
		Name = "Overcast",
		EnvironmentalRH = 0.999,
		InitialSourceCount = 14,
		FullInitialSourceCount = 16,
		FormationIntervalTicks = 90,
		FormationProbability = 0.9,
		Intensity = 1,
	}),
}

function Coverage.Get(name: string?): Scenario
	assert(name == nil or type(name) == "string", "Cloud coverage must be a scenario name")
	local result = scenarios[string.lower(name or "Scattered")]
	assert(result ~= nil, "Cloud coverage must be Clear, Few, Scattered, Broken or Overcast")
	return result
end

return table.freeze(Coverage)
