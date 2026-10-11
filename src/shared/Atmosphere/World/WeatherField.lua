--!native
--!strict

local Advection = require(script.Parent.FieldAdvection)
local uOffset = Advection.UOffset
local vOffset = Advection.VOffset
local wOffset = Advection.WOffset
local Constants = require(script.Parent.Parent.Core.Constants)
local Saturation = require(script.Parent.Parent.Thermodynamics.Saturation)
local Thermodynamics = require(script.Parent.Parent.Thermodynamics.Thermodynamics)
local WarmCloud = require(script.Parent.Parent.Microphysics.WarmCloud)

local Field = {}
Field.__index = Field
Field.FixedDt = 0.25
local SCALARS = { "theta", "qv", "qc", "qr" }
local FIELD_NAMES = { "theta", "qv", "qc", "qr", "pressure", "u", "v", "w" }

export type Options = {
	SizeX: number?,
	SizeY: number?,
	SizeZ: number?,
	BackgroundU: number?,
	BackgroundV: number?,
	ShearU: number?,
	ShearV: number?,
	BackgroundRelativeHumidity: number?,
	StreamfunctionAmplitude: number?,
	Boundary: string?,
	Microphysics: boolean?,
	CourantLimit: number?,
	MaxSubsteps: number?,
}
export type SourceForcing = {
	ThetaTarget: buffer,
	WaterTarget: buffer,
	Weights: buffer?,
	Fraction: number,
	MaxWaterSum: number,
	MaxThetaSum: number,
}
export type SourceInput = { WaterSum: number, ThetaSum: number, EnthalpySum: number }
export type WeatherField = typeof(setmetatable(
	{} :: {
		Coordinates: any,
		Grid: any,
		Dims: any,
		SizeX: number,
		SizeY: number,
		SizeZ: number,
		Count: number,
		Dx: number,
		Dy: number,
		Dz: number,
		ValueBytes: number,
		State: any,
		Fields: { [string]: buffer },
		Profile: any,
		PressureLayers: buffer,
		PendingScalar: { [string]: buffer },
		ScratchScalar: { [string]: buffer },
		Faces: Advection.Faces,
		FacesU: buffer,
		FacesV: buffer,
		FacesW: buffer,
		Advection: Advection.Advection,
		Streamfunction: buffer,
		BackgroundU: number,
		BackgroundV: number,
		ShearU: number,
		ShearV: number,
		StreamfunctionAmplitude: number,
		Boundary: string,
		Microphysics: boolean,
		Time: number,
		Tick: number,
		InitialWaterSum: number,
		ExternalWaterSum: number,
		ExternalThetaSum: number,
		ExternalEnthalpySum: number,
		LastSourceInput: SourceInput,
		MaxCourant: number,
		Substeps: number,
		DivergenceRms: number,
		DivergenceMax: number,
		StepMilliseconds: number,
		RegionQcFlux: buffer,
		RegionWaterNet: buffer,
		LastRegionQcFlux: buffer,
		LastRegionWaterNet: buffer,
		InternalRegionQcTransfer: number,
		OuterPeriodicQcTransfer: number,
	},
	Field
))

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function dimension(value: number, horizontal: boolean): number
	assert(
		value % 1 == 0
			and value >= (if horizontal then 4 else 3)
			and value <= (if horizontal then 64 else 12),
		"Invalid coarse weather grid dimension"
	)
	assert(
		not horizontal or value % 4 == 0,
		"Horizontal coarse dimensions must align with four regions"
	)
	return value
end

local function cellOffset(self: WeatherField, x: number, y: number, z: number): number
	return ((y * self.SizeZ + z) * self.SizeX + x) * 8
end

local function waterSum(self: WeatherField): number
	local total = 0
	for offset = 0, self.Count * 8 - 8, 8 do
		total += buffer.readf64(self.Fields.qv, offset) + buffer.readf64(self.Fields.qc, offset) + buffer.readf64(
			self.Fields.qr,
			offset
		)
	end
	return total
end

local function scalarStorage(count: number): { [string]: buffer }
	local result: { [string]: buffer } = {}
	for _, name in SCALARS do
		result[name] = buffer.create(count * 8)
	end
	return result
end

local function profileAt(height: number): (number, number)
	local theta = 300 + 0.003 * height
	local exner = 1
		- Constants.Gravity / (Constants.SpecificHeatDryAir * 0.003) * math.log(theta / 300)
	assert(exner > 0, "Coarse world altitude exceeds the hydrostatic sounding range")
	local pressure = Constants.ReferencePressure
		* exner ^ (Constants.SpecificHeatDryAir / Constants.DryAirGasConstant)
	return theta, pressure
