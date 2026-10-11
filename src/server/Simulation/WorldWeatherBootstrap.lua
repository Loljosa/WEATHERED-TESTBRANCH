--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local Root = ReplicatedStorage.Shared.Atmosphere
local WorldSeed = require(Root.Generation.WorldSeed)
local Controller = require(script.Parent.WorldWeatherController)
local Controls = require(script.Parent.WorldWeatherControls)
local Replication = require(script.Parent.WeatherReplication)
local Bootstrap = {}

function Bootstrap.Start(weatherScript: Script)
	local function number(name: string, fallback: number): number
		local value = weatherScript:GetAttribute(name)
		if value == nil then
			return fallback
		end
		assert(
			typeof(value) == "number" and value == value and math.abs(value :: number) < math.huge,
			name .. " must be finite numeric"
		)
		return value :: number
	end
	local function text(name: string, fallback: string): string
		local value = weatherScript:GetAttribute(name)
		assert(value == nil or typeof(value) == "string", name .. " must be a string")
		return if value == nil then fallback else value :: string
	end
	local function boolean(name: string, fallback: boolean): boolean
		local value = weatherScript:GetAttribute(name)
		assert(value == nil or typeof(value) == "boolean", name .. " must be boolean")
		return if value == nil then fallback else value :: boolean
	end
	assert(number("WorldSizeStuds", 4028) == 4028, "WorldSizeStuds must be exactly 4028")
	local canonical = Workspace:GetAttribute("WorldSeed")
	local seed, seedSource =
		WorldSeed.Resolve(canonical, if canonical == nil then number("WorldSeed", 84219) else nil)
	local count = number("CloudSourceCount", 0)
	local controller = Controller.new({
		Seed = seed,
		SeedSource = seedSource,
		Preset = text("PerformancePreset", "Laptop"),
		Coverage = text("CloudCoverage", "Scattered"),
		Boundary = text("WorldBoundary", "Periodic"),
		InitialSourceCount = if count == 0 then nil else count,
		BackgroundU = number("BackgroundU", 2),
		BackgroundV = number("BackgroundV", 1),
		ShearU = number("ShearU", 0),
		ShearV = number("ShearV", 0),
		SourceIntensity = number("SourceIntensity", 1),
		AutoClouds = boolean("AutoClouds", true),
		Speed = number("SimulationSpeed", 1),
		Coordinates = {
			CenterX = number("WorldCenterXStuds", 0),
			CenterZ = number("WorldCenterZStuds", 0),
			StudsPerMeter = number("StudsPerMeter", 2),
			BottomStuds = number("CloudBottomStuds", 424),
			BaseAltitudeMeters = number("BaseAltitudeMeters", 1000),
			HeightMeters = number("WorldHeightMeters", 72),
		},
	})
	local controls = Controls.new(controller)
	local full = controller.Options.Preset == "Full"
	local replication = Replication.new(controller.Field, {
		Seed = seed,
		MaxRecords = if full then 512 else 256,
		RateHz = if full then 2 else 1,
		DebugRegions = false,
		DebugVectors = false,
		Threshold = 1e-5, -- liquid diagnostic threshold, not a physics source.
		DebugEnabled = boolean("WorldDebugEnabled", RunService:IsStudio()),
		DroppedTime = function(): number
			return controller.DroppedSimulationTime
		end,
	})
	local replicatedField = controller.Field
	local function resultMessage(result: any): string
		if type(result) == "table" then
			local ok, encoded = pcall(HttpService.JSONEncode, HttpService, result)
			return if ok
				then encoded
				else "Diagnostic result returned; use the server BindableFunction to inspect it."
		end
		return tostring(result)
	end
	local function execute(command: string, ...: any): any
		local result = controls:Execute(command, ...)
		weatherScript:SetAttribute("LastWeatherMessage", resultMessage(result))
		print("[WEATHERED world]", resultMessage(result))
		return result
	end
	local function synchronizeReplication()
		if replicatedField ~= controller.Field then
			replication:SetField(controller.Field, controller.Options.Seed)
			replicatedField = controller.Field
		end
		replication:SetDebugFlags(controller.DebugRegions, controller.DebugVectors)
	end
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "WeatherControls"
	bindable.OnInvoke = function(command: string, ...: any): any
		local result = execute(command, ...)
		synchronizeReplication()
		return result
	end
	bindable.Parent = weatherScript
	local commandConnection = weatherScript
		:GetAttributeChangedSignal("WeatherCommand")
		:Connect(function()
			local command = weatherScript:GetAttribute("WeatherCommand")
			if command == nil or command == "" then
				return
			end
			weatherScript:SetAttribute("WeatherCommand", "")
			local ok, result = pcall(controls.ExecuteText, controls, command)
			weatherScript:SetAttribute("LastWeatherMessage", resultMessage(result))
			if ok then
				synchronizeReplication()
				print("[WEATHERED world]", resultMessage(result))
			else
				warn("[WEATHERED world] command rejected:", result)
			end
		end)
	local speedConnection = weatherScript
		:GetAttributeChangedSignal("SimulationSpeed")
		:Connect(function()
			local ok, value = pcall(function(): number
				return Controller.ValidateSpeed(number("SimulationSpeed", 1))
			end)
			if ok then
				controller.Speed = value
			else
				warn(value)
			end
		end)
	local diagnosticTime = 0
	local heartbeat: RBXScriptConnection?
	heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		local ok, problem = pcall(function()
			controller:Advance(dt)
			synchronizeReplication()
			replication:Update(dt)
		end)
		if not ok then
			if heartbeat then
				heartbeat:Disconnect()
			end
			warn("[WEATHERED world] stopped on numerical/runtime failure:", problem)
			weatherScript:SetAttribute("LastWeatherMessage", tostring(problem))
			return
		end
		diagnosticTime += dt
		if diagnosticTime >= 10 then
			diagnosticTime %= 10
			local d = controller:GetDiagnostics()
			print(
				string.format(
					"[WEATHERED world] t=%.2fs wall=%.2fs clouds=%d dropped=%d steps; %dx%dx%d cells, 16 logical regions",
					controller.Field.Time,
					controller.WallTime,
					d.CloudCells or 0,
					controller.DroppedSteps,
					controller.Field.SizeX,
					controller.Field.SizeY,
					controller.Field.SizeZ
				)
			)
		end
	end)
	print(
		"[WEATHERED] World atmosphere initialized: exactly 4028 x 4028 studs; single server field; local MAC detail disabled by default."
	)
	local stopped = false
	local destroyingConnection: RBXScriptConnection?
	local function stop()
		if stopped then
			return
		end
		stopped = true
		if heartbeat then
			heartbeat:Disconnect()
		end
		commandConnection:Disconnect()
		speedConnection:Disconnect()
		if destroyingConnection then
			destroyingConnection:Disconnect()
		end
		replication:Destroy()
		bindable:Destroy()
	end
	destroyingConnection = weatherScript.Destroying:Connect(stop)
	return { Controller = controller, Replication = replication, Stop = stop }
end
return Bootstrap
