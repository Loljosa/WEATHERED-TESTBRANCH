--!strict

-- Bounded diagnostic summaries of the one authoritative world field. This is
-- deliberately sparse: omitted cells are diagnostic cropping, never a change
-- to the server's physical state. Velocities retain m/s; geometry uses studs.
local WeatherSnapshot = {}

local MAGIC = 0x57544852
local VERSION = 1
local HEADER_BYTES = 104
local RECORD_BYTES = 18
local MAX_RECORDS = 512
local MAX_CELLS = 65535

export type Metadata = {
	SizeX: number,
	SizeY: number,
	SizeZ: number,
	Seed: number,
	Generation: number?,
	Sequence: number?,
	Time: number,
	WallTime: number?,
	DroppedTime: number?,
	WidthStuds: number,
	DepthStuds: number,
	StudsPerMeter: number,
	MinXStuds: number,
	MinZStuds: number,
	BottomYStuds: number,
	LayerHeightStuds: number,
	DebugEnabled: boolean?,
	DebugRegions: boolean?,
	DebugVectors: boolean?,
	MaxCourant: number?,
	CentroidDefined: boolean?,
	CentroidXStuds: number?,
	CentroidYStuds: number?,
	CentroidZStuds: number?,
}

export type Snapshot = Metadata & {
	Payload: buffer,
	Count: number,
	Limit: number,
	AboveThreshold: number,
	Threshold: number,
	Generation: number,
	Sequence: number,
	WallTime: number,
	DroppedTime: number,
	DebugEnabled: boolean,
	DebugRegions: boolean,
	DebugVectors: boolean,
	CentroidDefined: boolean,
}

export type Workspace = {
	Limit: number,
	Indices: { number },
	Values: { number },
	Sorted: { number },
}

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function integer(value: number, minimum: number, maximum: number, label: string)
	assert(finite(value) and value % 1 == 0 and value >= minimum and value <= maximum, label)
end

local function validateMetadata(meta: Metadata)
	integer(meta.SizeX, 1, MAX_CELLS, "Invalid snapshot X dimension")
	integer(meta.SizeY, 1, MAX_CELLS, "Invalid snapshot Y dimension")
	integer(meta.SizeZ, 1, MAX_CELLS, "Invalid snapshot Z dimension")
	assert(meta.SizeX * meta.SizeY * meta.SizeZ <= MAX_CELLS, "Snapshot grid exceeds u16 indices")
	integer(meta.Seed, -2147483648, 2147483647, "Invalid snapshot seed")
	integer(meta.Generation or 0, 0, 4294967295, "Invalid snapshot generation")
	integer(meta.Sequence or 0, 0, 4294967295, "Invalid snapshot sequence")
	for _, value in { meta.WidthStuds, meta.DepthStuds, meta.StudsPerMeter, meta.LayerHeightStuds } do
		assert(finite(value) and value > 0, "Invalid snapshot dimensions or unit conversion")
	end
	for _, value in
		{
			meta.Time,
			meta.WallTime or 0,
			meta.DroppedTime or 0,
			meta.MinXStuds,
			meta.MinZStuds,
			meta.BottomYStuds,
			meta.MaxCourant or 0,
			meta.CentroidXStuds or 0,
			meta.CentroidYStuds or 0,
			meta.CentroidZStuds or 0,
		}
	do
		assert(finite(value), "Nonfinite snapshot metadata")
	end
	assert(
		meta.Time >= 0 and (meta.WallTime or 0) >= 0 and (meta.DroppedTime or 0) >= 0,
		"Negative snapshot time"
	)
end

function WeatherSnapshot.NewWorkspace(limit: number): Workspace
	integer(limit, 1, MAX_RECORDS, "Snapshot record cap must be 1..512")
	return {
		Limit = limit,
		Indices = table.create(limit),
		Values = table.create(limit),
		Sorted = table.create(limit),
	}
end

-- A min-heap retains the strongest liquid cells without scanning only one map
-- corner. For equal water, larger indices are weaker, making selection stable.
local function weaker(aValue: number, aIndex: number, bValue: number, bIndex: number): boolean
	return aValue < bValue or (aValue == bValue and aIndex > bIndex)
end

local function siftDown(work: Workspace, count: number)
	local position = 1
	while position * 2 <= count do
		local child = position * 2
		if
			child < count
			and weaker(
				work.Values[child + 1],
				work.Indices[child + 1],
				work.Values[child],
				work.Indices[child]
			)
		then
			child += 1
		end
		if
			not weaker(
				work.Values[child],
				work.Indices[child],
				work.Values[position],
				work.Indices[position]
			)
		then
			break
		end
		work.Values[position], work.Values[child] = work.Values[child], work.Values[position]
		work.Indices[position], work.Indices[child] = work.Indices[child], work.Indices[position]
		position = child
	end