end

function Field.new(coordinates: any, options: Options?): WeatherField
	local settings = options or {}
	local nx, ny, nz =
		dimension(settings.SizeX or 32, true),
		dimension(settings.SizeY or 6, false),
		dimension(settings.SizeZ or 32, true)
	assert(
		coordinates.WidthStuds == 4028 and coordinates.DepthStuds == 4028,
		"Weather field must cover exactly 4028 by 4028 studs"
	)
	assert(
		finite(coordinates.WidthMeters)
			and coordinates.WidthMeters > 0
			and finite(coordinates.HeightMeters)
			and coordinates.HeightMeters > 0,
		"World physical extents must be finite and positive"
	)
	local count = nx * ny * nz
	local fields = scalarStorage(count)
	for _, name in { "pressure", "u", "v", "w" } do
		fields[name] = buffer.create(count * 8)
	end
	local grid: any = {
		SizeX = nx,
		SizeY = ny,
		SizeZ = nz,
		Count = count,
		Dx = coordinates.WidthMeters / nx,
		Dy = coordinates.HeightMeters / ny,
		Dz = coordinates.DepthMeters / nz,
	}
	function grid:Index(x: number, y: number, z: number): number
		assert(
			x % 1 == 0
				and y % 1 == 0
				and z % 1 == 0
				and x >= 1
				and x <= nx
				and y >= 1
				and y <= ny
				and z >= 1
				and z <= nz,
			"Weather grid coordinate outside domain"
		)
		return ((y - 1) * nz + z - 1) * nx + x
	end
	function grid:Coordinates(index: number): (number, number, number)
		assert(
			index % 1 == 0 and index >= 1 and index <= count,
			"Weather field index outside domain"
		)
		local zero = index - 1
		return zero % nx + 1, math.floor(zero / (nx * nz)) + 1, math.floor(zero / nx) % nz + 1
	end
	function grid:GridToPhysical(x: number, y: number, z: number): (number, number, number)
		self:Index(x, y, z)
		return coordinates.MinXMeters + (x - 0.5) * self.Dx,
			coordinates.BaseAltitudeMeters + (y - 0.5) * self.Dy,
			coordinates.MinZMeters + (z - 0.5) * self.Dz
	end
	local state: any = { Grid = grid, Fields = fields }
	function state:Get(name: string, index: number): number
		assert(
			self.Fields[name] ~= nil and index % 1 == 0 and index >= 1 and index <= count,
			"Invalid coarse field lookup"
		)
		return buffer.readf64(self.Fields[name], (index - 1) * 8)
	end
	function state:Set(name: string, index: number, value: number)
		assert(finite(value), "Coarse field assignment must be finite")
		self:Get(name, index)
		buffer.writef64(self.Fields[name], (index - 1) * 8, value)
	end
	function state:Fill(name: string, value: number)
		assert(self.Fields[name] ~= nil and finite(value), "Invalid coarse field fill")
		for offset = 0, count * 8 - 8, 8 do
			buffer.writef64(self.Fields[name], offset, value)
		end
	end
	local u = buffer.create((nx + 1) * ny * nz * 8)
	local v = buffer.create(nx * ny * (nz + 1) * 8)
	local w = buffer.create(nx * (ny + 1) * nz * 8)
	local self = setmetatable({
		Coordinates = coordinates,
		Grid = grid,
		Dims = grid,
		SizeX = nx,
		SizeY = ny,
		SizeZ = nz,
		Count = count,
		Dx = grid.Dx,
		Dy = grid.Dy,
		Dz = grid.Dz,
		ValueBytes = 8,
		State = state,
		Fields = fields,
		Profile = {
			Theta = buffer.create(ny * 8),
			Qv = buffer.create(ny * 8),
			U = buffer.create(ny * 8),
			V = buffer.create(ny * 8),
			CellHeightMeters = grid.Dy,
		},
		PressureLayers = buffer.create(ny * 8),
		PendingScalar = scalarStorage(count),
		ScratchScalar = scalarStorage(count),
		Faces = { U = u, V = v, W = w },
		FacesU = u,
		FacesV = v,
		FacesW = w,
		Advection = Advection.new(
			grid,
			settings.Boundary,
			settings.CourantLimit,
			settings.MaxSubsteps
		),
		Streamfunction = buffer.create((nx + 1) * (ny + 1) * nz * 8),
		BackgroundU = settings.BackgroundU or 8,
		BackgroundV = settings.BackgroundV or 2,
		ShearU = settings.ShearU or 0.002,
		ShearV = settings.ShearV or -0.001,
		StreamfunctionAmplitude = settings.StreamfunctionAmplitude or 200,
		Boundary = settings.Boundary or "Periodic",
		Microphysics = settings.Microphysics ~= false,
		Time = 0,
		Tick = 0,
		InitialWaterSum = 0,
		ExternalWaterSum = 0,
		ExternalThetaSum = 0,
		ExternalEnthalpySum = 0,
		LastSourceInput = { WaterSum = 0, ThetaSum = 0, EnthalpySum = 0 },
		MaxCourant = 0,
		Substeps = 0,
		DivergenceRms = 0,
		DivergenceMax = 0,
		StepMilliseconds = 0,
		RegionQcFlux = buffer.create(16 * 8),
		RegionWaterNet = buffer.create(16 * 8),
		LastRegionQcFlux = buffer.create(16 * 8),
		LastRegionWaterNet = buffer.create(16 * 8),
		InternalRegionQcTransfer = 0,
		OuterPeriodicQcTransfer = 0,
	}, Field)
	local humidity = settings.BackgroundRelativeHumidity or 0.72
	assert(
		finite(humidity) and humidity > 0 and humidity <= 1,
		"World background relative humidity must be in (0,1]"
	)
	assert(finite(self.ShearU) and finite(self.ShearV), "World shear must be finite")
	assert(
		finite(self.StreamfunctionAmplitude)
			and self.StreamfunctionAmplitude >= 0
			and self.StreamfunctionAmplitude <= 500,
		"Streamfunction amplitude must be 0..500 m^2/s"
	)
	for y = 0, ny - 1 do
		local theta, pressure = profileAt(coordinates.BaseAltitudeMeters + (y + 0.5) * grid.Dy)
		local qv = humidity
			* Saturation.MixingRatio(Thermodynamics.Temperature(theta, pressure), pressure)
		buffer.writef64(self.Profile.Theta, y * 8, theta)
		buffer.writef64(self.Profile.Qv, y * 8, qv)
		buffer.writef64(self.PressureLayers, y * 8, pressure)
		for z = 0, nz - 1 do
			for x = 0, nx - 1 do
				local offset = cellOffset(self, x, y, z)
				buffer.writef64(fields.theta, offset, theta)
				buffer.writef64(fields.qv, offset, qv)
				buffer.writef64(fields.pressure, offset, pressure)
			end
		end
	end
	self:SetWind(self.BackgroundU, self.BackgroundV)
	self.InitialWaterSum = waterSum(self)
	return self
