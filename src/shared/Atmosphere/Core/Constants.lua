--!strict

local Constants = {
	Gravity = 9.80665,

	DryAirGasConstant = 287.05,
	WaterVaporGasConstant = 461.5,

	SpecificHeatDryAir = 1004.0,

	ReferencePressure = 100000.0,
	ReferenceTemperature = 300.0,

	Epsilon = 0.622,
}

return table.freeze(Constants)