end

function WeatherSnapshot.Encode(
	fields: { [string]: buffer },
	meta: Metadata,
	work: Workspace,
	threshold: number?,
	fieldBytes: number?
): buffer
	validateMetadata(meta)
	local minimum = threshold or 0.00005 -- kg/kg, the existing diagnostic cutoff.
	assert(finite(minimum) and minimum > 0, "Invalid snapshot liquid threshold")
	local stride = fieldBytes or 8
	assert(stride == 4 or stride == 8, "Snapshot fields must be f32 or f64")
	local read = if stride == 8 then buffer.readf64 else buffer.readf32
	local cells = meta.SizeX * meta.SizeY * meta.SizeZ
	for _, name in { "qc", "u", "v", "w" } do
		assert(
			typeof(fields[name]) == "buffer" and buffer.len(fields[name]) == cells * stride,
			"Invalid snapshot field length: " .. name
		)
	end
	local selected = 0
	local above = 0
	for index = 1, cells do
		local value = read(fields.qc, (index - 1) * stride)
		assert(finite(value) and value >= 0, "Invalid authoritative cloud water in snapshot")
		if value >= minimum then
			above += 1
			if selected < work.Limit then
				selected += 1
				local position = selected
				work.Values[position], work.Indices[position] = value, index
				while position > 1 do
					local parent = math.floor(position / 2)
					if
						not weaker(
							work.Values[position],
							work.Indices[position],
							work.Values[parent],
							work.Indices[parent]
						)
					then
						break
					end
					work.Values[position], work.Values[parent] =
						work.Values[parent], work.Values[position]
					work.Indices[position], work.Indices[parent] =
						work.Indices[parent], work.Indices[position]
					position = parent
				end
			elseif weaker(work.Values[1], work.Indices[1], value, index) then
				work.Values[1], work.Indices[1] = value, index
				siftDown(work, selected)
			end
		end
	end
	table.clear(work.Sorted)
	for position = 1, selected do
		work.Sorted[position] = work.Indices[position]
	end
	table.sort(work.Sorted)
	local output = buffer.create(HEADER_BYTES + selected * RECORD_BYTES)
	buffer.writeu32(output, 0, MAGIC)
	buffer.writeu8(output, 4, VERSION)
	buffer.writeu8(
		output,
		5,
		(if meta.DebugRegions then 1 else 0)
			+ (if meta.DebugVectors then 2 else 0)
			+ (if meta.DebugEnabled ~= false then 4 else 0)
			+ (if meta.CentroidDefined then 8 else 0)
	)
	buffer.writeu16(output, 6, meta.SizeX)
	buffer.writeu16(output, 8, meta.SizeY)
	buffer.writeu16(output, 10, meta.SizeZ)
	buffer.writeu16(output, 12, selected)
	buffer.writeu16(output, 14, work.Limit)
	buffer.writei32(output, 16, meta.Seed)
	buffer.writeu32(output, 20, meta.Generation or 0)
	buffer.writef64(output, 24, meta.Time)
	buffer.writef32(output, 32, meta.WidthStuds)
	buffer.writef32(output, 36, meta.DepthStuds)
	buffer.writef32(output, 40, meta.StudsPerMeter)
	buffer.writef32(output, 44, meta.MinXStuds)
	buffer.writef32(output, 48, meta.MinZStuds)
	buffer.writef32(output, 52, meta.BottomYStuds)
	buffer.writef32(output, 56, meta.LayerHeightStuds)
	buffer.writef32(output, 60, minimum)
	buffer.writeu32(output, 64, above)
	buffer.writef64(output, 68, meta.WallTime or 0)
	buffer.writef64(output, 76, meta.DroppedTime or 0)
	buffer.writeu32(output, 84, meta.Sequence or 0)
	buffer.writef32(output, 88, meta.MaxCourant or 0)
	-- Roblox diagnostic geometry is float32. Reject origins/heights whose
	-- representation collapses neighboring cells instead of broadcasting a
	-- finite f64 configuration that turns into NaN or a single rendered point.
	for _, offset in { 32, 36, 40, 44, 48, 52, 56, 60, 88 } do
		assert(finite(buffer.readf32(output, offset)), "Snapshot header exceeds float32 range")
	end
	local function represented(value: number): number
		buffer.writef32(output, 100, value) -- scratch until centroid metadata is written below
		return buffer.readf32(output, 100)
	end
	local function resolves(origin: number, extent: number, layers: number)
		local spacing = extent / layers
		local start = represented(origin)
		local first = represented(origin + spacing)
		local finish = represented(origin + extent)
		local beforeFinish = represented(origin + extent - spacing)
		assert(
			finite(start)
				and finite(first)
				and finite(finish)
				and finite(beforeFinish)
				and math.abs(start - origin) <= spacing * 0.1
				and math.abs((first - start) - spacing) <= spacing * 0.1
				and math.abs((finish - beforeFinish) - spacing) <= spacing * 0.1,
			"Snapshot geometry cannot resolve configured cells as float32"
		)
	end
	resolves(meta.MinXStuds, meta.WidthStuds, meta.SizeX)
	resolves(meta.MinZStuds, meta.DepthStuds, meta.SizeZ)
	resolves(meta.BottomYStuds, meta.LayerHeightStuds * meta.SizeY, meta.SizeY)
	buffer.writef32(output, 92, meta.CentroidXStuds or 0)
	buffer.writef32(output, 96, meta.CentroidYStuds or 0)
	buffer.writef32(output, 100, meta.CentroidZStuds or 0)
	for _, offset in { 92, 96, 100 } do
		assert(finite(buffer.readf32(output, offset)), "Snapshot centroid exceeds float32 range")
	end
	for position = 1, selected do
		local index = work.Sorted[position]
		local offset = HEADER_BYTES + (position - 1) * RECORD_BYTES
		buffer.writeu16(output, offset, index)
		for component, name in { "qc", "u", "v", "w" } do
			local value = read(fields[name], (index - 1) * stride)
			assert(finite(value), "Nonfinite snapshot field: " .. name)
			buffer.writef32(output, offset + 2 + (component - 1) * 4, value)
			assert(
				finite(buffer.readf32(output, offset + 2 + (component - 1) * 4)),
				"Snapshot value exceeds float32 range"
			)
		end
	end
	return output