end

-- A prescribed large-scale kinematic circulation, NOT a coarse pressure solve.
-- Taking shared differences of a corner streamfunction gives exactly compatible
-- U/W faces. Local MAC detail supplies dynamic buoyancy where activated.
function Field:SetWind(u: number, v: number)
	assert(
		finite(u) and finite(v) and math.abs(u) <= 100 and math.abs(v) <= 100,
		"World wind components must be finite and within +/-100 m/s"
	)
	assert(
		self.Boundary ~= "Sealed" or (u == 0 and v == 0 and self.ShearU == 0 and self.ShearV == 0),
		"Sealed lateral walls require zero background wind and shear; use Periodic for live wind"
	)
	local nx, ny, nz = self.SizeX, self.SizeY, self.SizeZ
	local function psiOffset(x: number, y: number, z: number): number
		return ((y * nz + z) * (nx + 1) + x) * 8
	end
	for y = 0, ny do
		local sy = if y == 0 or y == ny then 0 else math.sin(math.pi * y / ny) ^ 2
		for z = 0, nz - 1 do
			local zFactor = 1 + 0.2 * math.cos(2 * math.pi * (z + 0.5) / nz)
			for x = 0, nx do
				local sx = if x == 0 or x == nx
					then 0
					else math.sin(
						(if self.Boundary == "Periodic" then 2 else 1) * math.pi * x / nx
					)
				buffer.writef64(
					self.Streamfunction,
					psiOffset(x, y, z),
					self.StreamfunctionAmplitude * sx * sy * zFactor
				)
			end
		end
	end
	-- Validate the proposed faces before changing authoritative velocities. The
	-- corner streamfunction is reusable derived scratch; live wind rejection
	-- must preserve faces, cell velocities, profile targets and background wind.
	local proposedCourant, proposedDivergence = 0, 0
	for y = 0, ny - 1 do
		local layerU = u + self.ShearU * (y + 0.5) * self.Dy
		local layerV = if self.Boundary == "Sealed"
			then 0
			else v + self.ShearV * (y + 0.5) * self.Dy
		for z = 0, nz - 1 do
			for x = 0, nx - 1 do
				local southwest = buffer.readf64(self.Streamfunction, psiOffset(x, y, z))
				local northwest = buffer.readf64(self.Streamfunction, psiOffset(x, y + 1, z))
				local southeast = buffer.readf64(self.Streamfunction, psiOffset(x + 1, y, z))
				local northeast = buffer.readf64(self.Streamfunction, psiOffset(x + 1, y + 1, z))
				local west = layerU - (northwest - southwest) / self.Dy
				local east = layerU - (northeast - southeast) / self.Dy
				local bottom = (southeast - southwest) / self.Dx
				local top = (northeast - northwest) / self.Dx
				local courant = Field.FixedDt
					* (
						(math.max(east, 0) + math.max(-west, 0)) / self.Dx
						+ math.abs(layerV) / self.Dz
						+ (math.max(top, 0) + math.max(-bottom, 0)) / self.Dy
					)
				local divergence = (east - west) / self.Dx + (top - bottom) / self.Dy
				assert(
					finite(courant) and finite(divergence),
					"Nonfinite proposed world face velocity"
				)
				proposedCourant = math.max(proposedCourant, courant)
				proposedDivergence = math.max(proposedDivergence, math.abs(divergence))
			end
		end
	end
	assert(
		proposedDivergence <= 1e-10,
		"World face velocities are not divergence free; mixing-ratio transport would be inconsistent"
	)
	assert(
		math.max(1, math.ceil(proposedCourant / self.Advection.CourantLimit))
			<= self.Advection.MaxSubsteps,
		"World transport CFL requires more than the configured maximum substeps"
	)
	for y = 0, ny - 1 do
		local layerU = u + self.ShearU * (y + 0.5) * self.Dy
		local layerV = v + self.ShearV * (y + 0.5) * self.Dy
		buffer.writef64(self.Profile.U, y * 8, layerU)
		buffer.writef64(self.Profile.V, y * 8, layerV)
		for z = 0, nz - 1 do
			for x = 0, nx do
				local correction = -(
						buffer.readf64(self.Streamfunction, psiOffset(x, y + 1, z))
						- buffer.readf64(self.Streamfunction, psiOffset(x, y, z))
					) / self.Dy
				buffer.writef64(self.FacesU, uOffset(self.State.Grid, x, y, z), layerU + correction)
			end
		end
		for z = 0, nz do
			for x = 0, nx - 1 do
				buffer.writef64(
					self.FacesV,
					vOffset(self.State.Grid, x, y, z),
					if self.Boundary == "Sealed" then 0 else layerV
				)
			end
		end
	end
	for y = 0, ny do
		for z = 0, nz - 1 do
			for x = 0, nx - 1 do
				local velocity = (
					buffer.readf64(self.Streamfunction, psiOffset(x + 1, y, z))
					- buffer.readf64(self.Streamfunction, psiOffset(x, y, z))
				) / self.Dx
				buffer.writef64(self.FacesW, wOffset(self.State.Grid, x, y, z), velocity)
			end
		end
	end
	self.Advection:Substeps(self.Faces, Field.FixedDt)
	for y = 0, ny - 1 do
		for z = 0, nz - 1 do
			for x = 0, nx - 1 do
				local offset = cellOffset(self, x, y, z)
				buffer.writef64(
					self.Fields.u,
					offset,
					0.5
						* (
							buffer.readf64(self.FacesU, uOffset(self.State.Grid, x, y, z))
							+ buffer.readf64(self.FacesU, uOffset(self.State.Grid, x + 1, y, z))
						)
				)
				buffer.writef64(
					self.Fields.v,
					offset,
					0.5
						* (
							buffer.readf64(self.FacesV, vOffset(self.State.Grid, x, y, z))
							+ buffer.readf64(self.FacesV, vOffset(self.State.Grid, x, y, z + 1))
						)
				)
				buffer.writef64(
					self.Fields.w,
					offset,
					0.5
						* (
							buffer.readf64(self.FacesW, wOffset(self.State.Grid, x, y, z))
							+ buffer.readf64(self.FacesW, wOffset(self.State.Grid, x, y + 1, z))
						)
				)
			end
		end
	end
	self.BackgroundU, self.BackgroundV = u, v
