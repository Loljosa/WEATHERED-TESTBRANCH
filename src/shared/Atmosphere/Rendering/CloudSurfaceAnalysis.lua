--!strict

-- Compact cloud-column bounds, evaluated only when a complete render snapshot
-- arrives. These bounds describe resolved liquid support, not a manufactured
-- tall cloud. A renderer must still require local reconstructed density.
local Snapshot = require(script.Parent.CloudRenderSnapshot)

local Surface = {}
Surface.__index = Surface

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function horizontal(
	position: number,
	minimum: number,
	length: number,
	count: number,
	periodic: boolean
): (number, number, number, boolean)
	local relative = (position - minimum) / length
	if periodic then
		relative %= 1
	elseif relative < 0 or relative > 1 then
		return 1, 1, 0, false
	end
	local cell = relative * count - 0.5
	local lower = math.floor(cell)
	local upper = lower + 1
	local fraction = cell - lower
	if periodic then
		lower %= count
		upper %= count
	else
		lower = math.clamp(lower, 0, count - 1)
		upper = math.clamp(upper, 0, count - 1)
	end
	return lower + 1, upper + 1, fraction, true
end

function Surface.new(options: { Threshold: number? }?): any
	local threshold = if options then options.Threshold or 0.0000001 else 0.0000001
	assert(finite(threshold) and threshold >= 0, "Column threshold must be nonnegative kg/kg")
	return setmetatable({
		Threshold = threshold,
		Snapshot = nil,
		Bases = buffer.create(0),
		Tops = buffer.create(0),
		Occupied = buffer.create(0),
		Columns = 0,
		CloudColumns = 0,
		Updates = 0,
	}, Surface)
end

function Surface:Reset()
	self.Snapshot = nil
	self.CloudColumns = 0
end

function Surface:Update(snapshot: any)
	assert(
		type(snapshot) == "table" and snapshot.Complete == true,
		"Cloud surface requires complete qc data"
	)
	if snapshot == self.Snapshot then
		return
	end
	local columns = snapshot.SizeX * snapshot.SizeZ
	if self.Columns ~= columns then
		self.Bases = buffer.create(columns * 4)
		self.Tops = buffer.create(columns * 4)
		self.Occupied = buffer.create(columns)
		self.Columns = columns
	end
	local cloudy = 0
	for z = 1, snapshot.SizeZ do
		for x = 1, snapshot.SizeX do
			local lowest, highest = 0, 0
			for y = 1, snapshot.SizeY do
				local value, known =
					Snapshot.ReadQC(snapshot, x + (z - 1) * snapshot.SizeX + (y - 1) * columns)
				assert(known, "Unknown cloud column sample cannot be interpreted as empty")
				if value > self.Threshold then
					if lowest == 0 then
						lowest = y
					end
					highest = y
				end
			end
			local offset = x - 1 + (z - 1) * snapshot.SizeX
			if lowest > 0 then
				-- Extend only to the actual cloudy cells' faces. Spatial qc itself
				-- remains smoothly reconstructed, so these envelopes are not cards.
				buffer.writef32(
					self.Bases,
					offset * 4,
					snapshot.BottomYStuds + (lowest - 1) * snapshot.LayerHeightStuds
				)
				buffer.writef32(
					self.Tops,
					offset * 4,
					snapshot.BottomYStuds + highest * snapshot.LayerHeightStuds
				)
				buffer.writeu8(self.Occupied, offset, 1)
				cloudy += 1
			else
				buffer.writef32(self.Bases, offset * 4, 0)
				buffer.writef32(self.Tops, offset * 4, 0)
				buffer.writeu8(self.Occupied, offset, 0)
			end
		end
	end
	self.CloudColumns = cloudy
	self.Snapshot = snapshot
	self.Updates += 1
end

function Surface:Sample(x: number, z: number): (number, number, number, boolean)
	assert(finite(x) and finite(z), "Invalid cloud-column sampling position")
	local snapshot = self.Snapshot
	if not snapshot then
		return 0, 0, 0, false
	end
	local periodic = snapshot.Boundary == "Periodic"
	local x0, x1, tx, validX =
		horizontal(x, snapshot.MinXStuds, snapshot.WidthStuds, snapshot.SizeX, periodic)
	local z0, z1, tz, validZ =
		horizontal(z, snapshot.MinZStuds, snapshot.DepthStuds, snapshot.SizeZ, periodic)
	if not validX or not validZ then
		return 0, 0, 0, false
	end
	local base, top, sum = 0, 0, 0
	for iz = 0, 1 do
		local cz = if iz == 0 then z0 else z1
		local fz = if iz == 0 then 1 - tz else tz
		for ix = 0, 1 do
			local cx = if ix == 0 then x0 else x1
			local offset = cx - 1 + (cz - 1) * snapshot.SizeX
			local weight = fz
				* (if ix == 0 then 1 - tx else tx)
				* buffer.readu8(self.Occupied, offset)
			base += buffer.readf32(self.Bases, offset * 4) * weight
			top += buffer.readf32(self.Tops, offset * 4) * weight
			sum += weight
		end
	end
	if sum <= 1e-12 then
		return 0, 0, 0, false
	end
	base /= sum
	top /= sum
	return base, top, top - base, true
end

function Surface:SampleHeight(x: number, y: number, z: number): (number, boolean)
	assert(finite(y), "Invalid cloud height")
	local base, _, thickness, present = self:Sample(x, z)
	if not present then
		return 0, false
	end
	return math.clamp((y - base) / math.max(thickness, 0.0001), 0, 1), true
end

function Surface:GetStorageBytes(): number
	return buffer.len(self.Bases) + buffer.len(self.Tops) + buffer.len(self.Occupied)
end

function Surface:GetDiagnostics(): any
	return {
		Columns = self.Columns,
		CloudColumns = self.CloudColumns,
		Updates = self.Updates,
		StorageBytes = self:GetStorageBytes(),
	}
end

return Surface
