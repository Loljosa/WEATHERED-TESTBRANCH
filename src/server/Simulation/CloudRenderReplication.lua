--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Snapshot = require(ReplicatedStorage.Shared.Atmosphere.Rendering.CloudRenderSnapshot)

-- Rendering data never accepts meteorological commands. A single cached
-- complete packet is shared by broadcasts and every late-joining player.
local Replication = {}
Replication.__index = Replication

export type Settings = {
	Seed: number?,
	RateHz: number?,
	DroppedTime: (() -> number)?,
}

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
		LastEncodeMilliseconds: number,
		TotalEncodeMilliseconds: number,
	},
	Replication
))

local function createChannel(): Transport
	local name = "WEATHERED_CLOUD_RENDER_DATA"
	assert(
		not ReplicatedStorage:FindFirstChild(name),
		"Cloud render replication is already initialized"
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
				if select("#", ...) ~= 0 then
					return nil
				end
				return handler(player)
			end
			removal = players.PlayerRemoving:Connect(function(player: Player)
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

function Replication.new(field: any, settings: Settings?, transport: Transport?): Replication
	local options = settings or {}
	local rate = options.RateHz or 1
	assert(
		rate == rate and rate >= 0.25 and rate <= 2,
		"Cloud render snapshot rate must be 0.25..2 Hz"
	)
	local self: Replication = setmetatable({
		Field = field,
		Seed = if options.Seed == nil then 84219 else options.Seed,
		Generation = 0,
		Sequence = 0,
		WallTime = 0,
		Accumulator = 0,
		Interval = 1 / rate,
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
		LastEncodeMilliseconds = 0,
		TotalEncodeMilliseconds = 0,
	}, Replication)
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

local function encode(
	self: Replication,
	field: any,
	seed: number,
	generation: number
): (buffer, number)
	local started = os.clock()
	local payload = Snapshot.Encode(field, {
		Seed = seed,
		Generation = generation,
		Sequence = self.Sequence,
		WallTime = self.WallTime,
		DroppedTime = if self.Settings.DroppedTime then self.Settings.DroppedTime() else 0,
	})
	return payload, (os.clock() - started) * 1000
end

local function broadcast(self: Replication, payload: buffer, milliseconds: number)
	self.Latest = payload
	self.LastBytes = buffer.len(payload)
	self.BytesBroadcast += self.LastBytes
	self.Published += 1
	self.Sequence += 1
	self.LastEncodeMilliseconds = milliseconds
	self.TotalEncodeMilliseconds += milliseconds
	self.Channel.Broadcast(payload)
end

function Replication:Publish(): buffer
	assert(not self.Destroyed, "Cloud render replication was destroyed")
	local payload, milliseconds = encode(self, self.Field, self.Seed, self.Generation)
	broadcast(self, payload, milliseconds)
	return payload
end

function Replication:Update(dt: number)
	assert(dt == dt and dt >= 0 and dt < math.huge, "Invalid cloud render wall timestep")
	assert(not self.Destroyed, "Cloud render replication was destroyed")
	self.WallTime += dt
	self.Accumulator += dt
	if self.Accumulator >= self.Interval then
		local opportunities = math.floor(self.Accumulator / self.Interval)
		self.DroppedUpdates += opportunities - 1
		self.Accumulator %= self.Interval
		-- Delayed frames send one current packet, never a stale catch-up burst.
		self:Publish()
	end
end

function Replication:RequestSnapshot(player: any): buffer?
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

function Replication:SetField(field: any, seed: number?)
	assert(not self.Destroyed, "Cloud render replication was destroyed")
	local nextSeed = if seed == nil then self.Seed else seed
	local generation = self.Generation + 1
	local payload, milliseconds = encode(self, field, nextSeed, generation)
	-- Invalid replacements must not discard the usable previous weather epoch.
	self.Field, self.Seed, self.Generation = field, nextSeed, generation
	self.Accumulator = 0
	broadcast(self, payload, milliseconds)
end

function Replication:GetDiagnostics(): { [string]: number | boolean }
	return {
		RenderDataComplete = true,
		RenderDataRateHz = 1 / self.Interval,
		RenderDataLastBytes = self.LastBytes,
		RenderDataBytesPerSecond = self.LastBytes / self.Interval,
		RenderDataBytesBroadcast = self.BytesBroadcast,
		RenderDataSnapshotsPublished = self.Published,
		RenderDataUpdatesDropped = self.DroppedUpdates,
		RenderDataRequests = self.RequestCount,
		RenderDataRequestsRejected = self.RejectedRequests,
		RenderDataGeneration = self.Generation,
		RenderDataLastEncodeMilliseconds = self.LastEncodeMilliseconds,
		RenderDataMeanEncodeMilliseconds = if self.Published > 0
			then self.TotalEncodeMilliseconds / self.Published
			else 0,
	}
end

function Replication:Destroy()
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

return table.freeze(Replication)