end

local function applyForcing(
	self: WeatherField,
	fields: { [string]: buffer },
	forcing: SourceForcing?
): (number, number, number)
	if forcing == nil then
		return 0, 0, 0
	end
	assert(
		buffer.len(forcing.ThetaTarget) == self.Count * 8
			and buffer.len(forcing.WaterTarget) == self.Count * 8,
		"World forcing targets must be float64 buffers matching cell count"
	)
	assert(
		forcing.Weights == nil or buffer.len(forcing.Weights) == self.Count * 8,
		"World forcing weights must be float64"
	)
	assert(
		finite(forcing.Fraction) and forcing.Fraction >= 0 and forcing.Fraction <= 1,
		"World source fraction must be 0..1"
	)
	assert(
		finite(forcing.MaxWaterSum)
			and forcing.MaxWaterSum >= 0
			and finite(forcing.MaxThetaSum)
			and forcing.MaxThetaSum >= 0,
		"World source budgets must be finite and nonnegative"
	)
	local requestedWater, requestedTheta = 0, 0
	for offset = 0, self.Count * 8 - 8, 8 do
		local targetTheta, targetWater =
			buffer.readf64(forcing.ThetaTarget, offset), buffer.readf64(forcing.WaterTarget, offset)
		local weight = if forcing.Weights then buffer.readf64(forcing.Weights, offset) else 1
		assert(
			finite(targetTheta)
				and targetTheta > 0
				and finite(targetWater)
				and targetWater >= 0
				and finite(weight)
				and weight >= 0
				and weight <= 1,
			"Invalid world source target or support"
		)
		local totalWater = buffer.readf64(fields.qv, offset)
			+ buffer.readf64(fields.qc, offset)
			+ buffer.readf64(fields.qr, offset)
		requestedWater += forcing.Fraction * weight * math.max(0, targetWater - totalWater)
		requestedTheta += forcing.Fraction * weight * math.max(
			0,
			targetTheta - buffer.readf64(fields.theta, offset)
		)
	end
	local waterFactor = if requestedWater == 0
		then 0
		else math.min(1, forcing.MaxWaterSum / requestedWater)
	local thetaFactor = if requestedTheta == 0
		then 0
		else math.min(1, forcing.MaxThetaSum / requestedTheta)
	local actualWater, actualTheta, enthalpy = 0, 0, 0
	for y = 0, self.SizeY - 1 do
		local exner = Thermodynamics.Exner(buffer.readf64(self.PressureLayers, y * 8))
		for z = 0, self.SizeZ - 1 do
			for x = 0, self.SizeX - 1 do
				local offset = cellOffset(self, x, y, z)
				local oldTheta, oldWater =
					buffer.readf64(fields.theta, offset), buffer.readf64(fields.qv, offset)
				local weight = if forcing.Weights
					then buffer.readf64(forcing.Weights, offset)
					else 1
				local totalWater = oldWater
					+ buffer.readf64(fields.qc, offset)
					+ buffer.readf64(fields.qr, offset)
				local dTheta = thetaFactor
					* forcing.Fraction
					* weight
					* math.max(0, buffer.readf64(forcing.ThetaTarget, offset) - oldTheta)
				local dWater = waterFactor
					* forcing.Fraction
					* weight
					* math.max(0, buffer.readf64(forcing.WaterTarget, offset) - totalWater)
				local theta, vapor = oldTheta + dTheta, oldWater + dWater
				assert(
					finite(theta)
						and finite(vapor)
						and theta * exner >= Constants.SaturationMinimumTemperature
						and theta * exner <= Constants.SaturationMaximumTemperature,
					"World source exceeds thermodynamic validity"
				)
				buffer.writef64(fields.theta, offset, theta)
				buffer.writef64(fields.qv, offset, vapor)
				local representedTheta, representedWater = theta - oldTheta, vapor - oldWater
				actualTheta += representedTheta
				actualWater += representedWater
				enthalpy += Constants.SpecificHeatDryAir * exner * representedTheta + Constants.LatentHeatVaporization * representedWater
			end
		end
	end
	-- Floating double additions may exceed a prescribed aggregate budget by its
	-- rounding floor. Report/assert that floor, never conceal larger overspend.
	assert(
		actualWater <= forcing.MaxWaterSum + self.Count * 1e-16
			and actualTheta <= forcing.MaxThetaSum + self.Count * 1e-12,
		"World source budget exceeded represented floating-point tolerance"
	)
	return actualWater, actualTheta, enthalpy
