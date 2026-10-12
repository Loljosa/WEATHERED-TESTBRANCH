--!strict

-- COMPLETE render data, separate from the sparse diagnostic WTHR protocol.
-- qc remains kg/kg: q = MaxQc * (byte / 255)^2. A zero byte is a known
-- quantized zero, not evidence that the unquantized liquid was exactly zero.
-- The maximum absolute rounding error is <= MaxQc * (1/255 + 1/(4*255^2)).
-- Velocities are an independently complete coarse lattice in physical m/s.
local Snapshot = {}

local MAGIC = 0x32524357 -- ASCII WCR2 in little-endian buffer order.
local VERSION = 1
local HEADER_BYTES = 128
local MAX_PAYLOAD_BYTES = 65536
local MAX_CELLS = 65536
local VELOCITY_BYTES = 6

export type Metadata = {
	Seed: number?,
	Generation: number?,
	Sequence: number?,
	Time: number?,
	WallTime: number?,
	DroppedTime: number?,
}

export type Snapshot = {
	Payload: buffer,
	Version: number,
	Complete: boolean,
	SizeX: number,
	SizeY: number,
	SizeZ: number,
	VelocitySizeX: number,
	VelocitySizeY: number,
	VelocitySizeZ: number,
	Count: number,
	VelocityCount: number,
	QcOffset: number,
	VelocityOffset: number,
	Seed: number,
	Generation: number,
	Sequence: number,
	Time: number,
	WallTime: number,
	DroppedTime: number,
	MinXStuds: number,
	MinZStuds: number,
	WidthStuds: number,
	DepthStuds: number,
	BottomYStuds: number,
	LayerHeightStuds: number,
	StudsPerMeter: number,
	BaseAltitudeMeters: number,
	Boundary: string,
	MaxQc: number,
	VelocityScale: number,
}

local function finite(value: number): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function integer(value: number, minimum: number, maximum: number, message: string)
	assert(finite(value) and value % 1 == 0 and value >= minimum and value <= maximum, message)
end

local function dimensions(nx: number, ny: number, nz: number)
	integer(nx, 1, 65535, "Invalid render snapshot X dimension")
	integer(ny, 1, 65535, "Invalid render snapshot Y dimension")
	integer(nz, 1, 65535, "Invalid render snapshot Z dimension")
	assert(nx * ny * nz <= MAX_CELLS, "Render snapshot exceeds bounded cell count")
end

local function validate(snapshot: Snapshot)
	dimensions(snapshot.SizeX, snapshot.SizeY, snapshot.SizeZ)
	assert(
		snapshot.Count == snapshot.SizeX * snapshot.SizeY * snapshot.SizeZ,
		"Incomplete qc field"
	)
	assert(
		snapshot.VelocitySizeX == math.max(1, math.floor(snapshot.SizeX / 4))
			and snapshot.VelocitySizeY == snapshot.SizeY
			and snapshot.VelocitySizeZ == math.max(1, math.floor(snapshot.SizeZ / 4)),
		"Invalid complete render velocity lattice"
	)
	assert(
		snapshot.VelocityCount
			== snapshot.VelocitySizeX * snapshot.VelocitySizeY * snapshot.VelocitySizeZ,
		"Incomplete velocity field"
	)
	integer(snapshot.Seed, -2147483648, 2147483647, "Invalid signed render seed")
	integer(snapshot.Generation, 0, 4294967295, "Invalid render generation")
	integer(snapshot.Sequence, 0, 4294967295, "Invalid render sequence")
	for _, value in { snapshot.Time, snapshot.WallTime, snapshot.DroppedTime } do
		assert(finite(value) and value >= 0, "Invalid render snapshot clock")
	end
	for _, value in
		{
			snapshot.WidthStuds,
			snapshot.DepthStuds,
			snapshot.LayerHeightStuds,
			snapshot.StudsPerMeter,
			snapshot.VelocityScale,
		}
	do
		assert(finite(value) and value > 0, "Invalid render snapshot scale")
	end
	for _, value in
		{
			snapshot.MinXStuds,
			snapshot.MinZStuds,
			snapshot.BottomYStuds,
			snapshot.BaseAltitudeMeters,
		}
	do
		assert(finite(value), "Invalid render snapshot origin")
	end
	assert(finite(snapshot.MaxQc) and snapshot.MaxQc >= 0, "Invalid render cloud-water scale")
	assert(
		snapshot.Boundary == "Periodic" or snapshot.Boundary == "Sealed",
		"Invalid render boundary"
	)
	assert(snapshot.Complete, "Cropped render packets cannot reconstruct complete neighborhoods")
