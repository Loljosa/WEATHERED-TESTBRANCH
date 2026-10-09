--!strict

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local createLoader = require("./RobloxModuleLoader")

-- Execute the real bootstrap and control modules. Only Roblox signal/Instance
-- plumbing and the already separately tested renderer are substituted.
return function(atmosphereRoot: any, check: any, near: any, rejects: any)
	local function signal(): any
		local listeners = {}
		return {
			Connect = function(_self: any, callback: any): any
				local connection = { Connected = true, Callback = callback }
				function connection:Disconnect()
					self.Connected = false
				end
				table.insert(listeners, connection)
				return connection
			end,
			Fire = function(_self: any, ...: any)
				for _, connection in listeners do
					if connection.Connected then
						connection.Callback(...)
					end
				end
			end,
		}
	end
	local heartbeat = signal()
	local game = {
		GetService = function(_self: any, name: string): any
			if name == "RunService" then
				return { Heartbeat = heartbeat }
			end
			assert(name == "ReplicatedStorage")
			return { Shared = { Atmosphere = atmosphereRoot } }
		end,
	}
	local warnings = {}
	local serverRoot, loadServer = createLoader("src/server", {
		game = game,
		print = function() end,
		warn = function(message: string)
			table.insert(warnings, message)
		end,
	})
	local attributes =
		serde.decode("json", fs.readFile("src/server/WeatherServer.meta.json")).attributes
	local attributeSignals = {}
	local fakeScript = { Parent = serverRoot }
	function fakeScript:GetAttribute(name: string): any
		return attributes[name]
	end
	function fakeScript:GetAttributeChangedSignal(name: string): any
		if not attributeSignals[name] then
			attributeSignals[name] = signal()
		end
		return attributeSignals[name]
	end
	function fakeScript:SetAttribute(name: string, value: any)
		if attributes[name] ~= value then
			attributes[name] = value
			self:GetAttributeChangedSignal(name):Fire()
		end
	end
	function fakeScript:FindFirstChild(_name: string): any
		return nil
	end
	local endpoint: any = nil
	local instance = {
		new = function(class: string): any
			check(
				class == "BindableFunction",
				"Bootstrap creates a server BindableFunction, not a RemoteEvent"
			)
			endpoint = { ClassName = class }
			function endpoint:Invoke(...: any): any
				return self.OnInvoke(...)
			end
			return endpoint
		end,
	}
	local renderedState = nil
	local renderer = {
		Render = function(state: any): number
			renderedState = state
			return 0
		end,
	}
	local requireModule = function(node: any): any
		if node == serverRoot.Debug.VoxelDebugRenderer then
			return renderer
		end
		return loadServer(node)
	end
	local execute = luau.load(
		"return function(script, game, require, Instance, print, warn)\n"
			.. fs.readFile("src/server/WeatherServer.server.lua")
			.. "\nend",
		{ codegenEnabled = true }
	)()
	execute(fakeScript, game, requireModule, instance, function() end, function(message: string)
		table.insert(warnings, message)
	end)
	local controller = loadServer(serverRoot.Simulation.SimulationController)
	check(endpoint.Parent == fakeScript, "Developer endpoint is owned by the server Script")
	local initialState = controller.GetState()
	check(renderedState == initialState, "Bootstrap renders initial authoritative state")
	fakeScript:SetAttribute("WeatherCommand", "wind 8 2")
	near(attributes.BackgroundU, 8, 0, "Attribute command synchronizes live X wind")
	near(attributes.BackgroundV, 2, 0, "Attribute command synchronizes live Z wind")
	check(attributes.WeatherCommand == "", "Command input clears for repeated commands")
	fakeScript:SetAttribute("WeatherCommand", "wind 31 0")
	check(
		#warnings == 1 and string.find(warnings[1], "command rejected", 1, true) ~= nil,
		"Invalid attribute command warns without stopping physics"
	)
	near(attributes.BackgroundU, 8, 0, "Rejected command preserves previous settings")
	fakeScript:SetAttribute("WeatherCommand", "spawn Wide Fast")
	check(controller.GetState() ~= initialState, "Attribute spawn changes authoritative state")
	check(attributes.CloudShape == "Wide", "Spawn synchronizes the shape attribute")
	near(attributes.BubbleTemperaturePerturbation, 8, 0, "Spawn synchronizes thermal settings")
	heartbeat:Fire(1)
	check(
		renderedState == controller.GetState(),
		"Later renders use replacement state instead of stale initial state"
	)
	check(controller.GetTime() > 0, "Physics continues after a rejected command")
	fakeScript:SetAttribute("SimulationSpeed", 2)
	heartbeat:Fire(0.125)
	near(
		controller.GetDiagnostics().SimulationSpeed,
		2,
		0,
		"Existing live playback attribute still works"
	)
	endpoint:Invoke("pause")
	local pausedTime = controller.GetTime()
	heartbeat:Fire(1)
	near(controller.GetTime(), pausedTime, 0, "Bindable pause is connected to production Heartbeat")
	endpoint:Invoke("form", 1)
	heartbeat:Fire(0.125)
	near(
		controller.GetTime(),
		pausedTime + 0.25,
		0,
		"Bindable formation resumes bounded real physics"
	)
	check(
		type(endpoint:Invoke("status")) == "table",
		"Bindable status exercises production diagnostic printing"
	)
	fakeScript:SetAttribute("WeatherCommand", "status")
	check(
		attributes.LastWeatherMessage == "Diagnostics printed in Output",
		"Attribute status produces a useful response"
	)
	fakeScript:SetAttribute("WeatherCommand", "help")
	check(
		string.find(attributes.LastWeatherMessage, "spawn", 1, true) ~= nil,
		"Help is available without the Command Bar"
	)
	buffer.writef32(controller.GetState().Fields.theta, 0, 0 / 0)
	heartbeat:Fire(0.25)
	local stoppedTime = controller.GetTime()
	heartbeat:Fire(1)
	near(
		controller.GetTime(),
		stoppedTime,
		0,
		"Bootstrap disconnects Heartbeat after numerical failure"
	)
	rejects(function()
		endpoint:Invoke("reset")
	end, "Stopped engine requires restart rather than silently running commands")
	print(
		"PASS: real WeatherServer attribute/Bindable commands, replacement render state, live speed, status and failure shutdown"
	)
end