end

function WeatherSnapshot.Decode(payload: buffer): Snapshot
	assert(
		typeof(payload) == "buffer" and buffer.len(payload) >= HEADER_BYTES,
		"Snapshot header is truncated"
	)
	assert(
		buffer.readu32(payload, 0) == MAGIC and buffer.readu8(payload, 4) == VERSION,
		"Unsupported weather snapshot"
	)
	local count = buffer.readu16(payload, 12)
	local limit = buffer.readu16(payload, 14)
	integer(limit, 1, MAX_RECORDS, "Invalid snapshot record cap")
	assert(
		count <= limit and buffer.len(payload) == HEADER_BYTES + count * RECORD_BYTES,
		"Invalid snapshot record length"
	)
	local flags = buffer.readu8(payload, 5)
	assert(flags <= 15, "Invalid snapshot debug flags")
	local result: Snapshot = {
		Payload = payload,
		SizeX = buffer.readu16(payload, 6),
		SizeY = buffer.readu16(payload, 8),
		SizeZ = buffer.readu16(payload, 10),
		Count = count,
		Limit = limit,
		Seed = buffer.readi32(payload, 16),
		Generation = buffer.readu32(payload, 20),
		Time = buffer.readf64(payload, 24),
		WidthStuds = buffer.readf32(payload, 32),
		DepthStuds = buffer.readf32(payload, 36),
		StudsPerMeter = buffer.readf32(payload, 40),
		MinXStuds = buffer.readf32(payload, 44),
		MinZStuds = buffer.readf32(payload, 48),
		BottomYStuds = buffer.readf32(payload, 52),
		LayerHeightStuds = buffer.readf32(payload, 56),
		Threshold = buffer.readf32(payload, 60),
		AboveThreshold = buffer.readu32(payload, 64),
		WallTime = buffer.readf64(payload, 68),
		DroppedTime = buffer.readf64(payload, 76),
		Sequence = buffer.readu32(payload, 84),
		MaxCourant = buffer.readf32(payload, 88),
		CentroidXStuds = buffer.readf32(payload, 92),
		CentroidYStuds = buffer.readf32(payload, 96),
		CentroidZStuds = buffer.readf32(payload, 100),
		DebugRegions = bit32.band(flags, 1) ~= 0,
		DebugVectors = bit32.band(flags, 2) ~= 0,
		DebugEnabled = bit32.band(flags, 4) ~= 0,
		CentroidDefined = bit32.band(flags, 8) ~= 0,
	}
	validateMetadata(result)
	assert(
		finite(result.Threshold) and result.Threshold > 0 and result.AboveThreshold >= count,
		"Invalid snapshot threshold/count"
	)
	local previous = 0
	local cells = result.SizeX * result.SizeY * result.SizeZ
	for position = 1, count do
		local offset = HEADER_BYTES + (position - 1) * RECORD_BYTES
		local index = buffer.readu16(payload, offset)
		assert(index > previous and index <= cells, "Snapshot indices must be ordered and in range")
		previous = index
		for component = 0, 3 do
			local value = buffer.readf32(payload, offset + 2 + component * 4)
			assert(finite(value) and (component > 0 or value >= 0), "Invalid snapshot record value")
		end
	end
	return table.freeze(result)
