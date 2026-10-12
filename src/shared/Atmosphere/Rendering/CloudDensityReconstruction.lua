--!strict

-- Client display reconstruction only. qc retains kg/kg; positions are studs,
-- velocity is m/s, and gradients below are display-density derivatives/stud.
-- Every accepted packet contains the COMPLETE qc lattice. The diagnostic
-- top-K codec intentionally cannot be used here: absence is not a known zero.
local Snapshot = require(script.Parent.CloudRenderSnapshot)

local Reconstruction = {}
Reconstruction.__index = Reconstruction

export type Options = {
	QcReference: number?,
	StaleAfter: number?,
	StaleFade: number?,
	VelocityAssist: boolean?,
	MaxVisualAdvectionSeconds: number?,
}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function positive(value: number, label: string): number
	assert(finite(value) and value > 0, label)
	return value
end

local function smooth(value: number): number
	return value * value * (3 - 2 * value)
end

-- Sealed faces fade to zero over the outer half-cell. This is a DISPLAY
-- support window, not a physical boundary condition or an extension of the
-- shallow simulated atmosphere. Periodic lateral sampling has no such fade.
local function axis(
	position: number,
	minimum: number,
	length: number,
	count: number,
	periodic: boolean
): (number, number, number, number)
	local relative = (position - minimum) / length
	if periodic then
		relative %= 1
	elseif relative < 0 or relative > 1 then
		return 1, 1, 0, 0
	end
	local centered = relative * count - 0.5
	local low = math.floor(centered)
	local fraction = centered - low
	local high = low + 1
	local window = 1
	if periodic then
		low = low % count
		high = high % count
	else
		if centered < 0 then
			window = smooth(math.clamp(2 * relative * count, 0, 1))
		elseif centered > count - 1 then
			window = smooth(math.clamp(2 * (1 - relative) * count, 0, 1))
		end
		low = math.clamp(low, 0, count - 1)
		high = math.clamp(high, 0, count - 1)
	end
	return low + 1, high + 1, fraction, window
end

local function qc(snapshot: any, x: number, y: number, z: number): number
	local index = x + (z - 1) * snapshot.SizeX + (y - 1) * snapshot.SizeX * snapshot.SizeZ
	local value, known = Snapshot.ReadQC(snapshot, index)
	assert(known, "Cloud reconstruction requires complete spatial neighborhoods")
	return value
end

local function supportWindow(snapshot: any, x: number, y: number, z: number): number
	local periodic = snapshot.Boundary == "Periodic"
	local _, _, _, wx = axis(x, snapshot.MinXStuds, snapshot.WidthStuds, snapshot.SizeX, periodic)
	local _, _, _, wz = axis(z, snapshot.MinZStuds, snapshot.DepthStuds, snapshot.SizeZ, periodic)
	local _, _, _, wy = axis(
		y,
		snapshot.BottomYStuds,
		snapshot.LayerHeightStuds * snapshot.SizeY,
		snapshot.SizeY,
		false
	)
	return wx * wy * wz
end

local function sampleQC(snapshot: any, x: number, y: number, z: number, raw: boolean?): number
	local periodic = snapshot.Boundary == "Periodic"
	local x0, x1, tx, wx =
		axis(x, snapshot.MinXStuds, snapshot.WidthStuds, snapshot.SizeX, periodic)
	local z0, z1, tz, wz =
		axis(z, snapshot.MinZStuds, snapshot.DepthStuds, snapshot.SizeZ, periodic)
	local y0, y1, ty, wy = axis(
		y,
		snapshot.BottomYStuds,
		snapshot.LayerHeightStuds * snapshot.SizeY,
		snapshot.SizeY,
		false
	)
	if wx * wy * wz == 0 then
		return 0
	end
	local a = qc(snapshot, x0, y0, z0) * (1 - tx) + qc(snapshot, x1, y0, z0) * tx
	local b = qc(snapshot, x0, y0, z1) * (1 - tx) + qc(snapshot, x1, y0, z1) * tx
	local c = qc(snapshot, x0, y1, z0) * (1 - tx) + qc(snapshot, x1, y1, z0) * tx
	local d = qc(snapshot, x0, y1, z1) * (1 - tx) + qc(snapshot, x1, y1, z1) * tx
	local value = (a * (1 - tz) + b * tz) * (1 - ty) + (c * (1 - tz) + d * tz) * ty
	return if raw then value else value * wx * wy * wz
end

