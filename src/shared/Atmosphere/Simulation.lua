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
local Constants = require(script.Parent.Core.Constants)
local Thermodynamics = require(script.Parent.Thermodynamics.Thermodynamics)
local Saturation = require(script.Parent.Thermodynamics.Saturation)

local Simulation = {}
Simulation.__index = Simulation
Simulation.FixedDt = 0.25 -- physical seconds, independent of Heartbeat dt.
Simulation.CellHeightMeters = 100 -- legacy default; each grid owns its actual Dy.

export type Config = {
	DisableBubble: boolean?,
	BackgroundU: number?,
	BackgroundV: number?,
	ShearU: number?,
	ShearV: number?,
	BubbleRelativeHumidity: number?,
	BubbleTemperaturePerturbation: number?,
	BubbleShape: string?,
	BubbleScale: number?,
	MomentumOptions: Momentum.Options?,
	ProjectionOptions: Projection.Options?,
	TransportOptions: Transport.Options?,
}

-- Cached absolute targets, not increments or visible cloud geometry. WaterTarget
-- bounds TOTAL qv+qc+qr (kg/kg). Finite domain budgets prevent sealed-box buildup.
export type SourceForcing = {
	ThetaTarget: buffer,
	WaterTarget: buffer,
	Weights: buffer?, -- optional smooth local support [0,1]; absent means all cells.
	Fraction: number, -- 0..1 relaxation fraction for this application.
	MaxWaterSum: number, -- available unweighted mixing-ratio sum, not kg.
	MaxThetaSum: number, -- available summed potential-temperature increment, K.
}

export type SourceInput = { WaterSum: number, ThetaSum: number, EnthalpySum: number }

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
	RawWaterChangeFraction: number,
	ExternalWaterSum: number,
	ExternalThetaSum: number,
	ExternalEnthalpySum: number, -- summed J/kg dry air, NOT domain joules.
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
		ExternalWaterSum: number,
		ExternalThetaSum: number,
		ExternalEnthalpySum: number,
		LastSourceInput: SourceInput,
		Time: number,
		InitialWaterSum: number,
		MomentumCourant: number,
		TransportCourant: number,
		StepMilliseconds: number,
		BackgroundU: number,
		BackgroundV: number,
		ShearU: number,
		ShearV: number,
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
		DisableBubble = settings.DisableBubble,
		BackgroundU = settings.BackgroundU,
		BackgroundV = settings.BackgroundV,
		ShearU = settings.ShearU,
		ShearV = settings.ShearV,
		BubbleRelativeHumidity = settings.BubbleRelativeHumidity,
		BubbleTemperaturePerturbation = settings.BubbleTemperaturePerturbation,
		BubbleShape = settings.BubbleShape,
		BubbleScale = settings.BubbleScale,
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
		ExternalWaterSum = 0,
		ExternalThetaSum = 0,
		ExternalEnthalpySum = 0,
		LastSourceInput = { WaterSum = 0, ThetaSum = 0, EnthalpySum = 0 },
		Time = 0,
		InitialWaterSum = waterSum(state),
		MomentumCourant = 0,
		TransportCourant = 0,
		StepMilliseconds = 0,
		BackgroundU = settings.BackgroundU or 0,
		BackgroundV = settings.BackgroundV or 0,
		ShearU = settings.ShearU or 0,
		ShearV = settings.ShearV or 0,
	}, Simulation)
	Validation.CheckState(state)
	return self
end

local function validateForcing(self: Simulation, forcing: SourceForcing)
	local bytes = self.Geometry.Count * 4
	assert(
		typeof(forcing.ThetaTarget) == "buffer" and buffer.len(forcing.ThetaTarget) == bytes,
		"Source theta target must match the grid"
	)
	assert(
		typeof(forcing.WaterTarget) == "buffer" and buffer.len(forcing.WaterTarget) == bytes,
		"Source water target must match the grid"
	)
	assert(
		forcing.Weights == nil
			or (typeof(forcing.Weights) == "buffer" and buffer.len(forcing.Weights) == bytes),
		"Source weights must match the grid"
	)
	assert(
		Validation.IsFinite(forcing.Fraction) and forcing.Fraction >= 0 and forcing.Fraction <= 1,
		"Source fraction must be 0..1"
	)
	assert(
		Validation.IsFinite(forcing.MaxWaterSum) and forcing.MaxWaterSum >= 0,
		"Source water budget must be finite and nonnegative"
	)
	assert(
		Validation.IsFinite(forcing.MaxThetaSum) and forcing.MaxThetaSum >= 0,
		"Source thermal budget must be finite and nonnegative"
	)