end

local function stageState(self: WeatherField)
	for _, name in SCALARS do
		buffer.copy(self.PendingScalar[name], 0, self.Fields[name])
	end
end

local function commitScalars(
	self: WeatherField,
	final: { [string]: buffer },
	spare: { [string]: buffer }
)
	for _, name in SCALARS do
		local old = self.Fields[name]
		self.Fields[name] = final[name]
		final[name] = old
	end
	self.PendingScalar, self.ScratchScalar = spare, final
end

local function commitInput(self: WeatherField, water: number, theta: number, enthalpy: number)
	self.ExternalWaterSum += water
	self.ExternalThetaSum += theta
	self.ExternalEnthalpySum += enthalpy
	self.LastSourceInput.WaterSum, self.LastSourceInput.ThetaSum, self.LastSourceInput.EnthalpySum =
		water, theta, enthalpy
end

function Field:InjectSource(forcing: SourceForcing): SourceInput
	stageState(self)
	local water, theta, enthalpy = applyForcing(self, self.PendingScalar, forcing)
	commitScalars(self, self.PendingScalar, self.ScratchScalar)
	commitInput(self, water, theta, enthalpy)
	return self.LastSourceInput
end

function Field:ResetWaterBaseline()
	assert(
		self.Time == 0 and self.Tick == 0,
		"World baseline reset is only allowed during initialization"
	)
	self.InitialWaterSum = waterSum(self)
	self.ExternalWaterSum, self.ExternalThetaSum, self.ExternalEnthalpySum = 0, 0, 0
	self.LastSourceInput.WaterSum, self.LastSourceInput.ThetaSum, self.LastSourceInput.EnthalpySum =
		0, 0, 0