end

local function validateRepresentedGeometry(snapshot: Snapshot, payload: buffer)
	-- Check BOTH ends: finite float32 geometry can still collapse adjacent cells
	-- at an enormous origin. The final reserved slot is scratch during encoding.
	local function represented(value: number): number
		buffer.writef32(payload, 124, value)
		return buffer.readf32(payload, 124)
	end
	local function resolves(origin: number, extent: number, count: number)
		local spacing = extent / count
		local encodedOrigin, encodedExtent = represented(origin), represented(extent)
		local resolution = math.max(
			math.abs(encodedOrigin),
			math.abs(encodedOrigin + encodedExtent)
		) * 2 ^ -23
		assert(
			finite(represented(origin + extent))
				and encodedExtent / count > resolution
				and represented(origin) < represented(origin + spacing)
				and represented(origin + extent - spacing) < represented(origin + extent),
			"Render snapshot geometry collapses neighboring float32 cells"
		)
	end
	resolves(snapshot.MinXStuds, snapshot.WidthStuds, snapshot.SizeX)
	resolves(snapshot.MinZStuds, snapshot.DepthStuds, snapshot.SizeZ)
	resolves(snapshot.BottomYStuds, snapshot.LayerHeightStuds * snapshot.SizeY, snapshot.SizeY)
	buffer.writeu32(payload, 124, 0)
end

local function sampleVelocity(
	fields: { [string]: buffer },
	read: (buffer, number) -> number,
	stride: number,
	nx: number,
	ny: number,
	nz: number,
	gx: number,
	gy: number,
	gz: number,
	periodic: boolean
): (number, number, number)
	if not periodic then
		gx, gz = math.clamp(gx, 0, nx - 1), math.clamp(gz, 0, nz - 1)
	end
	gy = math.clamp(gy, 0, ny - 1)
	local bx, by, bz = math.floor(gx), math.floor(gy), math.floor(gz)
	local fx, fy, fz = gx - bx, gy - by, gz - bz
	local u, v, w = 0, 0, 0
	for dy = 0, 1 do
		for dz = 0, 1 do
			for dx = 0, 1 do
				local ix, iy, iz = (bx + dx) % nx, math.min(by + dy, ny - 1), (bz + dz) % nz
				local weight = (if dx == 0 then 1 - fx else fx)
					* (if dy == 0 then 1 - fy else fy)
					* (if dz == 0 then 1 - fz else fz)
				local offset = ((iy * nz + iz) * nx + ix) * stride
				u += weight * read(fields.u, offset)
				v += weight * read(fields.v, offset)
				w += weight * read(fields.w, offset)
			end
		end
	end
	return u, v, w
end