end

-- Reuse phase-rounding scratch. Account represented float32 deltas; discard a
-- sub-ULP request that rounds beyond a remaining budget instead of overspending.
local function boundedAddition(
	old: number,
	requested: number,
	remaining: number,
	scratch: buffer
): number
	local allowance = math.min(requested, remaining)
	buffer.writef32(scratch, 0, old + allowance)
	local candidate = buffer.readf32(scratch, 0)
	assert(Validation.IsFinite(candidate), "Source float32 overflow")
	if candidate - old > allowance then
		-- A lower float32 neighbor preserves the proportional cell allowance.
		-- Positive fields have monotone float bits; old is already representable.
		buffer.writeu32(scratch, 0, buffer.readu32(scratch, 0) - 1)
		candidate = buffer.readf32(scratch, 0)
	end
	return if candidate >= old and candidate - old <= remaining then candidate else old
end

local function applyForcing(
	self: Simulation,
	state: AtmosphereState.AtmosphereState,
	forcing: SourceForcing
): (number, number, number)
	validateForcing(self, forcing)
	local fields = state.Fields
	local weights = forcing.Weights
	local waterRequested, thetaRequested = 0, 0
	-- Determine a global allowance before writing any cell. Budget exhaustion
	-- scales the entire source, instead of preferentially heating the first rows.
	for offset = 0, self.Geometry.Count * 4 - 4, 4 do
		local weight = if weights then buffer.readf32(weights, offset) else 1
		assert(
			Validation.IsFinite(weight) and weight >= 0 and weight <= 1,
			"Source weights must be in [0,1]"
		)
		local thetaTarget = buffer.readf32(forcing.ThetaTarget, offset)
		local waterTarget = buffer.readf32(forcing.WaterTarget, offset)
		assert(
			Validation.IsFinite(thetaTarget) and thetaTarget > 0,
			"Source theta target must be finite and positive"
		)
		assert(
			Validation.IsFinite(waterTarget) and waterTarget >= 0,
			"Source water target must be finite and nonnegative"
		)
		local theta = buffer.readf32(fields.theta, offset)
		local qv = buffer.readf32(fields.qv, offset)
		local totalWater = qv
			+ buffer.readf32(fields.qc, offset)
			+ buffer.readf32(fields.qr, offset)
		thetaRequested += math.max(0, thetaTarget - theta) * forcing.Fraction * weight
		waterRequested += math.max(0, waterTarget - totalWater) * forcing.Fraction * weight
	end
	assert(
		Validation.IsFinite(thetaRequested) and Validation.IsFinite(waterRequested),
		"Requested source input overflow"
	)
	local thetaScale = if thetaRequested > 0
		then math.min(1, forcing.MaxThetaSum / thetaRequested)
		else 1
	local waterScale = if waterRequested > 0
		then math.min(1, forcing.MaxWaterSum / waterRequested)
		else 1
	local waterSumAdded, thetaSumAdded, enthalpySumAdded = 0, 0, 0
	for offset = 0, self.Geometry.Count * 4 - 4, 4 do
		local weight = if weights then buffer.readf32(weights, offset) else 1
		local thetaTarget = buffer.readf32(forcing.ThetaTarget, offset)
		local waterTarget = buffer.readf32(forcing.WaterTarget, offset)
		local theta = buffer.readf32(fields.theta, offset)
		local qv = buffer.readf32(fields.qv, offset)
		local totalWater = qv
			+ buffer.readf32(fields.qc, offset)
			+ buffer.readf32(fields.qr, offset)
		local nextTheta = boundedAddition(
			theta,
			math.max(0, thetaTarget - theta) * forcing.Fraction * weight * thetaScale,
			forcing.MaxThetaSum - thetaSumAdded,
			self.PhaseRounding
		)
		local nextQv = boundedAddition(
			qv,
			math.max(0, waterTarget - totalWater) * forcing.Fraction * weight * waterScale,
			forcing.MaxWaterSum - waterSumAdded,
			self.PhaseRounding
		)
		local dTheta, dWater = nextTheta - theta, nextQv - qv
		-- Validate every target, including currently inactive cells, before commit.
		-- This catches unsupported thermal inputs without arbitrary temperature caps.
		local pressure = buffer.readf32(fields.pressure, offset)
		local exner = Thermodynamics.Exner(pressure)
		Saturation.MixingRatio(thetaTarget * exner, pressure)
		Saturation.MixingRatio(nextTheta * exner, pressure)
		waterSumAdded += dWater
		thetaSumAdded += dTheta
		enthalpySumAdded += Constants.SpecificHeatDryAir * exner * dTheta + Constants.LatentHeatVaporization * dWater
		buffer.writef32(fields.theta, offset, nextTheta)
		buffer.writef32(fields.qv, offset, nextQv)
	end
	assert(Validation.IsFinite(enthalpySumAdded), "Source enthalpy input overflow")
	assert(
		Validation.IsFinite(self.ExternalWaterSum + waterSumAdded)
			and Validation.IsFinite(self.ExternalThetaSum + thetaSumAdded)
			and Validation.IsFinite(self.ExternalEnthalpySum + enthalpySumAdded),
		"Cumulative source input overflow"
	)
	return waterSumAdded, thetaSumAdded, enthalpySumAdded
