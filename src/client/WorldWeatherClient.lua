--!strict

-- Local visual ownership only: both server channels are read-only.
local Storage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local Input = game:GetService("UserInputService")
local Http = game:GetService("HttpService")
local Root = Storage.Shared.Atmosphere
local Diagnostic = require(Root.World.WeatherSnapshot)
local Voxels = require(Root.World.WorldVoxelDebugRenderer)
local Snapshot = require(Root.Rendering.CloudRenderSnapshot)
local Reconstruction = require(Root.Rendering.CloudDensityReconstruction)
local Config = require(Root.Rendering.CloudRenderConfig)
local Renderer = require(script.Parent.Rendering.CloudRenderer)
local Client = {}

function Client.Start(owner: LocalScript?): () -> ()
	local alive = true
	local connections: { RBXScriptConnection } = {}
	local function attribute(name: string, fallback: string): string
		local value = if owner then owner:GetAttribute(name) else nil
		assert(value == nil or typeof(value) == "string", name .. " must be a string")
		return if value == nil then fallback else value :: string
	end
	local mode = Config.ValidateMode(attribute("CloudRenderMode", "Cubes"))
	local name = attribute("CloudQuality", "Auto")
	if string.lower(name) == "auto" then
		name = if Input.TouchEnabled then "Mobile" else "Balanced"
	end
	local quality = Config.GetQuality(name)
	local reconstruction = Reconstruction.new()
	local cubic = Renderer.new(reconstruction, { Quality = quality.Name })
	cubic:SetEnabled(mode == "Cubes" or mode == "HybridDebug")
	local voxels: any = nil
	local previous: any, current: any = nil, nil
	local receipt, interval, accumulator = 0, 1, 0
	local accepted, rejected, packetBytes, decodeMilliseconds = 0, 0, 0, 0
	local renderFailure: string? = nil
	local lastWarning = -math.huge
	local function warning(message: string)
		if os.clock() - lastWarning >= 5 then
			lastWarning = os.clock()
			warn("[WEATHERED clouds] " .. message)
		end
	end
	local function acceptRender(payload: any)
		if not alive then
			return
		end
		local started = os.clock()
		local ok, decoded = pcall(Snapshot.Decode, payload)
		decodeMilliseconds = (os.clock() - started) * 1000
		if not ok then
			rejected += 1
			warning("Invalid render packet: " .. tostring(decoded))
			return
		end
		local old = reconstruction.Current
		if reconstruction:Push(decoded, os.clock()) then
			accepted += 1
			packetBytes = buffer.len(payload)
			if renderFailure and (not old or not Snapshot.Compatible(old, decoded)) then
				renderFailure = nil
				cubic:SetEnabled(mode == "Cubes" or mode == "HybridDebug")
			end
		end
	end
	local function acceptDiagnostic(payload: any)
		if not alive then
			return
		end
		local ok, decoded = pcall(Diagnostic.Decode, payload)
		if not ok then
			warning("Invalid diagnostic packet: " .. tostring(decoded))
			return
		end
		if not Diagnostic.IsNewer(current, decoded) then
			return
		end
		decoded = table.clone(decoded) -- codec metadata is frozen; local debug flags need a private descriptor
		if current and Diagnostic.Compatible(current, decoded) and decoded.Time >= current.Time then
			previous, interval = current, math.clamp(decoded.WallTime - current.WallTime, 0.25, 4)
		else
			previous, interval = decoded, 1
		end
		-- Decoded summaries are client-owned; explicit local voxel mode is allowed
		-- even when server debug is disabled. No atmospheric buffer is touched.
		decoded.DebugEnabled = true
		current, receipt = decoded, os.clock()
		if voxels then
			voxels:SetLimit(decoded.Limit)
		end
	end
	local function subscribe(channelName: string, accept: (any) -> ())
		task.spawn(function()
			if not alive then
				return
			end
			local folder = Storage:WaitForChild(channelName, 30)
			if not alive then
				return
			end
			if not folder then
				warning(channelName .. " unavailable; waiting for authoritative weather")
				return
			end
			local event = folder:WaitForChild("Snapshot", 10) :: RemoteEvent?
			local request = folder:WaitForChild("GetSnapshot", 10) :: RemoteFunction?
			if not alive or not event or not request then
				return
			end
			table.insert(connections, event.OnClientEvent:Connect(accept))
			-- Subscribe before the request: late responses cannot replace live data.
			local ok, payload = pcall(function()
				return request:InvokeServer()
			end)
			if alive and ok and payload then
				accept(payload)
			end
		end)
	end
	subscribe("WEATHERED_CLOUD_RENDER_DATA", acceptRender)
	subscribe("WEATHERED_WORLD_WEATHER", acceptDiagnostic)
	local cameraInfo = { X = 0, Y = 70, Z = 0, LookX = 0, LookY = 0, LookZ = -1 }
	local lightingInfo = { SunX = 0, SunY = 1, SunZ = 0, Ambient = 0.5 }
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(dt: number)
			if not alive then
				return
			end
			local now, camera = os.clock(), Workspace.CurrentCamera
			if camera then
				local p, look = camera.CFrame.Position, camera.CFrame.LookVector
				cameraInfo.X, cameraInfo.Y, cameraInfo.Z = p.X, p.Y, p.Z
				cameraInfo.LookX, cameraInfo.LookY, cameraInfo.LookZ = look.X, look.Y, look.Z
			end
			local sun, ambient = Lighting:GetSunDirection(), Lighting.Ambient
			lightingInfo.SunX, lightingInfo.SunY, lightingInfo.SunZ = sun.X, sun.Y, sun.Z
			lightingInfo.Ambient = (ambient.R + ambient.G + ambient.B) / 3
			if not renderFailure and (mode == "Cubes" or mode == "HybridDebug") then
				local ok, problem = pcall(cubic.Update, cubic, now, dt, cameraInfo, lightingInfo)
				if not ok then
					renderFailure = tostring(problem)
					cubic:SetEnabled(false)
					warning("Local cube renderer stopped: " .. renderFailure)
					if owner then
						owner:SetAttribute("LastCloudRenderMessage", renderFailure)
					end
				end
			end
			accumulator += dt
			if accumulator < 0.2 then
				return
			end
			accumulator %= 0.2
			if current and (mode == "Voxels" or mode == "HybridDebug") then
				if not voxels then
					voxels = Voxels.new(current.Limit)
				end
				voxels:Update(previous or current, current, math.min(1, (now - receipt) / interval))
			elseif voxels then
				voxels:Hide()
				if current and mode == "Cubes" then
					voxels:UpdateRegions(current)
				end
			elseif current and current.DebugRegions and mode == "Cubes" then
				voxels = Voxels.new(current.Limit)
				voxels:UpdateRegions(current)
			end
		end)
	)
	local function stats(): any
		local result = cubic:GetDiagnostics()
		result.Mode = mode
		result.RenderFailure = renderFailure
		result.Geometry = "PartType.Block; equal X/Y/Z dimensions"
		result.RenderSnapshotsAccepted, result.InvalidPacketsRejected = accepted, rejected
		result.LastPacketBytes, result.LastDecodeMilliseconds = packetBytes, decodeMilliseconds
		result.DataCompleteness = "complete quantized qc and coarse velocity"
		result.DiagnosticDataCompleteness = "cropped; excluded from cubic reconstruction"
		local metadata = reconstruction.Current
		result.RenderGeneration = if metadata then metadata.Generation else -1
		result.RenderSequence = if metadata then metadata.Sequence else -1
		result.WorldSeed = if metadata then metadata.Seed else 0
		result.Temporal = reconstruction:GetDiagnostics(os.clock())
		result.Temporal.HasPrevious = reconstruction.Previous ~= nil
		-- Reports must be JSON-safe; binary packets stay in reconstruction.
		result.Temporal.Snapshot, result.Temporal.Previous = nil, nil
		return result
	end
	local function execute(text: string): any
		assert(
			type(text) == "string" and #text <= 256,
			"Visual command must be a string of at most 256 characters"
		)
		local words = {}
		for word in string.gmatch(text, "%S+") do
			table.insert(words, string.lower(word))
		end
		local command = words[1]
		if command == "cloudrender" then
			assert(
				#words == 2,
				"Usage: cloudrender cubes|voxels|hybriddebug|off (smooth is a compatibility alias)"
			)
			mode = Config.ValidateMode(words[2])
			renderFailure = nil
			cubic:SetEnabled(mode == "Cubes" or mode == "HybridDebug")
			if voxels then
				voxels:Hide()
			end
			return "Local cloud rendering: " .. mode
		elseif command == "cloudquality" then
			assert(#words == 2, "Usage: cloudquality mobile|balanced|high|ultra")
			quality = Config.GetQuality(words[2])
			cubic:SetQuality(quality.Name)
			return "Local cloud quality: " .. quality.Name
		elseif command == "clouddebug" then
			assert(#words == 2, "Usage: clouddebug density|gradients|bounds|off")
			cubic:SetDebugMode(if words[2] == "off" then "None" else words[2])
			return "Local cloud debug: " .. words[2]
		elseif command == "cloudrenderstats" or command == "cloudsnapshots" then
			assert(#words == 1, "Diagnostic command takes no arguments")
			return stats()
		end
		error(
			"Unknown local visual command. Use cloudrender, cloudquality, clouddebug, cloudrenderstats or cloudsnapshots.",
			2
		)
	end
	local function commandResult(text: string): any
		local ok, result = pcall(execute, text)
		local message = tostring(result)
		if ok and type(result) == "table" then
			local encoded, json = pcall(Http.JSONEncode, Http, result)
			if encoded then
				message = json
			end
		end
		if owner then
			owner:SetAttribute("LastCloudRenderMessage", message)
		end
		if ok then
			print("[WEATHERED clouds]", message)
		else
			warning(message)
		end
		return if ok then result else { Error = message }
	end
	local bindable: BindableFunction? = nil
	if owner then
		bindable = Instance.new("BindableFunction")
		bindable.Name = "CloudVisualControls"
		bindable.OnInvoke, bindable.Parent = commandResult, owner
		table.insert(
			connections,
			owner:GetAttributeChangedSignal("CloudRenderCommand"):Connect(function()
				local text = owner:GetAttribute("CloudRenderCommand")
				if text == nil or text == "" then
					return
				end
				owner:SetAttribute("CloudRenderCommand", "")
				commandResult(text)
			end)
		)
	end
	return function()
		if not alive then
			return
		end
		alive = false
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		if bindable then
			bindable:Destroy()
		end
		if voxels then
			voxels:Destroy()
		end
		cubic:Destroy()
		reconstruction:Reset()
	end
end

return table.freeze(Client)
