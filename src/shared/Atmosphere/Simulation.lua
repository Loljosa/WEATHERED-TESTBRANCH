--!strict

local Grid3D = require(script.Parent.Core.Grid3D)
local AtmosphereState = require(script.Parent.Core.AtmosphereState)
local Geometry = require(script.Parent.Core.Geometry)
local FaceVelocity = require(script.Parent.Core.FaceVelocity)
local Sounding = require(script.Parent.Thermodynamics.Sounding)
local WarmCloud = require(script.Parent.Microphysics.WarmCloud)
local Momentum = require(script.Parent.Dynamics.Momentum)
local Projection = require(script.Parent.Dynamics.Projection)
local Transport = require(script.Parent.Dynamics.Transport)
local Validation = require(script.Parent.Utilities.Validation)

local Simulation = {}
Simulation.__index = Simulation
Simulation.FixedDt = 0.25 -- physical seconds, independent of Heartbeat dt.
Simulation.CellHeightMeters = 100 -- legacy default; each grid owns its actual Dy.

export type Config = {
	BackgroundU: number?,
	BackgroundV: number?,
	ShearU: number?,
	ShearV: number?,
	MomentumOptions: Momentum.Options?,
	ProjectionOptions: Projection.Options?,
}

export type Diagnostics = {
	Time: number,
	CloudCells: number,
	MaxCloudWater: number,
	MaxVerticalVelocity: number,
	TotalWater: number, -- compatibility alias for WaterSum, NOT kilograms.
	QvSum: number,
	QcSum: number,
	QrSum: number,
	WaterSum: number, -- unweighted cell mixing-ratio sum, kg/kg summed over cells.
	WaterDriftFraction: number,
	MinU: number,
	MaxU: number,
	MinV: number,
	MaxV: number,
	MinW: number,
	MaxW: number,
	DivergenceBeforeRms: number,
	DivergenceAfterRms: number,
	DivergenceBeforeMax: number,
	DivergenceAfterMax: number,
	ProjectionIterations: number,
	ProjectionResidual: number, -- divergence-equivalent RMS, s^-1.
	ProjectionTolerance: number,
	ProjectionQuantizationFloor: number,
	MaxCourant: number,
	MomentumCourant: number,
	TransportCourant: number,
	StepMilliseconds: number, -- measured wall-clock duration, not simulation time.
	CloudCentroidDefined: boolean,
	CloudCentroidX: number,
	CloudCentroidY: number,
	CloudCentroidZ: number, -- meters from domain corner.
}

export type Simulation = typeof(setmetatable(
	{} :: {
		State: AtmosphereState.AtmosphereState,
		Profile: Sounding.Profile,
		Geometry: Geometry.Geometry,
		Faces: FaceVelocity.FaceVelocity,
		Momentum: Momentum.Momentum,
		Projection: Projection.Projection,
		Transport: Transport.Transport,
		Time: number,
		InitialWaterSum: number,
		MomentumCourant: number,
		TransportCourant: number,
		StepMilliseconds: number,
	},
	Simulation
))

local function waterSum(state: AtmosphereState.AtmosphereState): number
	local fields = state.Fields
	local total = 0
	for offset = 0, state.Grid.Count * 4 - 4, 4 do
		total += buffer.readf32(fields.qv, offset) + buffer.readf32(fields.qc, offset) + buffer.readf32(
			fields.qr,
			offset
		)
	end
	return total
end

function Simulation.new(grid: Grid3D.Grid3D, config: Config?): Simulation
	assert(grid.SizeY >= 3, "Atmospheric simulation requires at least three layers")
	local settings = config or {}
	local state = AtmosphereState.new(grid)
	local profile = Sounding.Initialize(state, grid.Dy, {
		BackgroundU = settings.BackgroundU,
		BackgroundV = settings.BackgroundV,
		ShearU = settings.ShearU,
		ShearV = settings.ShearV,
	})
	local geometry = Geometry.new(grid)
	local faces = FaceVelocity.new(geometry)
	faces:Initialize(state)
	faces:WriteCellCenters(state)
	local self = setmetatable({
		State = state,
		Profile = profile,
		Geometry = geometry,
		Faces = faces,
		Momentum = Momentum.new(geometry, settings.MomentumOptions),
		Projection = Projection.new(geometry, settings.ProjectionOptions),
		Transport = Transport.new(geometry),
		Time = 0,
		InitialWaterSum = waterSum(state),
		MomentumCourant = 0,
		TransportCourant = 0,
		StepMilliseconds = 0,
	}, Simulation)
	Validation.CheckState(state)
	return self
end