end

function WeatherSnapshot.Record(
	snapshot: Snapshot,
	position: number
): (number, number, number, number, number)
	integer(position, 1, snapshot.Count, "Snapshot record position out of range")
	local offset = HEADER_BYTES + (position - 1) * RECORD_BYTES
	return buffer.readu16(snapshot.Payload, offset),
		buffer.readf32(snapshot.Payload, offset + 2),
		buffer.readf32(snapshot.Payload, offset + 6),
		buffer.readf32(snapshot.Payload, offset + 10),
		buffer.readf32(snapshot.Payload, offset + 14)
end

function WeatherSnapshot.Sample(snapshot: Snapshot, index: number): (number, number, number, number)
	local lo, hi = 1, snapshot.Count
	while lo <= hi do
		local middle = math.floor((lo + hi) / 2)
		local offset = HEADER_BYTES + (middle - 1) * RECORD_BYTES
		local cell = buffer.readu16(snapshot.Payload, offset)
		if cell < index then
			lo = middle + 1
		elseif cell > index then
			hi = middle - 1
		else
			return buffer.readf32(snapshot.Payload, offset + 2),
				buffer.readf32(snapshot.Payload, offset + 6),
				buffer.readf32(snapshot.Payload, offset + 10),
				buffer.readf32(snapshot.Payload, offset + 14)
		end
	end
	return 0, 0, 0, 0
end

function WeatherSnapshot.IsNewer(previous: Snapshot?, candidate: Snapshot): boolean
	if not previous then
		return true
	end
	if candidate.Generation ~= previous.Generation then
		return candidate.Generation > previous.Generation
	end
	return candidate.Sequence > previous.Sequence and candidate.Time >= previous.Time
end

function WeatherSnapshot.Compatible(a: Snapshot, b: Snapshot): boolean
	return a.Generation == b.Generation
		and a.Seed == b.Seed
		and a.SizeX == b.SizeX
		and a.SizeY == b.SizeY
		and a.SizeZ == b.SizeZ
		and a.WidthStuds == b.WidthStuds
		and a.DepthStuds == b.DepthStuds
		and a.StudsPerMeter == b.StudsPerMeter
		and a.MinXStuds == b.MinXStuds
		and a.MinZStuds == b.MinZStuds
		and a.BottomYStuds == b.BottomYStuds
		and a.LayerHeightStuds == b.LayerHeightStuds
end

function WeatherSnapshot.Interpolate(
	a: Snapshot,
	b: Snapshot,
	index: number,
	alpha: number
): (number, number, number, number)
	assert(finite(alpha) and alpha >= 0 and alpha <= 1, "Interpolation alpha must be in [0,1]")
	if not WeatherSnapshot.Compatible(a, b) then
		return WeatherSnapshot.Sample(b, index)
	end
	local aq, au, av, aw = WeatherSnapshot.Sample(a, index)
	local bq, bu, bv, bw = WeatherSnapshot.Sample(b, index)
	return aq + (bq - aq) * alpha,
		au + (bu - au) * alpha,
		av + (bv - av) * alpha,
		aw + (bw - aw) * alpha
end

function WeatherSnapshot.CellCenter(snapshot: Snapshot, index: number): (number, number, number)
	integer(
		index,
		1,
		snapshot.SizeX * snapshot.SizeY * snapshot.SizeZ,
		"Snapshot cell index out of range"
	)
	-- Grid3D's existing X-fastest, then Z, then Y convention.
	local zero = index - 1
	local x = zero % snapshot.SizeX
	local y = math.floor(zero / (snapshot.SizeX * snapshot.SizeZ))
	local z = math.floor(zero / snapshot.SizeX) % snapshot.SizeZ
	return snapshot.MinXStuds + (x + 0.5) * snapshot.WidthStuds / snapshot.SizeX,
		snapshot.BottomYStuds + (y + 0.5) * snapshot.LayerHeightStuds,
		snapshot.MinZStuds + (z + 0.5) * snapshot.DepthStuds / snapshot.SizeZ
end

WeatherSnapshot.HeaderBytes = HEADER_BYTES
WeatherSnapshot.RecordBytes = RECORD_BYTES
WeatherSnapshot.MaxRecords = MAX_RECORDS
return table.freeze(WeatherSnapshot)