local function velocity(snapshot: any, x: number, y: number, z: number): (number, number, number)
	local periodic = snapshot.Boundary == "Periodic"
	local nx, ny, nz = snapshot.VelocitySizeX, snapshot.VelocitySizeY, snapshot.VelocitySizeZ
	local x0, x1, tx = axis(x, snapshot.MinXStuds, snapshot.WidthStuds, nx, periodic)
	local z0, z1, tz = axis(z, snapshot.MinZStuds, snapshot.DepthStuds, nz, periodic)
	local y0, y1, ty =
		axis(y, snapshot.BottomYStuds, snapshot.LayerHeightStuds * snapshot.SizeY, ny, false)
	local u, v, w = 0, 0, 0
	for iy = 0, 1 do
		local cy = if iy == 0 then y0 else y1
		local fy = if iy == 0 then 1 - ty else ty
		for iz = 0, 1 do
			local cz = if iz == 0 then z0 else z1
			local fz = if iz == 0 then 1 - tz else tz
			for ix = 0, 1 do
				local cx = if ix == 0 then x0 else x1
				local weight = fy * fz * (if ix == 0 then 1 - tx else tx)
				local a, b, c =
					Snapshot.ReadVelocity(snapshot, cx + (cz - 1) * nx + (cy - 1) * nx * nz)
				u += a * weight
				v += b * weight
				w += c * weight
			end
		end
	end
	return u, v, w
end

function Reconstruction.new(options: Options?): any
	local settings = options or {}
	local self = setmetatable({}, Reconstruction)
	self.QcReference =
		positive(settings.QcReference or 0.00005, "QcReference must be positive kg/kg")
	self.StaleAfter =
		positive(settings.StaleAfter or 10, "StaleAfter must be positive wall seconds")
	self.StaleFade = positive(settings.StaleFade or 20, "StaleFade must be positive wall seconds")
	self.MaxVisualAdvectionSeconds = positive(
		settings.MaxVisualAdvectionSeconds or 2,
		"Visual advection duration must be positive"
	)
	self.VelocityAssist = settings.VelocityAssist ~= false
	self.Current = nil
	self.Previous = nil
	self.ReceivedWall = 0
	self.Interval = 1
	self.Accepted = 0
	self.Rejected = 0
	self.Resets = 0
	return self
end

function Reconstruction:Reset()
	self.Current = nil
	self.Previous = nil
	self.Resets += 1
end

function Reconstruction:Push(snapshot: any, receivedWall: number): boolean
	assert(finite(receivedWall) and receivedWall >= 0, "Invalid snapshot receipt wall time")
	if
		type(snapshot) ~= "table"
		or snapshot.Complete ~= true
		or typeof(snapshot.Payload) ~= "buffer"
	then
		self.Rejected += 1
		return false
	end
	local old = self.Current
	if old and not Snapshot.IsNewer(old, snapshot) then
		self.Rejected += 1
		return false
	end
	local compatible = old ~= nil and Snapshot.Compatible(old, snapshot)
	if compatible and (snapshot.Time < old.Time or snapshot.WallTime < old.WallTime) then
		self.Rejected += 1
		return false
	end
	if compatible then
		self.Previous = old
		-- Server elapsed WALL time defines playback duration; simulation time
		-- defines physical displacement. Speed, pause and dropped time therefore
		-- cannot silently turn seconds into an incorrect velocity conversion.
		self.Interval = math.clamp(snapshot.WallTime - old.WallTime, 0.05, 5)
	else
		self.Previous = nil
		if old then
			self.Resets += 1
		end
	end
	self.Current = snapshot
	self.ReceivedWall = receivedWall
	self.Accepted += 1
	return true
end

function Reconstruction:_temporal(wallNow: number): (number, number, number)
	assert(finite(wallNow), "Invalid render wall time")
	local age = math.max(0, wallNow - self.ReceivedWall)
	local alpha = if self.Previous then math.clamp(age / self.Interval, 0, 1) else 1
	local fade = 1 - smooth(math.clamp((age - self.StaleAfter) / self.StaleFade, 0, 1))
	return alpha, fade, age
end

function Reconstruction:SampleVelocity(
	x: number,
	y: number,
	z: number,
	wallNow: number
): (number, number, number)
	assert(finite(x) and finite(y) and finite(z), "Nonfinite cloud sampling position")
	if not self.Current then
		return 0, 0, 0
	end
	local alpha = self:_temporal(wallNow)
	local u, v, w = velocity(self.Current, x, y, z)
	if self.Previous then
		local a, b, c = velocity(self.Previous, x, y, z)
		u, v, w =
			a * (1 - alpha) + u * alpha, b * (1 - alpha) + v * alpha, c * (1 - alpha) + w * alpha
	end
	return u, v, w
