--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeatherSnapshot = require(ReplicatedStorage.Shared.Atmosphere.World.WeatherSnapshot)

local WeatherReplication = {}
WeatherReplication.__index = WeatherReplication

export type Settings = {
	Seed: number?,
	MaxRecords: number?,
	RateHz: number?,
	DebugEnabled: boolean?,
	DebugRegions: boolean?,
	DebugVectors: boolean?,
	Threshold: number?,
	DroppedTime: (() -> number)?,
}

-- The optional transport is also the production boundary tested by Lune: every
-- player receives the same immutable-by-convention cached payload. It performs
-- no player-dependent field generation and accepts no administrative requests.
export type Transport = {
	Broadcast: (buffer) -> (),
	SetRequestHandler: ((any) -> buffer?) -> (),
	Destroy: (() -> ())?,
}

export type Replication = typeof(setmetatable(
	{} :: {
		Field: any,
		Seed: number,
		Generation: number,
		Sequence: number,
		WallTime: number,
		Accumulator: number,
		Interval: number,
		Workspace: WeatherSnapshot.Workspace,
		Settings: Settings,
		Channel: Transport,
		Latest: buffer?,
		LastRequests: { [any]: number },
		Published: number,
		DroppedUpdates: number,
		LastBytes: number,
		BytesBroadcast: number,
		RequestCount: number,
		RejectedRequests: number,
		Destroyed: boolean,
	},
	WeatherReplication
))

local function createChannel(): Transport
	local name = "WEATHERED_WORLD_WEATHER"
	assert(
		not ReplicatedStorage:FindFirstChild(name),
		"World weather replication is already initialized"
	)
	local folder = Instance.new("Folder")
	folder.Name = name
	local event = Instance.new("RemoteEvent")
	event.Name = "Snapshot"
	event.Parent = folder
	local request = Instance.new("RemoteFunction")
	request.Name = "GetSnapshot"
	request.Parent = folder
	folder.Parent = ReplicatedStorage
	local removal: RBXScriptConnection? = nil
	local players = game:GetService("Players")
	return {
		Broadcast = function(payload: buffer)
			event:FireAllClients(payload)
		end,
		SetRequestHandler = function(handler: (any) -> buffer?)
			request.OnServerInvoke = function(player: Player, ...: any): buffer?
				-- No arguments are part of the public read-only protocol. In
				-- particular, seed/wind/reset commands never cross this channel.
				if select("#", ...) ~= 0 then
					return nil
				end
				return handler(player)
			end
			removal = players.PlayerRemoving:Connect(function(player: Player)
				-- A nil player is not a request; it releases the limiter entry.
				handler({ RemovedPlayer = player })
			end)
		end,
		Destroy = function()
			if removal then
				removal:Disconnect()
			end
			request.OnServerInvoke = nil
			folder:Destroy()
		end,
	}
end

function WeatherReplication.new(field: any, settings: Settings?, transport: Transport?): Replication
	local options = settings or {}
	local rate = options.RateHz or 1
	assert(rate == rate and rate >= 0.25 and rate <= 2, "World snapshot rate must be 0.25..2 Hz")
	local self: Replication = setmetatable({
		Field = field,
		Seed = options.Seed or 84219,
		Generation = 0,
		Sequence = 0,
		WallTime = 0,
		Accumulator = 0,
		Interval = 1 / rate,
		Workspace = WeatherSnapshot.NewWorkspace(options.MaxRecords or 256),
		Settings = table.clone(options),
		Channel = transport or createChannel(),
		Latest = nil,
		LastRequests = {},
		Published = 0,
		DroppedUpdates = 0,
		LastBytes = 0,
		BytesBroadcast = 0,
		RequestCount = 0,
		RejectedRequests = 0,
		Destroyed = false,
	}, WeatherReplication)
	local initialized, message = pcall(function()
		self.Channel.SetRequestHandler(function(player: any): buffer?
			if type(player) == "table" and player.RemovedPlayer then
				self.LastRequests[player.RemovedPlayer] = nil
				return nil
			end
			return self:RequestSnapshot(player)
		end)
		self:Publish()
	end)
	if not initialized then
		self:Destroy()
		error(message, 2)
	end
	return self
end