end

function Field:Step(dt: number, forcing: SourceForcing?)
	assert(dt == Field.FixedDt, "World atmosphere advances only fixed 0.25-second steps")
	local started = os.clock()
	local substeps, courant, divergenceMax, divergenceRms = self.Advection:Substeps(self.Faces, dt)
	stageState(self)
	local water, theta, enthalpy = applyForcing(self, self.PendingScalar, forcing)
	self.Advection:ResetRegionFlux()
	local input, output = self.PendingScalar, self.ScratchScalar
	for _ = 1, substeps do
		for _, name in SCALARS do
			self.Advection:Advect(input[name], output[name], self.Faces, dt / substeps, name)
		end
		if self.Microphysics then
			for y = 0, self.SizeY - 1 do
				local pressure = buffer.readf64(self.PressureLayers, y * 8)
				for z = 0, self.SizeZ - 1 do
					for x = 0, self.SizeX - 1 do
						local offset = cellOffset(self, x, y, z)
						local adjustedTheta, vapor, cloud = WarmCloud.Adjust(
							buffer.readf64(output.theta, offset),
							buffer.readf64(output.qv, offset),
							buffer.readf64(output.qc, offset),
							pressure
						)
						buffer.writef64(output.theta, offset, adjustedTheta)
						buffer.writef64(output.qv, offset, vapor)
						buffer.writef64(output.qc, offset, cloud)
					end
				end
			end
		end
		input, output = output, input
	end
	commitScalars(self, input, output)
	commitInput(self, water, theta, enthalpy)
	for offset = 0, 15 * 8, 8 do
		local qc, net =
			buffer.readf64(self.Advection.RegionQcFlux, offset),
			buffer.readf64(self.Advection.RegionWaterNet, offset)
		buffer.writef64(self.RegionQcFlux, offset, buffer.readf64(self.RegionQcFlux, offset) + qc)
		buffer.writef64(
			self.RegionWaterNet,
			offset,
			buffer.readf64(self.RegionWaterNet, offset) + net
		)
		buffer.writef64(self.LastRegionQcFlux, offset, qc)
		buffer.writef64(self.LastRegionWaterNet, offset, net)
	end
	self.Time += dt
	self.InternalRegionQcTransfer += self.Advection.InternalQcTransfer
	self.OuterPeriodicQcTransfer += self.Advection.OuterQcTransfer
	self.Tick += 1
	self.MaxCourant, self.Substeps, self.DivergenceMax, self.DivergenceRms =
		courant, substeps, divergenceMax, divergenceRms
	self.StepMilliseconds = (os.clock() - started) * 1000
end