function Snapshot.Encode(field: any, metadata: Metadata?): buffer
	local meta = metadata or {}
	local grid = if field.State then field.State.Grid else (field.Dims or field.Grid)
	local fields = if field.State then field.State.Fields else field.Fields
	local coords = field.Coordinates
	assert(grid and fields and coords, "Render snapshots require an authoritative world field")
	local nx, ny, nz = grid.SizeX, grid.SizeY, grid.SizeZ
	dimensions(nx, ny, nz)
	local vx, vy, vz = math.max(1, math.floor(nx / 4)), ny, math.max(1, math.floor(nz / 4))
	local count, velocityCount = nx * ny * nz, vx * vy * vz
	local length = HEADER_BYTES + count + velocityCount * VELOCITY_BYTES
	assert(length <= MAX_PAYLOAD_BYTES, "Render snapshot exceeds the 64 KiB packet budget")
	local stride = field.ValueBytes or 8
	assert(stride == 4 or stride == 8, "Render snapshot fields must be float32 or float64")
	local read = if stride == 8 then buffer.readf64 else buffer.readf32
	for _, name in { "qc", "u", "v", "w" } do
		assert(
			typeof(fields[name]) == "buffer" and buffer.len(fields[name]) == count * stride,
			"Invalid authoritative render field length: " .. name
		)
	end
	local maxQc, maxVelocity = 0, 0
	for index = 0, count - 1 do
		local offset = index * stride
		local qc, u, v, w =
			read(fields.qc, offset),
			read(fields.u, offset),
			read(fields.v, offset),
			read(fields.w, offset)
		assert(finite(qc) and qc >= 0, "Invalid authoritative render cloud water")
		assert(finite(u) and finite(v) and finite(w), "Invalid authoritative render velocity")
		maxQc = math.max(maxQc, qc)
		maxVelocity = math.max(maxVelocity, math.abs(u), math.abs(v), math.abs(w))
	end
	local payload = buffer.create(length)
	-- Tiny headroom guarantees representable scales after float32 rounding.
	-- Quantizing a valid concentration is the ONLY density rounding here.
	buffer.writef32(payload, 88, maxQc * (1 + 1e-6))
	buffer.writef32(payload, 92, if maxVelocity == 0 then 1 else maxVelocity / 32760)
	local qcScale, velocityScale = buffer.readf32(payload, 88), buffer.readf32(payload, 92)
	assert(
		finite(qcScale) and (maxQc == 0 or qcScale > 0),
		"Cloud-water scale exceeds float32 range"
	)
	assert(finite(velocityScale) and velocityScale > 0, "Velocity scale exceeds float32 range")
	local snapshot: Snapshot = {
		Payload = payload,
		Version = VERSION,
		Complete = true,
		SizeX = nx,
		SizeY = ny,
		SizeZ = nz,
		VelocitySizeX = vx,
		VelocitySizeY = vy,
		VelocitySizeZ = vz,
		Count = count,
		VelocityCount = velocityCount,
		QcOffset = HEADER_BYTES,
		VelocityOffset = HEADER_BYTES + count,
		Seed = if meta.Seed == nil then 84219 else meta.Seed,
		Generation = meta.Generation or 0,
		Sequence = meta.Sequence or 0,
		Time = if meta.Time == nil then field.Time else meta.Time,
		WallTime = meta.WallTime or 0,
		DroppedTime = meta.DroppedTime or 0,
		MinXStuds = coords.MinX,
		MinZStuds = coords.MinZ,
		WidthStuds = coords.WidthStuds,
		DepthStuds = coords.DepthStuds,
		BottomYStuds = coords.BottomStuds,
		LayerHeightStuds = coords.HeightMeters * coords.StudsPerMeter / ny,
		StudsPerMeter = coords.StudsPerMeter,
		BaseAltitudeMeters = coords.BaseAltitudeMeters,
		Boundary = field.Boundary or "Periodic",
		MaxQc = qcScale,
		VelocityScale = velocityScale,
	}
	validate(snapshot)
	buffer.writeu32(payload, 0, MAGIC)
	buffer.writeu8(payload, 4, VERSION)
	buffer.writeu8(payload, 5, 1 + (if snapshot.Boundary == "Periodic" then 2 else 0))
	buffer.writeu16(payload, 6, HEADER_BYTES)
	buffer.writeu16(payload, 8, nx)
	buffer.writeu16(payload, 10, ny)
	buffer.writeu16(payload, 12, nz)
	buffer.writeu16(payload, 14, vx)
	buffer.writeu16(payload, 16, vy)
	buffer.writeu16(payload, 18, vz)
	buffer.writei32(payload, 20, snapshot.Seed)
	buffer.writeu32(payload, 24, snapshot.Generation)
	buffer.writeu32(payload, 28, snapshot.Sequence)
	buffer.writef64(payload, 32, snapshot.Time)
	buffer.writef64(payload, 40, snapshot.WallTime)
	buffer.writef64(payload, 48, snapshot.DroppedTime)
	buffer.writef32(payload, 56, snapshot.MinXStuds)
	buffer.writef32(payload, 60, snapshot.MinZStuds)
	buffer.writef32(payload, 64, snapshot.WidthStuds)
	buffer.writef32(payload, 68, snapshot.DepthStuds)
	buffer.writef32(payload, 72, snapshot.BottomYStuds)
	buffer.writef32(payload, 76, snapshot.LayerHeightStuds)
	buffer.writef32(payload, 80, snapshot.StudsPerMeter)
	buffer.writef32(payload, 84, snapshot.BaseAltitudeMeters)
	buffer.writeu32(payload, 96, count)
	buffer.writeu32(payload, 100, velocityCount)
	buffer.writeu32(payload, 104, length)
	for offset = 56, 92, 4 do
		assert(finite(buffer.readf32(payload, offset)), "Render header exceeds float32 range")
	end
	validateRepresentedGeometry(snapshot, payload)
	for index = 0, count - 1 do
		local qc = read(fields.qc, index * stride)
		local quantized = if qcScale == 0
			then 0
			else math.floor(255 * math.sqrt(qc / qcScale) + 0.5)
		assert(quantized >= 0 and quantized <= 255, "Render concentration quantization overflow")
		buffer.writeu8(payload, HEADER_BYTES + index, quantized)
	end
	local position = HEADER_BYTES + count
	for iy = 0, vy - 1 do
		for iz = 0, vz - 1 do
			for ix = 0, vx - 1 do
				-- Both lattices use the SAME world bounds. A coarse velocity-cell
				-- center maps to this fractional authoritative cell coordinate.
				local u, v, w = sampleVelocity(
					fields,
					read,
					stride,
					nx,
					ny,
					nz,
					(ix + 0.5) * nx / vx - 0.5,
					(iy + 0.5) * ny / vy - 0.5,
					(iz + 0.5) * nz / vz - 0.5,
					snapshot.Boundary == "Periodic"
				)
				local qu, qv, qw =
					math.round(u / velocityScale),
					math.round(v / velocityScale),
					math.round(w / velocityScale)
				assert(
					math.abs(qu) <= 32767 and math.abs(qv) <= 32767 and math.abs(qw) <= 32767,
					"Render velocity quantization overflow"
				)
				buffer.writei16(payload, position, qu)
				buffer.writei16(payload, position + 2, qv)
				buffer.writei16(payload, position + 4, qw)
				position += VELOCITY_BYTES
			end
		end
	end
	return payload