end

local function commitSourceInput(self: Simulation, water: number, theta: number, enthalpy: number)
	self.ExternalWaterSum += water
	self.ExternalThetaSum += theta
	self.ExternalEnthalpySum += enthalpy
	self.LastSourceInput.WaterSum = water
	self.LastSourceInput.ThetaSum = theta
	self.LastSourceInput.EnthalpySum = enthalpy
end

-- Explicit initial-state checkpoint; ongoing source events must never call this.
function Simulation:ResetWaterBaseline()
	assert(self.Time == 0, "Water baseline can only be set during initialization")
	self.InitialWaterSum = waterSum(self.State)
	self.ExternalWaterSum, self.ExternalThetaSum, self.ExternalEnthalpySum = 0, 0, 0
	self.LastSourceInput.WaterSum, self.LastSourceInput.ThetaSum, self.LastSourceInput.EnthalpySum =
		0, 0, 0
end

-- Atomic source operation for initial conditions/developer use. Existing cloud
-- water, rain, momentum, profile, pressure and simulation time remain untouched.
function Simulation:InjectSource(forcing: SourceForcing): SourceInput
	Validation.CheckState(self.State)
	local oldFields, pendingFields = self.State.Fields, self.PendingState.Fields
	for _, name in SCALARS do
		buffer.copy(pendingFields[name], 0, oldFields[name])
	end
	pendingFields.pressure = oldFields.pressure
	local water, theta, enthalpy = applyForcing(self, self.PendingState, forcing)
	oldFields.theta, pendingFields.theta = pendingFields.theta, oldFields.theta
	oldFields.qv, pendingFields.qv = pendingFields.qv, oldFields.qv
	commitSourceInput(self, water, theta, enthalpy)
	return self.LastSourceInput
end

