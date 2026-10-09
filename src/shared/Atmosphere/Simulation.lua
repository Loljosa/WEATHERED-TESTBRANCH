--!native
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
	BubbleRelativeHumidity: number?,
	MomentumOptions: Momentum.Options?,
	ProjectionOptions: Projection.Options?,
	TransportOptions: Transport.Options?,
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
	ProjectionResidualMax: number,
	ProjectionTolerance: number,
	ProjectionQuantizationFloor: number,
	ProjectionF64RoundingFloor: number,
	ProjectionPostTolerance: number,
	ProjectionConverged: boolean,
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
		PendingState: AtmosphereState.AtmosphereState,
		PendingFaces: FaceVelocity.FaceVelocity,
		ProjectionBackup: buffer,
		ProjectionDiagnosticsBackup: Projection.Diagnostics,
		PhaseRounding: buffer,
		Time: number,
		InitialWaterSum: number,
		MomentumCourant: number,
		TransportCourant: number,
		StepMilliseconds: number,
	},
	Simulation
))

local SCALARS = { "theta", "qv", "qc", "qr" }
local DYNAMIC_FIELDS = { "u", "v", "w", "theta", "qv", "qc", "qr" }

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
		BubbleRelativeHumidity = settings.BubbleRelativeHumidity,
	})
	local geometry = Geometry.new(grid)
	local faces = FaceVelocity.new(geometry)
	faces:Initialize(state)
	faces:WriteCellCenters(state)
	local projection = Projection.new(geometry, settings.ProjectionOptions)
	local pendingState = AtmosphereState.new(grid)
	-- Thermodynamic pressure is fixed in space, not transported or projected.
	-- Share its read-only buffer; all seven evolving fields have separate storage.
	pendingState.Fields.pressure = state.Fields.pressure
	local self = setmetatable({
		State = state,
		Profile = profile,
		Geometry = geometry,
		Faces = faces,
		Momentum = Momentum.new(geometry, settings.MomentumOptions),
		Projection = projection,
		Transport = Transport.new(geometry, settings.TransportOptions),
		PendingState = pendingState,
		PendingFaces = FaceVelocity.new(geometry),
		ProjectionBackup = buffer.create(geometry.Count * 8),
		ProjectionDiagnosticsBackup = table.clone(projection.Last),
		PhaseRounding = buffer.create(12),
		Time = 0,
		InitialWaterSum = waterSum(state),
		MomentumCourant = 0,
		TransportCourant = 0,
		StepMilliseconds = 0,
	}, Simulation)
	Validation.CheckState(state)
	return self
end

-- Run against owned staging storage. The protected call uses this static function
-- rather than allocating a new closure per step.
local function advancePending(self: Simulation, dt: number): (number, number)
	local state, faces = self.PendingState, self.PendingFaces
	local momentumCourant = self.Momentum:Predict(state, self.Profile, faces, dt)
	self.Projection:Project(faces, dt)
	local transportCourant = self.Transport:Advance(state, faces, dt)
	local fields = state.Fields
	for offset = 0, self.Geometry.Count * 4 - 4, 4 do
		local theta, qv, qc = WarmCloud.AdjustFloat32(
			buffer.readf32(fields.theta, offset),
			buffer.readf32(fields.qv, offset),
			buffer.readf32(fields.qc, offset),
			buffer.readf32(fields.pressure, offset),
			self.PhaseRounding
		)
		buffer.writef32(fields.theta, offset, theta)
		buffer.writef32(fields.qv, offset, qv)
		buffer.writef32(fields.qc, offset, qc)
	end
	faces:WriteCellCenters(state)
	Validation.CheckState(state)
	return momentumCourant, transportCourant
end

-- First-order operator split: old-state momentum -> MAC projection -> bounded
-- conservative scalar transport -> saturation/latent heating. SSPRK2 improves
-- scalar transport alone; it does not make the whole coupled model second-order.
-- Commit every evolving field together only after all stages validate. Failures
-- preserve public buffers, time, diagnostics, and the pressure solver warm start.
function Simulation:Step(dt: number)
	assert(
		Validation.IsFinite(dt) and dt > 0 and dt <= Simulation.FixedDt,
		"Step dt must be positive and at most FixedDt"
	)
	local startTime = os.clock()
	Validation.CheckState(self.State)
	self.Faces:CheckFinite()
	local oldFields, pendingFields = self.State.Fields, self.PendingState.Fields
	for _, name in SCALARS do
		buffer.copy(pendingFields[name], 0, oldFields[name])
	end
	pendingFields.pressure = oldFields.pressure
	buffer.copy(self.PendingFaces.U, 0, self.Faces.U)
	buffer.copy(self.PendingFaces.V, 0, self.Faces.V)
	buffer.copy(self.PendingFaces.W, 0, self.Faces.W)
	buffer.copy(self.ProjectionBackup, 0, self.Projection.Correction)
	for name, value in self.Projection.Last do
		(self.ProjectionDiagnosticsBackup :: any)[name] = value
	end
	local success, momentumCourant, transportCourant = pcall(advancePending, self, dt)
	if not success then
		buffer.copy(self.Projection.Correction, 0, self.ProjectionBackup)
		for name, value in self.ProjectionDiagnosticsBackup do
			(self.Projection.Last :: any)[name] = value
		end
		error(momentumCourant, 0)
	end
	for _, name in DYNAMIC_FIELDS do
		oldFields[name], pendingFields[name] = pendingFields[name], oldFields[name]
	end
	self.Faces.U, self.PendingFaces.U = self.PendingFaces.U, self.Faces.U
	self.Faces.V, self.PendingFaces.V = self.PendingFaces.V, self.Faces.V
	self.Faces.W, self.PendingFaces.W = self.PendingFaces.W, self.Faces.W
	self.MomentumCourant = momentumCourant
	self.TransportCourant = transportCourant
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
		ProjectionResidualMax = p.ResidualMax,
		ProjectionTolerance = p.TargetTolerance,
		ProjectionQuantizationFloor = p.QuantizationFloor,
		ProjectionF64RoundingFloor = p.F64RoundingFloor,
		ProjectionPostTolerance = p.PostTolerance,
		ProjectionConverged = p.Converged,
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
