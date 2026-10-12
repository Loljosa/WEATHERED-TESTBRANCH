--!strict

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local createLoader = require("./RobloxModuleLoader")

-- Production world bootstrap, real physics/source/controller/replication
-- modules, and fake Roblox plumbing. No Studio/network performance is inferred.
return function(root: any, loadModule: any, check: any, near: any, rejects: any, _quick: boolean?)
	local Snapshot = loadModule(root.World.WeatherSnapshot)
	local RenderSnapshot = loadModule(root.Rendering.CloudRenderSnapshot)
	local function signal(): any
		local connections = {}
		return {
			Connect = function(_self: any, callback: any): any
				local connection = { Connected = true, Callback = callback }
				function connection:Disconnect()
					self.Connected = false
				end
				table.insert(connections, connection)
				return connection
			end,
			Fire = function(_self: any, ...: any)
				for _, connection in connections do
					if connection.Connected then
						connection.Callback(...)
					end
				end
			end,
			ConnectionCount = function(): number
				local count = 0
				for _, connection in connections do
					if connection.Connected then
						count += 1
					end
				end
				return count
			end,
		}
	end
	local function setup(canonicalSeed: any): any
		local instances: { any } = {}
		local broadcasts: { buffer } = {}
		local renderBroadcasts: { buffer } = {}
		local heartbeat, leaving = signal(), signal()
		local attributes =
			serde.decode("json", fs.readFile("src/server/WeatherServer.meta.json")).attributes
		attributes.AutoClouds = false
		local newInstance: (string) -> any
		newInstance = function(className: string): any
			local props: any = {
				ClassName = className,
				Attributes = {},
				Children = {},
				Signals = {},
				Destroying = signal(),
				Destroyed = false,
			}
			local instance = setmetatable({}, {
				__index = function(_self: any, key: string): any
					if key == "FindFirstChild" then
						return function(_same: any, name: string): any
							for _, child in props.Children do
								if child.Name == name and not child.Destroyed then
									return child
								end
							end
							return nil
						end
					elseif key == "GetChildren" then
						return function()
							return table.clone(props.Children)
						end
					elseif key == "GetAttribute" then
						return function(_same: any, name: string)
							return props.Attributes[name]
						end
					elseif key == "GetAttributeChangedSignal" then
						return function(_same: any, name: string): any
							if not props.Signals[name] then
								props.Signals[name] = signal()
							end
							return props.Signals[name]
						end
					elseif key == "SetAttribute" then
						return function(same: any, name: string, value: any)
							if props.Attributes[name] ~= value then
								props.Attributes[name] = value
								same:GetAttributeChangedSignal(name):Fire()
							end
						end
					elseif key == "Invoke" then
						return function(same: any, ...: any): any
							return same.OnInvoke(...)
						end
					elseif key == "FireAllClients" then
						return function(same: any, message: buffer)
							table.insert(
								if same.Parent.Name == "WEATHERED_CLOUD_RENDER_DATA"
									then renderBroadcasts
									else broadcasts,
								message
							)
						end
					elseif key == "Destroy" then
						return function(same: any)
							if props.Destroyed then
								return
							end
							props.Destroyed = true
							props.Destroying:Fire()
							for _, child in table.clone(props.Children) do
								child:Destroy()
							end
							if props.Parent then
								local index = table.find(props.Parent.Children, same)
								if index then
									table.remove(props.Parent.Children, index)
								end
							end
						end
					end
					return props[key]
				end,
				__newindex = function(same: any, key: string, value: any)
					if key == "Parent" and value ~= props.Parent then
						if props.Parent then
							local index = table.find(props.Parent.Children, same)
							if index then
								table.remove(props.Parent.Children, index)
							end
						end
						if value then
							table.insert(value.Children, same)
						end
					end
					props[key] = value
				end,
			})
			table.insert(instances, instance)
			return instance
		end
		local storage = newInstance("ReplicatedStorage")
		storage.Shared = { Atmosphere = root }
		local world = newInstance("Workspace")
		world.Attributes.WorldSeed = canonicalSeed
		local warnings: { string } = {}
		local fakeGame = {
			GetService = function(_self: any, name: string): any
				if name == "ReplicatedStorage" then
					return storage
				elseif name == "Workspace" then
					return world
				elseif name == "RunService" then
					return {
						Heartbeat = heartbeat,
						IsStudio = function()
							return true
						end,
					}
				elseif name == "HttpService" then
					return {
						JSONEncode = function(_same: any, value: any)
							return serde.encode("json", value)
						end,
					}
				elseif name == "Players" then
					return { PlayerRemoving = leaving }
				end
				error("Unexpected test service " .. name)
			end,
		}
		local server, loadServer = createLoader("src/server", {
			game = fakeGame,
			Instance = { new = newInstance },
			print = function() end,
			warn = function(...: any)
				local text = {}
				for _, value in { ... } do
					table.insert(text, tostring(value))
				end
				table.insert(warnings, table.concat(text, " "))
			end,
		})
		local script = newInstance("Script")
		script.Parent = { Children = {}, Simulation = server.Simulation }
		script.Attributes = attributes
		local execute = luau.load(
			"return function(script, require)\n"
				.. fs.readFile("src/server/WeatherServer.server.lua")
				.. "\nend",
			{ debugName = "@src/server/WeatherServer.server.lua", codegenEnabled = true }
		)()
		local lifecycle: any = nil
		local function requireServer(node: any): any
			if node == server.Simulation.WorldWeatherBootstrap then
				return {
					Start = function(weatherScript: any)
						lifecycle = loadServer(node).Start(weatherScript)
						return lifecycle
					end,
				}
			end
			return loadServer(node)
		end
		execute(script, requireServer)
		local endpoint = script:FindFirstChild("WeatherControls")
		local channel = storage:FindFirstChild("WEATHERED_WORLD_WEATHER")
		return {
			Script = script,
			Endpoint = endpoint,
			Storage = storage,
			World = world,
			Heartbeat = heartbeat,
			Leaving = leaving,
			Channel = channel,
			Instances = instances,
			Broadcasts = broadcasts,
			RenderBroadcasts = renderBroadcasts,
			Warnings = warnings,
			Attributes = attributes,
			Lifecycle = lifecycle,
			Server = server,
			LoadServer = loadServer,
		}
	end
	local context = setup(0)
	local endpoint = context.Endpoint
	check(
		endpoint ~= nil and endpoint.ClassName == "BindableFunction",
		"Production world developer controls stay server-only"
	)
	check(endpoint.Parent == context.Script, "World controls are owned by the server Script")
	check(
		context.Channel ~= nil,
		"World-enabled startup publishes one shared weather snapshot channel"
	)
	local event = context.Channel:FindFirstChild("Snapshot")
	local request = context.Channel:FindFirstChild("GetSnapshot")
	check(
		event.ClassName == "RemoteEvent" and request.ClassName == "RemoteFunction",
		"Client weather protocol contains only summaries and read-only bootstrap requests"
	)
	check(
		event.OnServerEvent == nil,
		"The snapshot RemoteEvent cannot mutate weather through a server request handler"
	)
	near(#context.Broadcasts, 1, 0, "Production bootstrap creates a single initial global summary")
	local renderChannel = context.Storage:FindFirstChild("WEATHERED_CLOUD_RENDER_DATA")
	check(renderChannel ~= nil, "Smooth clouds use a separate complete rendering channel")
	near(
		#context.RenderBroadcasts,
		1,
		0,
		"Complete rendering data is immediately available for late joins"
	)
	local renderRequest = renderChannel:FindFirstChild("GetSnapshot")
	local renderFirst = RenderSnapshot.Decode(renderRequest.OnServerInvoke({}))
	check(
		renderFirst.Complete and renderFirst.SizeX == 32,
		"Production rendering neighborhoods are complete"
	)
	check(
		renderRequest.OnServerInvoke({}, "wind", 50, 50) == nil,
		"Rendering bootstrap cannot invoke administration"
	)
	local playerA, playerB = {}, {}
	local firstA, firstB = request.OnServerInvoke(playerA), request.OnServerInvoke(playerB)
	check(
		buffer.tostring(firstA) == buffer.tostring(firstB),
		"Different simultaneous player positions share identical world state"
	)
	near(
		Snapshot.Decode(firstA).Seed,
		0,
		0,
		"Canonical Workspace seed zero takes priority over development fallback"
	)
	check(
		request.OnServerInvoke(playerA) == nil,
		"Actual read-only RemoteFunction throttles repeated client requests"
	)
	check(
		request.OnServerInvoke(playerB, "wind", 100, 100) == nil,
		"Client-supplied administration arguments are rejected"
	)
	local initial = endpoint:Invoke("status")
	near(initial.Time, 0, 0, "Production world begins at its deterministic physical time")
	near(initial.QcSum, 0, 0, "Production seeded startup never directly paints visible liquid")
	near(initial.CellCount, 6144, 0, "Laptop bootstrap uses a bounded 32 by 6 by 32 world field")
	near(
		endpoint:Invoke("worldsize", 4028).WidthStuds,
		4028,
		0,
		"Production command validates exact world width"
	)
	local regions = endpoint:Invoke("weatherregions")
	near(#regions, 16, 0, "Production region diagnostics cover all sixteen logical weather regions")
	near(
		regions[1].Bounds.MinX,
		-2014,
		0,
		"World region diagnostics preserve negative global coordinates"
	)
	endpoint:Invoke("wind", 8, 2)
	local wind = endpoint:Invoke("status")
	check(
		wind.MaxU >= 8 and wind.MaxV >= 2,
		"Server-only live wind changes the production coarse velocity field"
	)
	local startingTime = wind.Time
	local startEpoch = Snapshot.Decode(context.Broadcasts[#context.Broadcasts]).Generation
	endpoint:Invoke("spawnseeded")
	near(
		endpoint:Invoke("status").Time,
		startingTime,
		0,
		"New world sources queue without resetting atmosphere time"
	)
	near(
		Snapshot.Decode(context.Broadcasts[#context.Broadcasts]).Generation,
		startEpoch,
		0,
		"Adding a source does not regenerate client weather epochs"
	)
	context.Heartbeat:Fire(0.25)
	near(
		endpoint:Invoke("status").Time,
		0.25,
		0,
		"Production Heartbeat advances one fixed physical step"
	)
	context.Script:SetAttribute("WeatherCommand", "debugregions on")
	context.Script:SetAttribute("WeatherCommand", "debugvectors on")
	check(
		context.Attributes.WeatherCommand == "",
		"Attribute command input clears for repeated server commands"
	)
	context.Heartbeat:Fire(0.75)
	local debugSnapshot = Snapshot.Decode(context.Broadcasts[#context.Broadcasts])
	check(
		debugSnapshot.DebugRegions and debugSnapshot.DebugVectors,
		"Server debug command flags reach the existing global snapshot channel"
	)
	check(debugSnapshot.Time > 0, "Debug snapshots represent actual advancing atmospheric state")
	local status = endpoint:Invoke("status")
	check(
		status.DroppedSteps > 0,
		"Oversized frame backlog is dropped and reported instead of runaway catch-up"
	)
	endpoint:Invoke("pause")
	local paused = endpoint:Invoke("status").Time
	context.Heartbeat:Fire(1)
	near(
		endpoint:Invoke("status").Time,
		paused,
		0,
		"Production pause preserves the authoritative physics timeline"
	)
	local pausedSnapshot = Snapshot.Decode(context.Broadcasts[#context.Broadcasts])
	near(
		pausedSnapshot.Time,
		paused,
		0,
		"Paused clients receive unchanged authoritative physical time"
	)
	endpoint:Invoke("resume")
	context.Heartbeat:Fire(0.25)
	near(
		endpoint:Invoke("status").Time,
		paused + 0.25,
		0,
		"Production resume continues the same fixed-step world timeline"
	)
	local beforeReject = endpoint:Invoke("status").Time
	context.Script:SetAttribute("WeatherCommand", "wind nonsense 2")
	check(
		#context.Warnings > 0
			and string.find(context.Warnings[#context.Warnings], "command rejected", 1, true)
				~= nil,
		"Malformed live commands have meaningful failure messages"
	)
	context.Heartbeat:Fire(0.25)
	near(
		endpoint:Invoke("status").Time,
		beforeReject + 0.25,
		0,
		"Rejected developer commands do not stop valid world physics"
	)
	context.Script:SetAttribute("SimulationSpeed", 2)
	local speedTime = endpoint:Invoke("status").Time
	context.Heartbeat:Fire(0.125)
	near(
		endpoint:Invoke("status").Time,
		speedTime + 0.25,
		0,
		"Existing playback attribute keeps a fixed 0.25-second physical step"
	)
	context.Script:SetAttribute("SimulationSpeed", "invalid")
	near(
		endpoint:Invoke("status").SimulationSpeed,
		2,
		0,
		"Malformed playback attribute preserves the previous validated speed"
	)
	endpoint:Invoke("seed", -39)
	endpoint:Invoke("cloudcoverage", "few")
	local selecting = endpoint:Invoke("seedstatus")
	near(selecting.WorldSeed, 0, 0, "Next initialization seed does not change active weather")
	near(
		selecting.NextWorldSeed,
		-39,
		0,
		"Negative world seed is selected explicitly for regeneration"
	)
	endpoint:Invoke("regenerate")
	local fresh = Snapshot.Decode(context.Broadcasts[#context.Broadcasts])
	near(
		fresh.Generation,
		startEpoch + 1,
		0,
		"Regeneration changes snapshot generation without replacing channels"
	)
	near(fresh.Seed, -39, 0, "Regenerated authoritative snapshots use the newly selected seed")
	near(fresh.Time, 0, 0, "Regeneration deliberately starts a new physical timeline")
	local renderFresh = RenderSnapshot.Decode(context.RenderBroadcasts[#context.RenderBroadcasts])
	near(
		renderFresh.Generation,
		fresh.Generation,
		0,
		"Both channels invalidate history on regeneration"
	)
	near(renderFresh.Seed, -39, 0, "Smooth rendering receives the regenerated world seed")
	near(renderFresh.Time, 0, 0, "Smooth rendering receives the new simulation timeline")
	check(
		context.Storage:FindFirstChild("WEATHERED_WORLD_WEATHER") == context.Channel,
		"Existing client connections survive intentional regeneration"
	)
	check(
		endpoint:Invoke("seedstatus").Coverage == "Few",
		"Coverage scenario changes only after explicit world regeneration"
	)
	-- Strings are checked directly rather than interpreted as numerical values.
	context.Leaving:Fire(playerA)
	check(
		request.OnServerInvoke(playerA) ~= nil,
		"Player departure releases bounded request-throttle storage"
	)
	local folders, events, functions = 0, 0, 0
	for _, instance in context.Instances do
		if instance.ClassName == "Folder" then
			folders += 1
		elseif instance.ClassName == "RemoteEvent" then
			events += 1
		elseif instance.ClassName == "RemoteFunction" then
			functions += 1
		end
	end
	near(folders, 2, 0, "Diagnostic and complete render channels are shared across all players")
	near(events, 2, 0, "Each shared channel uses one low-rate snapshot RemoteEvent")
	near(functions, 2, 0, "Each shared channel uses one read-only late-join function")
	rejects(function()
		endpoint:Invoke("worldsize", 8056)
	end, "Unsupported world sizes cannot silently double the domain")
	local controller = context.Lifecycle.Controller
	local timeBeforeFailure = controller.Field.Time
	buffer.writef64(controller.Field.State.Fields.theta, 0, 0 / 0)
	context.Heartbeat:Fire(0.25)
	near(
		controller.Field.Time,
		timeBeforeFailure,
		0,
		"Numerical failure cannot commit an invalid world step"
	)
	near(
		context.Heartbeat.ConnectionCount(),
		0,
		0,
		"Numerical failure disconnects the production physics Heartbeat"
	)
	context.Heartbeat:Fire(1)
	near(
		controller.Field.Time,
		timeBeforeFailure,
		0,
		"Stopped world physics cannot silently resume after failure"
	)
	check(
		string.find(
			context.Warnings[#context.Warnings],
			"stopped on numerical/runtime failure",
			1,
			true
		) ~= nil,
		"Numerical failure is reported honestly through production warnings"
	)
	context.Script:Destroy()
	check(
		context.Channel.Destroyed,
		"Destroying the weather Script releases its shared snapshot channel"
	)
	near(
		context.Leaving.ConnectionCount(),
		0,
		0,
		"Script cleanup disconnects the request-limiter player listener"
	)
	check(request.OnServerInvoke == nil, "Script cleanup removes the read-only snapshot handler")
	check(
		renderChannel.Destroyed and renderRequest.OnServerInvoke == nil,
		"Script cleanup releases the complete rendering channel"
	)
	check(endpoint.Destroyed, "Script cleanup releases its server-only developer BindableFunction")
	near(
		context.Script:GetAttributeChangedSignal("WeatherCommand").ConnectionCount(),
		0,
		0,
		"Script cleanup releases developer attribute listeners"
	)
	context.Lifecycle.Stop()
	check(context.Channel.Destroyed, "Production cleanup is idempotent")
	local negative = setup(-2147483648)
	near(
		Snapshot.Decode(negative.Broadcasts[1]).Seed,
		-2147483648,
		0,
		"Canonical signed-minimum world seed survives the complete production bootstrap"
	)
	negative.Script:Destroy()
	rejects(function()
		setup("invalid-canonical")
	end, "Malformed canonical world seeds are rejected without fallback substitution")
end