-- Interactive background-wind change, m/s (u=X, v=Z). Shift the MAC faces
-- AND drag targets, preserving the existing perturbation flow and vertical shear.
-- Reuse pending storage and validate before committing; moisture is untouched.
function Simulation:SetWind(u: number, v: number)
	assert(Validation.IsFinite(u) and math.abs(u) <= 30, "Wind U must be within -30..30 m/s")
	assert(Validation.IsFinite(v) and math.abs(v) <= 30, "Wind V must be within -30..30 m/s")
	self.Faces:CheckFinite()
	local maxU, maxV, maxW = 0, 0, 0
	local grid = self.State.Grid
	for y = 0, grid.SizeY - 1 do
		local height = (y + 0.5) * grid.Dy
		local targetU, targetV = u + self.ShearU * height, v + self.ShearV * height
		assert(
			Validation.IsFinite(targetU) and Validation.IsFinite(targetV),
			"Wind target overflow"
		)
		local deltaU = targetU - buffer.readf32(self.Profile.U, y * 4)
		local deltaV = targetV - buffer.readf32(self.Profile.V, y * 4)
		for index = y * self.Geometry.Plane, (y + 1) * self.Geometry.Plane - 1 do
			local offset = index * 4
			buffer.writef32(
				self.PendingFaces.U,
				offset,
				buffer.readf32(self.Faces.U, offset) + deltaU
			)
			buffer.writef32(
				self.PendingFaces.V,
				offset,
				buffer.readf32(self.Faces.V, offset) + deltaV
			)
			local nextU = buffer.readf32(self.PendingFaces.U, offset)
			local nextV = buffer.readf32(self.PendingFaces.V, offset)
			assert(Validation.IsFinite(nextU) and Validation.IsFinite(nextV), "Wind face overflow")
			maxU, maxV = math.max(maxU, math.abs(nextU)), math.max(maxV, math.abs(nextV))
		end
	end
	for offset = 0, buffer.len(self.Faces.W) - 4, 4 do
		maxW = math.max(maxW, math.abs(buffer.readf32(self.Faces.W, offset)))
	end
	assert(
		Simulation.FixedDt
				* (maxU / grid.Dx + maxV / grid.Dz + maxW / grid.Dy + self.Momentum.DiffusionRate)
			<= 0.8,
		"Wind command would exceed the momentum CFL/diffusion limit"
	)
	for y = 0, grid.SizeY - 1 do
		local height = (y + 0.5) * grid.Dy
		buffer.writef32(self.Profile.U, y * 4, u + self.ShearU * height)
		buffer.writef32(self.Profile.V, y * 4, v + self.ShearV * height)
	end
	self.Faces.U, self.PendingFaces.U = self.PendingFaces.U, self.Faces.U
	self.Faces.V, self.PendingFaces.V = self.PendingFaces.V, self.Faces.V
	self.BackgroundU, self.BackgroundV = u, v
	self.Faces:WriteCellCenters(self.State)
end

-- Run against owned staging storage. The protected call uses this static function
-- rather than allocating a new closure per step.
local function advancePending(
	self: Simulation,
	dt: number,
	forcing: SourceForcing?
): (number, number, number, number, number)
	local state, faces = self.PendingState, self.PendingFaces
	local water, thetaInput, enthalpy = 0, 0, 0
	if forcing then
		water, thetaInput, enthalpy = applyForcing(self, state, forcing)
	end
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
	return momentumCourant, transportCourant, water, thetaInput, enthalpy
end

-- First-order operator split: old-state momentum -> MAC projection -> bounded
-- conservative scalar transport -> saturation/latent heating. SSPRK2 improves
-- scalar transport alone; it does not make the whole coupled model second-order.
-- Commit every evolving field together only after all stages validate. Failures
-- preserve public buffers, time, diagnostics, and the pressure solver warm start.
function Simulation:Step(dt: number, forcing: SourceForcing?)
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
	local success, momentumCourant, transportCourant, water, thetaInput, enthalpy =
		pcall(advancePending, self, dt, forcing)
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
	commitSourceInput(self, water, thetaInput, enthalpy)
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
			then (total - self.InitialWaterSum - self.ExternalWaterSum) / self.InitialWaterSum
			else 0,
		RawWaterChangeFraction = if self.InitialWaterSum > 0
			then (total - self.InitialWaterSum) / self.InitialWaterSum
			else 0,
		ExternalWaterSum = self.ExternalWaterSum,
		ExternalThetaSum = self.ExternalThetaSum,
		ExternalEnthalpySum = self.ExternalEnthalpySum,
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