end

function Snapshot.Decode(payload: buffer): Snapshot
	assert(typeof(payload) == "buffer", "Render snapshot must be a buffer")
	local length = buffer.len(payload)
	assert(
		length >= HEADER_BYTES and length <= MAX_PAYLOAD_BYTES,
		"Render snapshot packet length is invalid"
	)
	assert(
		buffer.readu32(payload, 0) == MAGIC and buffer.readu8(payload, 4) == VERSION,
		"Unsupported complete cloud render snapshot"
	)
	assert(buffer.readu16(payload, 6) == HEADER_BYTES, "Unsupported cloud render header size")
	local flags = buffer.readu8(payload, 5)
	assert(flags == 1 or flags == 3, "Render snapshot must explicitly contain complete data")
	for offset = 108, 124, 4 do
		assert(buffer.readu32(payload, offset) == 0, "Unsupported cloud render header extension")
	end
	local count, velocityCount = buffer.readu32(payload, 96), buffer.readu32(payload, 100)
	assert(
		buffer.readu32(payload, 104) == length
			and length == HEADER_BYTES + count + velocityCount * VELOCITY_BYTES,
		"Cloud render payload is incomplete or has trailing bytes"
	)
	local result: Snapshot = {
		Payload = payload,
		Version = VERSION,
		Complete = true,
		SizeX = buffer.readu16(payload, 8),
		SizeY = buffer.readu16(payload, 10),
		SizeZ = buffer.readu16(payload, 12),
		VelocitySizeX = buffer.readu16(payload, 14),
		VelocitySizeY = buffer.readu16(payload, 16),
		VelocitySizeZ = buffer.readu16(payload, 18),
		Count = count,
		VelocityCount = velocityCount,
		QcOffset = HEADER_BYTES,
		VelocityOffset = HEADER_BYTES + count,
		Seed = buffer.readi32(payload, 20),
		Generation = buffer.readu32(payload, 24),
		Sequence = buffer.readu32(payload, 28),
		Time = buffer.readf64(payload, 32),
		WallTime = buffer.readf64(payload, 40),
		DroppedTime = buffer.readf64(payload, 48),
		MinXStuds = buffer.readf32(payload, 56),
		MinZStuds = buffer.readf32(payload, 60),
		WidthStuds = buffer.readf32(payload, 64),
		DepthStuds = buffer.readf32(payload, 68),
		BottomYStuds = buffer.readf32(payload, 72),
		LayerHeightStuds = buffer.readf32(payload, 76),
		StudsPerMeter = buffer.readf32(payload, 80),
		BaseAltitudeMeters = buffer.readf32(payload, 84),
		Boundary = if flags == 3 then "Periodic" else "Sealed",
		MaxQc = buffer.readf32(payload, 88),
		VelocityScale = buffer.readf32(payload, 92),
	}
	validate(result)
	-- Without mutating the received packet, reject float32 coordinates whose
	-- already encoded values cannot distinguish neighboring renderer cells.
	local function resolves(origin: number, extent: number, cells: number): boolean
		local spacing = extent / cells
		local tolerance = math.max(math.abs(origin), math.abs(origin + extent)) * 2 ^ -23
		return finite(origin + extent) and spacing > tolerance
	end
	assert(
		resolves(result.MinXStuds, result.WidthStuds, result.SizeX)
			and resolves(result.MinZStuds, result.DepthStuds, result.SizeZ)
			and resolves(result.BottomYStuds, result.LayerHeightStuds * result.SizeY, result.SizeY),
		"Cloud render geometry has insufficient float32 resolution"
	)
	if result.MaxQc == 0 then
		for index = 0, count - 1 do
			assert(
				buffer.readu8(payload, HEADER_BYTES + index) == 0,
				"Zero qc scale with nonzero density data"
			)
		end
	end
	return table.freeze(result)