-- First-order split: old-state momentum predictor -> MAC projection -> shared-face
-- conservative scalar transport -> local saturation/latent heating. Hydrostatic
-- pressure stays fixed in space. Cell-center u/v/w are derived diagnostics ONLY;
-- forcing/transport must change Faces, not those diagnostic buffers.
function Simulation:Step(dt: number)
	assert(
		Validation.IsFinite(dt) and dt > 0 and dt <= Simulation.FixedDt,
		"Step dt must be positive and at most FixedDt"
	)
	local startTime = os.clock()
	Validation.CheckState(self.State)
	self.Faces:CheckFinite()
	self.MomentumCourant = self.Momentum:Predict(self.State, self.Profile, self.Faces, dt)
	self.Projection:Project(self.Faces, dt)
	self.TransportCourant = self.Transport:Advance(self.State, self.Faces, dt)
	local fields = self.State.Fields
	for offset = 0, self.Geometry.Count * 4 - 4, 4 do
		local theta, qv, qc = WarmCloud.Adjust(
			buffer.readf32(fields.theta, offset),
			buffer.readf32(fields.qv, offset),
			buffer.readf32(fields.qc, offset),
			buffer.readf32(fields.pressure, offset)
		)
		buffer.writef32(fields.theta, offset, theta)
		buffer.writef32(fields.qv, offset, qv)
		buffer.writef32(fields.qc, offset, qc)
	end
	self.Faces:WriteCellCenters(self.State)
	Validation.CheckState(self.State)
	self.Time += dt
	self.StepMilliseconds = (os.clock() - startTime) * 1000
end

local function extremes(field: buffer): (number, number)
	local minimum, maximum = math.huge, -math.huge
	for offset = 0, buffer.len(field) - 4, 4 do
		local value = buffer.readf32(field, offset)
		minimum = math.min(minimum, value)
		maximum = math.max(maximum, value)
	end
	return minimum, maximum
end

-- Circular means avoid false centroid jumps when qc crosses a periodic seam.
-- An axis covered uniformly has no unique centroid; flag that rather than invent it.
local function periodicCenter(
	sine: number,
	cosine: number,
	weight: number,
	length: number
): (number, boolean)
	if weight <= 0 or math.sqrt(sine * sine + cosine * cosine) <= weight * 1e-6 then
		return 0, false
	end
	return (math.atan2(sine, cosine) % (2 * math.pi)) * length / (2 * math.pi), true
end

-- Diagnostic-frequency allocation/trigonometry stays outside the physics hot loop.
function Simulation:GetDiagnostics(): Diagnostics
	local fields, grid = self.State.Fields, self.State.Grid
	local cloudCells, maxCloudWater = 0, 0
	local qvSum, qcSum, qrSum = 0, 0, 0
	local sinX, cosX, sinZ, cosZ, weightedY = 0, 0, 0, 0, 0
	for y = 0, grid.SizeY - 1 do
		for z = 0, grid.SizeZ - 1 do
			local angleZ = 2 * math.pi * (z + 0.5) / grid.SizeZ
			for x = 0, grid.SizeX - 1 do
				local offset = (y * self.Geometry.Plane + z * grid.SizeX + x) * 4
				local qc = buffer.readf32(fields.qc, offset)
				if qc >= 0.00005 then
					cloudCells += 1
				end
				maxCloudWater = math.max(maxCloudWater, qc)
				qvSum += buffer.readf32(fields.qv, offset)
				qcSum += qc
				qrSum += buffer.readf32(fields.qr, offset)
				if qc > 0 then
					local angleX = 2 * math.pi * (x + 0.5) / grid.SizeX
					sinX += qc * math.sin(angleX)
					cosX += qc * math.cos(angleX)
					sinZ += qc * math.sin(angleZ)
					cosZ += qc * math.cos(angleZ)
					weightedY += qc * (y + 0.5) * grid.Dy
				end
			end
		end
	end
	local centerX, definedX = periodicCenter(sinX, cosX, qcSum, grid.SizeX * grid.Dx)
	local centerZ, definedZ = periodicCenter(sinZ, cosZ, qcSum, grid.SizeZ * grid.Dz)
	local minU, maxU = extremes(self.Faces.U)
	local minV, maxV = extremes(self.Faces.V)
	local minW, maxW = extremes(self.Faces.W)
	local p = self.Projection.Last
	local total = qvSum + qcSum + qrSum
	return {
		Time = self.Time,
		CloudCells = cloudCells,
		MaxCloudWater = maxCloudWater,
		MaxVerticalVelocity = math.max(math.abs(minW), math.abs(maxW)),
		TotalWater = total,
		QvSum = qvSum,
		QcSum = qcSum,
		QrSum = qrSum,
		WaterSum = total,
		WaterDriftFraction = if self.InitialWaterSum > 0
			then (total - self.InitialWaterSum) / self.InitialWaterSum
			else 0,
		MinU = minU,
		MaxU = maxU,
		MinV = minV,
		MaxV = maxV,
		MinW = minW,
		MaxW = maxW,
		DivergenceBeforeRms = p.BeforeRms,
		DivergenceAfterRms = p.AfterRms,
		DivergenceBeforeMax = p.BeforeMax,
		DivergenceAfterMax = p.AfterMax,
		ProjectionIterations = p.Iterations,
		ProjectionResidual = p.Residual,
		ProjectionTolerance = p.TargetTolerance,
		ProjectionQuantizationFloor = p.QuantizationFloor,
		MaxCourant = math.max(self.MomentumCourant, self.TransportCourant),
		MomentumCourant = self.MomentumCourant,
		TransportCourant = self.TransportCourant,
		StepMilliseconds = self.StepMilliseconds,
		CloudCentroidDefined = definedX and definedZ,
		CloudCentroidX = centerX,
		CloudCentroidY = if qcSum > 0 then weightedY / qcSum else 0,
		CloudCentroidZ = centerZ,
	}
end

return Simulation