end

function Reconstruction:SampleQC(x: number, y: number, z: number, wallNow: number): number
	assert(finite(x) and finite(y) and finite(z), "Nonfinite cloud sampling position")
	local current = self.Current
	if not current then
		return 0
	end
	local alpha, fade = self:_temporal(wallNow)
	if fade == 0 then
		return 0
	end
	local previous = self.Previous
	if not previous or alpha >= 1 then
		return sampleQC(current, x, y, z) * fade
	end
	local ox, oy, oz, nx, ny, nz = x, y, z, x, y, z
	local window = supportWindow(current, x, y, z)
	if window == 0 then
		return 0
	end
	if self.VelocityAssist then
		local dt = math.min(current.Time - previous.Time, self.MaxVisualAdvectionSeconds)
		if dt > 0 then
			local u, v, w = self:SampleVelocity(x, y, z, wallNow)
			local scale = current.StudsPerMeter
			local dx = math.clamp(
				u * dt * scale,
				-current.WidthStuds / current.SizeX,
				current.WidthStuds / current.SizeX
			)
			local dz = math.clamp(
				v * dt * scale,
				-current.DepthStuds / current.SizeZ,
				current.DepthStuds / current.SizeZ
			)
			local dy =
				math.clamp(w * dt * scale, -current.LayerHeightStuds, current.LayerHeightStuds)
			ox, oy, oz = x - dx * alpha, y - dy * alpha, z - dz * alpha
			nx, ny, nz = x + dx * (1 - alpha), y + dy * (1 - alpha), z + dz * (1 - alpha)
		end
	end
	-- The DISPLAY support window belongs to the requested world position,
	-- not to traced source positions. Velocity assistance cannot leak optical
	-- cloud above/below the resolved physical atmosphere.
	return (
		sampleQC(previous, ox, oy, oz, true) * (1 - alpha)
		+ sampleQC(current, nx, ny, nz, true) * alpha
	)
		* window
		* fade
end

function Reconstruction:SampleDensity(x: number, y: number, z: number, wallNow: number): number
	local value = self:SampleQC(x, y, z, wallNow)
	-- Fixed, shared display mapping. No normalized maxima that would make a
	-- vanishing trace of liquid appear as a fully opaque persistent cloud.
	return 1 - math.exp(-value / self.QcReference)
end

function Reconstruction:Gradient(
	x: number,
	y: number,
	z: number,
	wallNow: number
): (number, number, number)
	local current = self.Current
	if not current then
		return 0, 0, 0
	end
	local hx = current.WidthStuds / current.SizeX * 0.125
	local hy = current.LayerHeightStuds * 0.125
	local hz = current.DepthStuds / current.SizeZ * 0.125
	return (self:SampleDensity(x + hx, y, z, wallNow) - self:SampleDensity(x - hx, y, z, wallNow))
		/ (2 * hx),
		(self:SampleDensity(x, y + hy, z, wallNow) - self:SampleDensity(x, y - hy, z, wallNow))
			/ (2 * hy),
		(self:SampleDensity(x, y, z + hz, wallNow) - self:SampleDensity(x, y, z - hz, wallNow))
			/ (2 * hz)
end

function Reconstruction:GetTemporalState(wallNow: number): any
	local alpha, fade, age = self:_temporal(wallNow)
	local current, previous = self.Current, self.Previous
	return {
		Snapshot = current,
		Previous = previous,
		Alpha = alpha,
		Age = age,
		StaleFade = fade,
		Time = if current
			then (if previous
				then previous.Time * (1 - alpha) + current.Time * alpha
				else current.Time)
			else 0,
		Interval = self.Interval,
	}
end

function Reconstruction:GetRenderTime(wallNow: number): number
	local alpha = self:_temporal(wallNow)
	local current, previous = self.Current, self.Previous
	if not current then
		return 0
	end
	return if previous then previous.Time * (1 - alpha) + current.Time * alpha else current.Time
end

function Reconstruction:GetMetadata(): any
	return self.Current
end

function Reconstruction:GetDiagnostics(wallNow: number): any
	local state = self:GetTemporalState(wallNow)
	state.Accepted = self.Accepted
	state.Rejected = self.Rejected
	state.Resets = self.Resets
	state.Complete = self.Current ~= nil and self.Current.Complete == true
	state.PayloadBytes = if self.Current then buffer.len(self.Current.Payload) else 0
	return state
end

return Reconstruction