function Field:SamplePhysical(x: number, y: number, z: number, name: string): number
	assert(
		self.Fields[name] ~= nil and finite(x) and finite(y) and finite(z),
		"Invalid world scalar sample"
	)
	local gx = (x - self.Coordinates.MinXMeters) / self.Dx - 0.5
	local gy = (y - self.Coordinates.BaseAltitudeMeters) / self.Dy - 0.5
	local gz = (z - self.Coordinates.MinZMeters) / self.Dz - 0.5
	if self.Boundary == "Sealed" then
		gx = math.clamp(gx, 0, self.SizeX - 1)
		gz = math.clamp(gz, 0, self.SizeZ - 1)
	end
	gy = math.clamp(gy, 0, self.SizeY - 1)
	local bx, by, bz = math.floor(gx), math.floor(gy), math.floor(gz)
	local fx, fy, fz = gx - bx, gy - by, gz - bz
	local result = 0
	for dy = 0, 1 do
		for dz = 0, 1 do
			for dx = 0, 1 do
				local ix, iy, iz =
					(bx + dx) % self.SizeX,
					math.min(by + dy, self.SizeY - 1),
					(bz + dz) % self.SizeZ
				local weight = (if dx == 0 then 1 - fx else fx)
					* (if dy == 0 then 1 - fy else fy)
					* (if dz == 0 then 1 - fz else fz)
				result += weight * buffer.readf64(self.Fields[name], cellOffset(self, ix, iy, iz))
			end
		end
	end
	return result
end

function Field:SampleWorld(x: number, y: number, z: number, name: string): number
	local px, py, pz = self.Coordinates:WorldToPhysical(x, y, z)
	return self:SamplePhysical(px, py, pz, name)
end

function Field:GetDiagnostics(): any
	local qv, qc, qr, cloudCells, maxCloud = 0, 0, 0, 0, 0
	local minU, minV, minW, maxU, maxV, maxW =
		math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	local sx, cx, sz, cz, cy = 0, 0, 0, 0, 0
	local momentX, momentZ = 0, 0
	for y = 0, self.SizeY - 1 do
		for z = 0, self.SizeZ - 1 do
			for x = 0, self.SizeX - 1 do
				local offset = cellOffset(self, x, y, z)
				local vapor, liquid, rain =
					buffer.readf64(self.Fields.qv, offset),
					buffer.readf64(self.Fields.qc, offset),
					buffer.readf64(self.Fields.qr, offset)
				qv += vapor
				qc += liquid
				qr += rain
				if liquid > 1e-5 then
					cloudCells += 1
				end
				maxCloud = math.max(maxCloud, liquid)
				local u, v, w =
					buffer.readf64(self.Fields.u, offset),
					buffer.readf64(self.Fields.v, offset),
					buffer.readf64(self.Fields.w, offset)
				minU = math.min(minU, u)
				maxU = math.max(maxU, u)
				minV = math.min(minV, v)
				maxV = math.max(maxV, v)
				minW = math.min(minW, w)
				maxW = math.max(maxW, w)
				if self.Boundary == "Sealed" then
					momentX += liquid * (self.Coordinates.MinXMeters + (x + 0.5) * self.Dx)
					momentZ += liquid * (self.Coordinates.MinZMeters + (z + 0.5) * self.Dz)
				else
					local ax, az =
						2 * math.pi * (x + 0.5) / self.SizeX, 2 * math.pi * (z + 0.5) / self.SizeZ
					sx += liquid * math.sin(ax)
					cx += liquid * math.cos(ax)
					sz += liquid * math.sin(az)
					cz += liquid * math.cos(az)
				end
				cy += liquid * (self.Coordinates.BaseAltitudeMeters + (y + 0.5) * self.Dy)
			end
		end
	end
	local total = qv + qc + qr
	local defined = qc > 0
		and (
			self.Boundary == "Sealed"
			or (
				math.sqrt(sx * sx + cx * cx) > qc * 1e-9
				and math.sqrt(sz * sz + cz * cz) > qc * 1e-9
			)
		)
	local centroidX = if self.Boundary == "Sealed" and qc > 0
		then momentX / qc
		else self.Coordinates.MinXMeters
			+ (math.atan2(sx, cx) % (2 * math.pi))
				/ (2 * math.pi)
				* self.Coordinates.WidthMeters
	local centroidZ = if self.Boundary == "Sealed" and qc > 0
		then momentZ / qc
		else self.Coordinates.MinZMeters
			+ (math.atan2(sz, cz) % (2 * math.pi))
				/ (2 * math.pi)
				* self.Coordinates.DepthMeters
	local centroidY = if qc > 0 then cy / qc else self.Coordinates.BaseAltitudeMeters
	local wx, wy, wz = self.Coordinates:PhysicalToWorld(centroidX, centroidY, centroidZ)
	local absoluteCrossing, net = 0, 0
	for offset = 0, 15 * 8, 8 do
		absoluteCrossing += buffer.readf64(self.RegionQcFlux, offset)
		net += buffer.readf64(self.RegionWaterNet, offset)
	end
	return {
		Time = self.Time,
		Tick = self.Tick,
		QvSum = qv,
		QcSum = qc,
		QrSum = qr,
		WaterSum = total,
		TotalWater = total,
		WaterDriftFraction = (total - self.InitialWaterSum - self.ExternalWaterSum)
			/ self.InitialWaterSum,
		RawWaterChangeFraction = (total - self.InitialWaterSum) / self.InitialWaterSum,
		ExternalWaterSum = self.ExternalWaterSum,
		ExternalThetaSum = self.ExternalThetaSum,
		ExternalEnthalpySum = self.ExternalEnthalpySum,
		CloudCells = cloudCells,
		MaxCloudWater = maxCloud,
		MinU = minU,
		MaxU = maxU,
		MinV = minV,
		MaxV = maxV,
		MinW = minW,
		MaxW = maxW,
		DivergenceRms = self.DivergenceRms,
		DivergenceMax = self.DivergenceMax,
		MaxCourant = self.MaxCourant,
		Substeps = self.Substeps,
		StepMilliseconds = self.StepMilliseconds,
		CloudCentroidDefined = defined,
		CloudCentroidX = centroidX,
		CloudCentroidY = centroidY,
		CloudCentroidZ = centroidZ,
		CloudCentroidStudX = wx,
		CloudCentroidStudY = wy,
		CloudCentroidStudZ = wz,
		CloudCentroidXStuds = wx,
		CloudCentroidYStuds = wy,
		CloudCentroidZStuds = wz,
		RegionCrossingQcSum = absoluteCrossing / 2,
		InternalRegionCrossingQcSum = self.InternalRegionQcTransfer,
		OuterPeriodicQcTransferSum = self.OuterPeriodicQcTransfer,
		RegionWaterNetSum = net,
		CellCount = self.Count,
		BufferBytes = self:GetStorageBytes(),
		ActiveRegions = 16,
		DensityAssumption = "constant-reference-density unweighted mixing-ratio sums; not kilograms",
		VelocityModel = "prescribed divergence-free streamfunction closure; no coarse momentum or projection solve",
	}
