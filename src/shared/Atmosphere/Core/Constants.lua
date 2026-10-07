--!strict

local Constants = {
	Gravity = 9.80665,

	DryAirGasConstant = 287.05,
	WaterVaporGasConstant = 461.5,

	SpecificHeatDryAir = 1004.0,
	LatentHeatVaporization = 2500000.0, -- J/kg; constant warm-cloud approximation

	ReferencePressure = 100000.0,
	ReferenceTemperature = 300.0,

	Epsilon = 0.622,
	VirtualTemperatureVaporFactor = 0.61,

	-- Supported liquid-water saturation approximation domain, in Kelvin.
	SaturationMinimumTemperature = 180.0,
	SaturationMaximumTemperature = 350.0,
}

return table.freeze(Constants)