function WeatherReplication:Publish(): buffer
	assert(not self.Destroyed, "World replication was destroyed")
	local field = self.Field
	local coordinates = field.Coordinates
	local dims = field.State.Grid
	local diagnostics = field:GetDiagnostics()
	local payload = WeatherSnapshot.Encode(field.State.Fields, {
		SizeX = dims.SizeX,
		SizeY = dims.SizeY,
		SizeZ = dims.SizeZ,
		Seed = self.Seed,
		Generation = self.Generation,
		Sequence = self.Sequence,
		Time = field.Time,
		WallTime = self.WallTime,
		DroppedTime = if self.Settings.DroppedTime then self.Settings.DroppedTime() else 0,
		WidthStuds = coordinates.WidthStuds,
		DepthStuds = coordinates.DepthStuds,
		StudsPerMeter = coordinates.StudsPerMeter,
		MinXStuds = coordinates.MinX,
		MinZStuds = coordinates.MinZ,
		BottomYStuds = coordinates.BottomStuds,
		LayerHeightStuds = coordinates.HeightMeters * coordinates.StudsPerMeter / dims.SizeY,
		DebugEnabled = self.Settings.DebugEnabled ~= false,
		DebugRegions = self.Settings.DebugRegions == true,
		DebugVectors = self.Settings.DebugVectors == true,
		MaxCourant = diagnostics.MaxCourant or 0,
		CentroidDefined = diagnostics.CloudCentroidDefined == true,
		CentroidXStuds = diagnostics.CloudCentroidStudX or 0,
		CentroidYStuds = diagnostics.CloudCentroidStudY or 0,
		CentroidZStuds = diagnostics.CloudCentroidStudZ or 0,
	}, self.Workspace, self.Settings.Threshold, field.ValueBytes or 8)
	self.Latest = payload
	self.LastBytes = buffer.len(payload)
	self.BytesBroadcast += self.LastBytes
	self.Published += 1
	self.Sequence += 1
	self.Channel.Broadcast(payload)
	return payload
end

function WeatherReplication:Update(dt: number)
	assert(dt == dt and dt >= 0 and dt < math.huge, "Invalid snapshot wall timestep")
	assert(not self.Destroyed, "World replication was destroyed")
	self.WallTime += dt
	self.Accumulator += dt
	if self.Accumulator >= self.Interval then
		local opportunities = math.floor(self.Accumulator / self.Interval)
		self.DroppedUpdates += opportunities - 1
		self.Accumulator %= self.Interval
		-- A stalled frame publishes only the latest state once, never a burst
		-- of stale packets or an unbounded network catch-up loop.
		self:Publish()
	end
end

function WeatherReplication:RequestSnapshot(player: any): buffer?
	if self.Destroyed or player == nil then
		return nil
	end
	local previous = self.LastRequests[player]
	if previous ~= nil and self.WallTime - previous < 2 then
		self.RejectedRequests += 1
		return nil
	end
	self.LastRequests[player] = self.WallTime
	self.RequestCount += 1
	return self.Latest
end

function WeatherReplication:SetField(field: any, seed: number?)
	assert(not self.Destroyed, "World replication was destroyed")
	self.Field = field
	self.Seed = seed or self.Seed
	self.Generation += 1
	self.Accumulator = 0
	self:Publish()
end

function WeatherReplication:SetDebugFlags(regions: boolean, vectors: boolean)
	self.Settings.DebugRegions = regions
	self.Settings.DebugVectors = vectors
end

function WeatherReplication:SetDebugEnabled(enabled: boolean)
	self.Settings.DebugEnabled = enabled
end

function WeatherReplication:GetDiagnostics(): { [string]: number }
	return {
		SnapshotRateHz = 1 / self.Interval,
		SnapshotRecordCap = self.Workspace.Limit,
		SnapshotLastBytes = self.LastBytes,
		SnapshotBytesBroadcast = self.BytesBroadcast,
		SnapshotsPublished = self.Published,
		SnapshotUpdatesDropped = self.DroppedUpdates,
		SnapshotRequests = self.RequestCount,
		SnapshotRequestsRejected = self.RejectedRequests,
		SnapshotGeneration = self.Generation,
	}
end

function WeatherReplication:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	if self.Channel.Destroy then
		self.Channel.Destroy()
	end
	self.Latest = nil
	table.clear(self.LastRequests)
end

return table.freeze(WeatherReplication)