end

-- Low-rate developer inspection only: no per-cell tables in the physical loop.
function Field:GetRegionDiagnostics(): { any }
	local result: { any } = table.create(16)
	local cellsPerRegion = self.Count / 16
	for id = 1, 16 do
		local bounds = self.Coordinates.Bounds[id]
		result[id] = {
			Id = id,
			X = bounds.X,
			Z = bounds.Z,
			Bounds = bounds,
			CloudCells = 0,
			Coverage = 0,
			QvSum = 0,
			QcSum = 0,
			QrSum = 0,
			Processing = "GlobalSharedField",
			Active = true,
			Boundary = "Internal shared faces; outer world boundary=" .. self.Boundary,
			CumulativeQcInterfaceFlux = buffer.readf64(self.RegionQcFlux, (id - 1) * 8),
			CumulativeWaterNet = buffer.readf64(self.RegionWaterNet, (id - 1) * 8),
		}
	end
	for y = 0, self.SizeY - 1 do
		for z = 0, self.SizeZ - 1 do
			for x = 0, self.SizeX - 1 do
				local id = math.floor(z / (self.SizeZ / 4)) * 4
					+ math.floor(x / (self.SizeX / 4))
					+ 1
				local record = result[id]
				local offset = cellOffset(self, x, y, z)
				local cloud = buffer.readf64(self.Fields.qc, offset)
				record.QvSum += buffer.readf64(self.Fields.qv, offset)
				record.QcSum += cloud
				record.QrSum += buffer.readf64(self.Fields.qr, offset)
				if cloud > 1e-5 then
					record.CloudCells += 1
				end
			end
		end
	end
	for _, record in result do
		record.Coverage = record.CloudCells / cellsPerRegion
	end
	return result
end

function Field:GetStorageBytes(): number
	local bytes = 0
	for _, name in FIELD_NAMES do
		bytes += buffer.len(self.Fields[name])
	end
	for _, name in SCALARS do
		bytes += buffer.len(self.PendingScalar[name]) + buffer.len(self.ScratchScalar[name])
	end
	for _, value in
		{
			self.FacesU,
			self.FacesV,
			self.FacesW,
			self.Streamfunction,
			self.PressureLayers,
			self.Profile.Theta,
			self.Profile.Qv,
			self.Profile.U,
			self.Profile.V,
			self.Advection.FluxU,
			self.Advection.FluxV,
			self.Advection.FluxW,
			self.RegionQcFlux,
			self.RegionWaterNet,
			self.LastRegionQcFlux,
			self.LastRegionWaterNet,
			self.Advection.RegionQcFlux,
			self.Advection.RegionWaterNet,
		}
	do
		bytes += buffer.len(value)
	end
	return bytes
end

return table.freeze(Field)
