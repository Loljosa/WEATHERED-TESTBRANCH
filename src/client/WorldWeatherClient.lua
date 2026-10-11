--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local World = ReplicatedStorage.Shared.Atmosphere.World
local WeatherSnapshot = require(World.WeatherSnapshot)
local WorldVoxelDebugRenderer = require(World.WorldVoxelDebugRenderer)

local WorldWeatherClient = {}
local RENDER_INTERVAL = 0.2 -- at most five local diagnostic updates per second

function WorldWeatherClient.Start(): () -> ()
	local folder = ReplicatedStorage:WaitForChild("WEATHERED_WORLD_WEATHER", 30)
	if not folder then
		warn("[WEATHERED] World snapshots unavailable; legacy weather may be active")
		return function() end
	end
	local event = folder:WaitForChild("Snapshot") :: RemoteEvent
	local request = folder:WaitForChild("GetSnapshot") :: RemoteFunction
	local previous: WeatherSnapshot.Snapshot? = nil
	local current: WeatherSnapshot.Snapshot? = nil
	local renderer: WorldVoxelDebugRenderer.Renderer? = nil
	local age = 0
	local interpolationDuration = 1
	local renderAccumulator = 0
	local alive = true
	local function accept(payload: any)
		if not alive then
			return
		end
		local ok, decoded = pcall(WeatherSnapshot.Decode, payload)
		if not ok then
			warn("[WEATHERED] Rejected invalid world snapshot: " .. tostring(decoded))
			return
		end
		local nextSnapshot = decoded :: WeatherSnapshot.Snapshot
		local old = current
		if not WeatherSnapshot.IsNewer(old, nextSnapshot) then
			return -- a late bootstrap response cannot replace a newer live packet
		end
		if
			old
			and WeatherSnapshot.Compatible(old, nextSnapshot)
			and nextSnapshot.Time >= old.Time
		then
			previous = old
			interpolationDuration =
				math.max(0.25, math.min(4, nextSnapshot.WallTime - old.WallTime))
		else
			previous = nextSnapshot
			interpolationDuration = 1
		end
		current = nextSnapshot
		age = 0
		if nextSnapshot.DebugEnabled and not renderer then
			renderer = WorldVoxelDebugRenderer.new(nextSnapshot.Limit)
		elseif renderer then
			renderer:SetLimit(nextSnapshot.Limit)
		end
	end
	local eventConnection = event.OnClientEvent:Connect(accept)
	-- Subscribe before requesting the cached server snapshot. Late joins get
	-- the same global field as existing clients, independent of player region.
	task.spawn(function()
		local ok, payload = pcall(function()
			return request:InvokeServer()
		end)
		if ok and payload then
			accept(payload)
		end
	end)
	local renderConnection = RunService.Heartbeat:Connect(function(dt: number)
		age += dt
		renderAccumulator += dt
		if renderAccumulator < RENDER_INTERVAL then
			return
		end
		renderAccumulator %= RENDER_INTERVAL
		if renderer and previous and current then
			renderer:Update(previous, current, math.min(1, age / interpolationDuration))
		end
	end)
	return function()
		alive = false
		eventConnection:Disconnect()
		renderConnection:Disconnect()
		if renderer then
			renderer:Destroy()
		end
	end
end

return table.freeze(WorldWeatherClient)