end

function Snapshot.ReadQC(snapshot: Snapshot, index: number): (number, boolean)
	if
		not snapshot.Complete
		or not finite(index)
		or index % 1 ~= 0
		or index < 1
		or index > snapshot.Count
	then
		return 0, false -- Unknown; never silently treated as a known empty cell.
	end
	local unit = buffer.readu8(snapshot.Payload, snapshot.QcOffset + index - 1) / 255
	return snapshot.MaxQc * unit * unit, true
end

function Snapshot.ReadVelocity(snapshot: Snapshot, index: number): (number, number, number)
	integer(index, 1, snapshot.VelocityCount, "Render velocity index out of bounds")
	local offset = snapshot.VelocityOffset + (index - 1) * VELOCITY_BYTES
	local scale = snapshot.VelocityScale
	return buffer.readi16(snapshot.Payload, offset) * scale,
		buffer.readi16(snapshot.Payload, offset + 2) * scale,
		buffer.readi16(snapshot.Payload, offset + 4) * scale
end

function Snapshot.CellCenter(snapshot: Snapshot, index: number): (number, number, number)
	integer(index, 1, snapshot.Count, "Render cell index out of bounds")
	local zero = index - 1
	local x = zero % snapshot.SizeX
	local z = math.floor(zero / snapshot.SizeX) % snapshot.SizeZ
	local y = math.floor(zero / (snapshot.SizeX * snapshot.SizeZ))
	return snapshot.MinXStuds + (x + 0.5) * snapshot.WidthStuds / snapshot.SizeX,
		snapshot.BottomYStuds + (y + 0.5) * snapshot.LayerHeightStuds,
		snapshot.MinZStuds + (z + 0.5) * snapshot.DepthStuds / snapshot.SizeZ
end

function Snapshot.Compatible(a: Snapshot, b: Snapshot): boolean
	return a.Complete
		and b.Complete
		and a.Version == b.Version
		and a.Generation == b.Generation
		and a.Seed == b.Seed
		and a.SizeX == b.SizeX
		and a.SizeY == b.SizeY
		and a.SizeZ == b.SizeZ
		and a.VelocitySizeX == b.VelocitySizeX
		and a.VelocitySizeY == b.VelocitySizeY
		and a.VelocitySizeZ == b.VelocitySizeZ
		and a.MinXStuds == b.MinXStuds
		and a.MinZStuds == b.MinZStuds
		and a.WidthStuds == b.WidthStuds
		and a.DepthStuds == b.DepthStuds
		and a.BottomYStuds == b.BottomYStuds
		and a.LayerHeightStuds == b.LayerHeightStuds
		and a.StudsPerMeter == b.StudsPerMeter
		and a.BaseAltitudeMeters == b.BaseAltitudeMeters
		and a.Boundary == b.Boundary
end

function Snapshot.IsNewer(previous: Snapshot, incoming: Snapshot): boolean
	if incoming.Generation ~= previous.Generation then
		return incoming.Generation > previous.Generation
	end
	return incoming.Sequence > previous.Sequence
		and incoming.Time >= previous.Time
		and incoming.WallTime >= previous.WallTime
end

Snapshot.HeaderBytes = HEADER_BYTES
Snapshot.MaxPayloadBytes = MAX_PAYLOAD_BYTES
Snapshot.Version = VERSION

return table.freeze(Snapshot)
