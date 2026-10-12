--!strict

local createLoader = require("./RobloxModuleLoader")
local roblox = require("@lune/roblox")

-- Actual unified client, real codecs/reconstruction/cubic renderer/voxel
-- renderer. The mock boundary supplies services, scheduling and Instances;
-- it deliberately contains no cloud-selection or reconstruction algorithm.
return function(root: any, load: any, check: any, near: any, _rejects: any, _quick: boolean?)
	local Field = load(root.World.WeatherField)
	local Coordinates = load(root.World.WorldCoordinates)
	local RenderSnapshot = load(root.Rendering.CloudRenderSnapshot)
	local Diagnostic = load(root.World.WeatherSnapshot)
	local field = Field.new(Coordinates.new(), { SizeX = 4, SizeY = 3, SizeZ = 4 })
	for index = 1, field.Count do
		field.State:Set("qc", index, 0.00003)
	end
	local before = {}
	for name, values in field.Fields do
		before[name] = buffer.tostring(values)
	end
	local function renderPacket(sequence: number, generation: number?, seed: number?): buffer
		return RenderSnapshot.Encode(field, {
			Seed = seed or 84219,
			Generation = generation or 1,
			Sequence = sequence,
			Time = if generation == 2 then 0 else sequence,
			WallTime = sequence,
		})
	end
	local function diagnosticPacket(sequence: number, regions: boolean?, vectors: boolean?): buffer
		local coords = field.Coordinates
		return Diagnostic.Encode(field.Fields, {
			SizeX = field.SizeX,
			SizeY = field.SizeY,
			SizeZ = field.SizeZ,
			Seed = 84219,
			Generation = 1,
			Sequence = sequence,
			Time = sequence,
			WallTime = sequence,
			WidthStuds = coords.WidthStuds,
			DepthStuds = coords.DepthStuds,
			StudsPerMeter = coords.StudsPerMeter,
			MinXStuds = coords.MinX,
			MinZStuds = coords.MinZ,
			BottomYStuds = coords.BottomStuds,
			LayerHeightStuds = coords.HeightMeters * coords.StudsPerMeter / field.SizeY,
			DebugEnabled = false,
			DebugRegions = regions == true,
			DebugVectors = vectors == true,
		}, Diagnostic.NewWorkspace(32), 1e-5, 8)
	end
	local function signal(): any
		local connections = {}
		local result = {}
		function result:Connect(callback: any): any
			local connection = { Connected = true, Callback = callback }
			function connection:Disconnect()
				self.Connected = false
			end
			table.insert(connections, connection)
			return connection
		end
		function result:Fire(...: any)
			for _, connection in table.clone(connections) do
				if connection.Connected then
					connection.Callback(...)
				end
			end
		end
		function result:Count(): number
			local count = 0
			for _, connection in connections do
				if connection.Connected then
					count += 1
				end
			end
			return count
		end
		return result
	end
	local function setup(touch: boolean?, missing: boolean?): any
		local instances, queued, warnings = {}, {}, {}
		local newInstance: (string) -> any
		newInstance = function(className: string): any
			local props: any = {
				ClassName = className,
				Children = {},
				Attributes = {},
				Signals = {},
				Destroyed = false,
				Destroying = signal(),
			}
			local object = setmetatable({}, {
				__index = function(_same: any, key: string): any
					if key == "GetAttribute" then
						return function(_self: any, name: string): any
							return props.Attributes[name]
						end
					elseif key == "SetAttribute" then
						return function(self: any, name: string, value: any)
							if props.Attributes[name] ~= value then
								props.Attributes[name] = value
								self:GetAttributeChangedSignal(name):Fire()
							end
						end
					elseif key == "GetAttributeChangedSignal" then
						return function(_self: any, name: string): any
							if not props.Signals[name] then
								props.Signals[name] = signal()
							end
							return props.Signals[name]
						end
					elseif key == "FindFirstChild" or key == "WaitForChild" then
						return function(_self: any, name: string): any
							for _, child in props.Children do
								if child.Name == name and not child.Destroyed then
									return child
								end
							end
							return nil
						end
					elseif key == "Invoke" then
						return function(self: any, ...: any): any
							return self.OnInvoke(...)
						end
					elseif key == "Destroy" then
						return function(self: any)
							if props.Destroyed then
								return
							end
							props.Destroyed = true
							props.Destroying:Fire()
							for _, child in table.clone(props.Children) do
								child:Destroy()
							end
							if props.Parent then
								local index = table.find(props.Parent.Children, self)
								if index then
									table.remove(props.Parent.Children, index)
								end
							end
						end
					end
					return props[key]
				end,
				__newindex = function(self: any, key: string, value: any)
					if key == "Parent" and props.Parent ~= value then
						if props.Parent then
							local index = table.find(props.Parent.Children, self)
							if index then
								table.remove(props.Parent.Children, index)
							end
						end
						if value then
							table.insert(value.Children, self)
						end
					end
					props[key] = value
				end,
			})
			table.insert(instances, object)
			return object
		end
		local storage, workspace, owner =
			newInstance("ReplicatedStorage"), newInstance("Workspace"), newInstance("LocalScript")
		storage.Shared = { Atmosphere = root }
		workspace.CurrentCamera = {
			CFrame = roblox.CFrame.lookAt(
				roblox.Vector3.new(0, 70, 0),
				roblox.Vector3.new(0, 490, -200)
			),
		}
		owner:SetAttribute("CloudQuality", "Auto")
		local renderEvent, diagnosticEvent = signal(), signal()
		local requests, remoteWrites = 0, 0
		local function channel(name: string, event: any, payload: buffer, newest: buffer?): any
			local folder = newInstance("Folder")
			folder.Name, folder.Parent = name, storage
			local receiver = newInstance("RemoteEvent")
			receiver.Name, receiver.Parent, receiver.OnClientEvent = "Snapshot", folder, event
			function receiver:FireServer()
				remoteWrites += 1
				error("Client meteorological writes are forbidden")
			end
			local request = newInstance("RemoteFunction")
			request.Name, request.Parent = "GetSnapshot", folder
			function request:InvokeServer(): buffer
				requests += 1
				if newest then
					event:Fire(newest)
				end
				return payload
			end
			return folder
		end
		if not missing then
			channel("WEATHERED_CLOUD_RENDER_DATA", renderEvent, renderPacket(1), renderPacket(2))
			channel(
				"WEATHERED_WORLD_WEATHER",
				diagnosticEvent,
				diagnosticPacket(1),
				diagnosticPacket(2)
			)
		end
		local heartbeat = signal()
		local services = {
			ReplicatedStorage = storage,
			Workspace = workspace,
			RunService = { Heartbeat = heartbeat },
			Lighting = {
				Ambient = roblox.Color3.new(0.4, 0.5, 0.6),
				GetSunDirection = function()
					return roblox.Vector3.new(0.2, 0.9, 0.1)
				end,
			},
			UserInputService = { TouchEnabled = touch == true },
			HttpService = {
				JSONEncode = function()
					return '{"local":true}'
				end,
			},
		}
		local clientRoot, loadClient = createLoader("src/client", {
			game = {
				GetService = function(_self: any, name: string): any
					assert(services[name], "Unexpected service " .. name)
					return services[name]
				end,
			},
			Instance = { new = newInstance },
			workspace = workspace,
			task = {
				spawn = function(callback: any)
					table.insert(queued, callback)
				end,
			},
			print = function() end,
			warn = function(message: string)
				table.insert(warnings, message)
			end,
		})
		local client = loadClient(clientRoot.WorldWeatherClient)
		local stop = client.Start(owner)
		local result = {
			Instances = instances,
			Owner = owner,
			Workspace = workspace,
			Heartbeat = heartbeat,
			RenderEvent = renderEvent,
			DiagnosticEvent = diagnosticEvent,
			Stop = stop,
			Warnings = warnings,
			Queued = queued,
		}
		function result:RunTasks()
			while #queued > 0 do
				table.remove(queued, 1)()
			end
		end
		function result:RequestCount(): number
			return requests
		end
		function result:RemoteWrites(): number
			return remoteWrites
		end

		function result:Control(): any
			return owner:FindFirstChild("CloudVisualControls")
		end
		function result:Stats(): any
			return self:Control():Invoke("cloudrenderstats")
		end
		function result:Frames(count: number)
			for _ = 1, count do
				heartbeat:Fire(0.2)
			end
		end
		return result
	end

	local fixture = setup(false)
	check(
		fixture:Stats().Mode == "Cubes" and fixture:Stats().Quality == "Balanced",
		"Desktop startup chooses real cubic Balanced graphics"
	)
	near(fixture:Stats().ActiveCubes, 0, 0, "No client cloud is invented before receiving weather")
	check(
		fixture:Control().ClassName == "BindableFunction",
		"Visual administration uses a local bindable, not a client weather RemoteEvent"
	)
	fixture:RunTasks()
	near(
		fixture:RequestCount(),
		2,
		0,
		"Late join makes one bounded request per authoritative channel"
	)
	local stats = fixture:Stats()
	near(
		stats.RenderSnapshotsAccepted,
		1,
		0,
		"Live packet arriving during late-join request wins over the older cached response"
	)
	near(stats.RenderSequence, 2, 0, "Late bootstrap cannot roll back current field sequence")
	check(
		stats.Temporal.Complete and stats.DataCompleteness ~= stats.DiagnosticDataCompleteness,
		"Smooth reconstruction explicitly separates complete data from sparse diagnostics"
	)
	fixture:Frames(25)
	stats = fixture:Stats()
	check(
		stats.ActiveCubes > 0,
		"Real renderer produces three-dimensional cloud cubes from received qc"
	)
	check(
		stats.AllocatedInstances <= 1 + 576,
		"Real cube resources remain within the Balanced packed pool cap"
	)
	check(
		fixture.Workspace:FindFirstChild("WEATHERED_WORLD_DEBUG_VOXELS") == nil,
		"Default sky does not create diagnostic grid tiles"
	)
	local cubes = 0
	for _, instance in fixture.Instances do
		check(
			instance.ClassName ~= "BillboardGui"
				and instance.ClassName ~= "ImageLabel"
				and instance.ClassName ~= "ParticleEmitter"
				and instance.ClassName ~= "Beam"
				and instance.ClassName ~= "SurfaceGui",
			"Normal cloud graphics contain no flat visual substitutes"
		)
		if
			instance.Parent
			and instance.Parent.Name == "WEATHERED_CUBIC_CLOUDS"
			and instance.ClassName == "Part"
		then
			cubes += 1
			check(
				instance.Shape == roblox.Enum.PartType.Block
					and instance.CanCollide == false
					and instance.CastShadow == false,
				"Normal cloud geometry is truly cubic, client-only and noncolliding"
			)
			check(
				instance.Size.X == instance.Size.Y
					and instance.Size.Y == instance.Size.Z
					and instance.Size.X <= 48,
				"Every cloud object has equal XYZ dimensions and never exposes a huge weather-grid tile"
			)
		end
	end
	check(cubes > 0, "Geometry checks inspected actual active cube Parts")
	local mobileClient = setup(true)
	mobileClient:RunTasks()
	mobileClient:Frames(25)
	local mobileStats = mobileClient:Stats()
	check(
		mobileStats.Quality == "Mobile"
			and mobileStats.ActiveCubes > 0
			and mobileStats.ActiveCubes <= 256,
		"A second simultaneous client uses a bounded cheaper cubic presentation"
	)
	check(
		mobileStats.RenderSequence == stats.RenderSequence
			and mobileStats.RenderGeneration == stats.RenderGeneration
			and mobileStats.WorldSeed == stats.WorldSeed,
		"Different graphics qualities share the same authoritative weather identity and timeline"
	)
	near(
		mobileStats.LastPacketBytes,
		stats.LastPacketBytes,
		0,
		"Different graphics settings consume the same complete cloud-density packet"
	)
	check(
		mobileStats.DataCompleteness == stats.DataCompleteness,
		"Mobile retains complete density semantics rather than creating a different weather world"
	)
	mobileClient.Stop()
	local count = stats.RenderSnapshotsAccepted
	fixture.RenderEvent:Fire(renderPacket(1))
	near(
		fixture:Stats().RenderSnapshotsAccepted,
		count,
		0,
		"Out-of-order packets cannot replace current client weather"
	)
	fixture.RenderEvent:Fire(buffer.create(3))
	near(
		fixture:Stats().InvalidPacketsRejected,
		1,
		0,
		"Malformed packets are reported and rejected safely"
	)
	local warningCount = #fixture.Warnings
	for _ = 1, 10 do
		fixture.RenderEvent:Fire(buffer.create(3))
	end
	near(
		fixture:Stats().InvalidPacketsRejected,
		11,
		0,
		"All malformed packets are counted even while warnings are throttled"
	)
	near(
		#fixture.Warnings,
		warningCount,
		0,
		"A burst of malformed packets cannot spam developer warnings"
	)
	fixture.RenderEvent:Fire(renderPacket(1, 2, -84219))
	stats = fixture:Stats()
	check(
		stats.RenderGeneration == 2
			and stats.WorldSeed == -84219
			and stats.Temporal.HasPrevious == false,
		"Regeneration clears incompatible interpolation history"
	)
	fixture:Frames(2)
	local controls = fixture:Control()
	-- A complete, finite protocol header can describe an unusably large visual
	-- lattice. This exercises the actual renderer budget and client failure guard,
	-- rather than treating successful packet decoding as an allocation guarantee.
	local oversized = renderPacket(1, 3, -84219)
	buffer.writef32(oversized, 76, 1e8) -- protocol's layer-height slot, STUDS
	check(
		RenderSnapshot.Decode(oversized).Complete,
		"Oversized-geometry fixture is valid complete authoritative render data"
	)
	fixture.RenderEvent:Fire(oversized)
	check(
		pcall(fixture.Frames, fixture, 2),
		"A valid but oversized header cannot throw through the client Heartbeat"
	)
	local failed = fixture:Stats()
	check(
		type(failed.RenderFailure) == "string" and #failed.RenderFailure > 0,
		"Renderer construction failure is reported to local diagnostics"
	)
	check(
		failed.Enabled == false and failed.ActiveCubes == 0,
		"Failed geometry disables local cubes and releases visible resources"
	)
	check(
		failed.LODStorageBytes <= 262144 and failed.AllocatedInstances <= 577,
		"Oversized geometry is rejected before a giant lattice or Part allocation"
	)
	local afterFailure = #fixture.Instances
	fixture:Frames(5)
	near(
		#fixture.Instances,
		afterFailure,
		0,
		"A stopped failed renderer cannot repeatedly allocate on later frames"
	)
	for name, values in field.Fields do
		check(
			buffer.tostring(values) == before[name],
			"Local renderer failure cannot alter authoritative " .. name
		)
	end
	check(
		type(controls:Invoke("cloudrender cubes")) == "string",
		"Developers can explicitly retry a stopped local renderer"
	)
	check(
		fixture:Stats().RenderFailure == nil,
		"Explicit visual retry clears the stored failure before retrying"
	)
	check(
		pcall(fixture.Frames, fixture, 1) and fixture:Stats().RenderFailure ~= nil,
		"Retrying invalid geometry remains bounded and reports the same failure"
	)
	fixture.RenderEvent:Fire(renderPacket(1, 4, -84219))
	fixture:Frames(25)
	local recovered = fixture:Stats()
	check(
		recovered.RenderFailure == nil and recovered.Enabled and recovered.ActiveCubes > 0,
		"A normal new weather generation recovers rendering after rejected geometry"
	)
	near(
		recovered.RenderGeneration,
		4,
		0,
		"Recovered client preserves the current authoritative generation identity"
	)
	for _, command in
		{
			"clouddebug density",
			"clouddebug gradients",
			"clouddebug bounds",
			"clouddebug off",
			"cloudrender smooth",
			"cloudrender cubes",
			"cloudquality mobile",
			"cloudquality high",
			"cloudquality ultra",
			"cloudquality balanced",
		}
	do
		check(type(controls:Invoke(command)) == "string", "Local visual command works: " .. command)
	end
	check(
		type(controls:Invoke("cloudsnapshots")) == "table",
		"Snapshot diagnostics are available locally"
	)
	check(
		controls:Invoke("wind 8 2").Error ~= nil,
		"Local visual controls cannot change server wind"
	)
	check(
		controls:Invoke("seed 12").Error ~= nil,
		"Local visual controls cannot change server world seed"
	)
	check(
		controls:Invoke("cloudquality invalid").Error ~= nil,
		"Invalid quality produces a meaningful failure"
	)
	check(
		controls:Invoke("cloudrender").Error ~= nil,
		"Invalid command arity produces a meaningful failure"
	)
	check(
		fixture:Stats().Mode == "Cubes" and fixture:Stats().Quality == "Balanced",
		"Rejected local commands preserve active visual settings"
	)
	fixture.Owner:SetAttribute("CloudRenderCommand", "cloudrender off")
	check(
		fixture.Owner:GetAttribute("CloudRenderCommand") == "",
		"Attribute commands are consumed once"
	)
	check(
		type(fixture.Owner:GetAttribute("LastCloudRenderMessage")) == "string",
		"Developer feedback is exposed on the local script"
	)
	fixture:Frames(2)
	check(
		fixture:Stats().Mode == "Off" and fixture:Stats().ActiveCubes == 0,
		"Off mode immediately releases active cubic visuals"
	)
	controls:Invoke("cloudrender voxels")
	fixture:Frames(3)
	local diagnosticFolder = fixture.Workspace:FindFirstChild("WEATHERED_WORLD_DEBUG_VOXELS")
	check(
		diagnosticFolder ~= nil,
		"Explicit voxel mode preserves production legacy diagnostics: "
			.. table.concat(fixture.Warnings, "\n")
	)
	local visibleVoxels = 0
	for _, instance in diagnosticFolder.Children do
		if string.sub(instance.Name or "", 1, 8) == "WorldQc_" and instance.Transparency < 1 then
			visibleVoxels += 1
		end
	end
	check(
		visibleVoxels > 0,
		"Local voxel mode can inspect valid diagnostic cells even when server default-debug flag is false"
	)
	controls:Invoke("cloudrender smooth")
	fixture:Frames(3)
	for _, instance in diagnosticFolder.Children do
		check(instance.Transparency == 1, "Cubic mode hides coarse diagnostic Parts")
	end
	fixture.DiagnosticEvent:Fire(diagnosticPacket(3, true, true))
	fixture:Frames(2)
	local regionLines = 0
	for _, instance in diagnosticFolder.Children do
		if
			string.match(instance.Name or "", "^WeatherRegionBorder_")
			and instance.Transparency < 1
		then
			regionLines += 1
		end
	end
	near(
		regionLines,
		10,
		0,
		"Cubic mode can show bounded region lines without displaying giant voxel cells"
	)
	controls:Invoke("cloudrender hybriddebug")
	fixture:Frames(3)
	check(fixture:Stats().Mode == "HybridDebug", "Hybrid mode is an explicit local choice")
	local vectorLines = 0
	for _, instance in diagnosticFolder.Children do
		if string.match(instance.Name or "", "^WeatherVelocity_") and instance.Transparency < 1 then
			vectorLines += 1
		end
	end
	check(
		vectorLines > 0 and vectorLines <= 16,
		"Hybrid debugging preserves bounded production wind vectors"
	)
	near(
		fixture:RemoteWrites(),
		0,
		0,
		"All client controls and modes remain read-only on weather channels"
	)
	fixture.Stop()
	fixture.Stop()
	near(fixture.Heartbeat:Count(), 0, 0, "Shutdown disconnects the update listener idempotently")
	near(fixture.RenderEvent:Count(), 0, 0, "Shutdown disconnects complete render snapshots")
	near(fixture.DiagnosticEvent:Count(), 0, 0, "Shutdown disconnects sparse diagnostic snapshots")
	check(
		fixture.Owner:FindFirstChild("CloudVisualControls") == nil,
		"Shutdown destroys local developer control ownership"
	)
	check(
		fixture.Workspace:FindFirstChild("WEATHERED_CUBIC_CLOUDS") == nil
			and fixture.Workspace:FindFirstChild("WEATHERED_WORLD_DEBUG_VOXELS") == nil,
		"Shutdown releases both client geometry pools"
	)
	local instancesAfterStop = #fixture.Instances
	fixture.RenderEvent:Fire(renderPacket(3))
	fixture.Heartbeat:Fire(1)
	near(
		#fixture.Instances,
		instancesAfterStop,
		0,
		"Stopped clients cannot recreate resources from late packets"
	)

	local earlyStop = setup(true)
	check(
		earlyStop:Stats().Quality == "Mobile",
		"Touch-capable startup selects the cheaper Mobile profile"
	)
	earlyStop.Stop()
	earlyStop:RunTasks()
	near(
		earlyStop:RequestCount(),
		0,
		0,
		"Stopping before queued subscriptions avoids late-join network work"
	)
	near(
		earlyStop.RenderEvent:Count(),
		0,
		0,
		"Late queued subscription cannot leak a listener after shutdown"
	)
	near(earlyStop.Heartbeat:Count(), 0, 0, "Early shutdown releases heartbeat ownership")
	check(
		earlyStop.Workspace:FindFirstChild("WEATHERED_CUBIC_CLOUDS") == nil,
		"Late subscription tasks cannot resurrect destroyed clouds"
	)
	local missing = setup(false, true)
	missing:RunTasks()
	missing:Frames(2)
	near(
		missing:RequestCount(),
		0,
		0,
		"Missing server channels do not cause unbounded polling or requests"
	)
	near(
		missing:Stats().ActiveCubes,
		0,
		0,
		"Missing authority data never displays fabricated clouds"
	)
	missing.Stop()
	for name, values in field.Fields do
		check(
			buffer.tostring(values) == before[name],
			"Client graphics, commands and packet handling never mutate authoritative " .. name
		)
	end
	return {
		NativeClientCases = 4,
		LateJoinRequests = 2,
		ClientMeteorologicalWrites = 0,
		InvalidPacketsRejected = 11,
		StudioVisualValidation = false,
	}
end
