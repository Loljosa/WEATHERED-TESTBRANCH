--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Atmosphere = require(ReplicatedStorage.Shared.Atmosphere)
local Controller = require(script.Parent.SimulationController)
local WorldSeed = require(ReplicatedStorage.Shared.Atmosphere.Generation.WorldSeed)

local CloudControls = {}
CloudControls.__index = CloudControls

export type CloudControls = typeof(setmetatable(
	{} :: {
		Config: Atmosphere.Config,
		SetSpeed: (number) -> (),
		SettingsChanged: (Atmosphere.Config) -> (),
		Generation: Controller.GenerationOptions,
	},
	CloudControls
))

local SHAPES: { [string]: string } = { round = "Round", wide = "Wide", tower = "Tower" }
local FORMATION: { [string]: { Temperature: number, Humidity: number } } = {
	normal = { Temperature = 6, Humidity = 0.999 },
	fast = { Temperature = 8, Humidity = 0.9999 },
}

local function number(value: any, label: string): number
	local result = if type(value) == "number"
		then value
		else if type(value) == "string" then tonumber(value) else nil
	assert(
		result ~= nil and result == result and math.abs(result) < math.huge,
		label .. " must be a finite number"
	)
	return result :: number
end

local function shape(value: any): string
	assert(type(value) == "string", "Shape must be Round, Wide or Tower")
	local selected = SHAPES[string.lower(value)]
	assert(selected ~= nil, "Shape must be Round, Wide or Tower")
	return selected
end

function CloudControls.new(
	config: Atmosphere.Config,
	setSpeed: (number) -> (),
	settingsChanged: (Atmosphere.Config) -> (),
	generation: Controller.GenerationOptions?
): CloudControls
	return setmetatable({
		Config = table.clone(config),
		SetSpeed = setSpeed,
		SettingsChanged = settingsChanged,
		Generation = table.clone(generation or {
			Seed = 84219,
			InitialSourceCount = 2,
			MaxInitialSources = 4,
			AutoClouds = true,
			SeedSource = "DevelopmentFallback",
		}),
	}, CloudControls)
end

function CloudControls:Spawn(selectedShape: any?, formation: any?, scale: any?): string
	local nextConfig = table.clone(self.Config)
	if selectedShape ~= nil then
		nextConfig.BubbleShape = shape(selectedShape)
	end
	if scale ~= nil then
		local value = number(scale, "Size")
		assert(value >= 0.5 and value <= 1.5, "Size must be 0.5..1.5")
		nextConfig.BubbleScale = value
	end
	if formation ~= nil then
		assert(type(formation) == "string", "Formation must be Normal or Fast")
		local preset = FORMATION[string.lower(formation)]
		assert(preset ~= nil, "Formation must be Normal or Fast")
		nextConfig.BubbleTemperaturePerturbation = preset.Temperature
		nextConfig.BubbleRelativeHumidity = preset.Humidity
	end
	Controller.Restart(nextConfig)
	self.Config = nextConfig
	self.SettingsChanged(nextConfig)
	return string.format(
		"Started clear %s warm/moist cloud source, size %.2fx; theta excess %.1f K, RH %.4f. Cloud water will condense as it evolves.",
		nextConfig.BubbleShape or "Round",
		nextConfig.BubbleScale or 1,
		nextConfig.BubbleTemperaturePerturbation or 2,
		nextConfig.BubbleRelativeHumidity or 0.98
	)
end

-- Called by a server-only BindableFunction or the developer Script attribute.
-- No RemoteEvent, chat hook, loadstring, client authority or per-step parsing.
function CloudControls:Execute(command: string, ...: any): any
	assert(type(command) == "string", "Weather command must be a string")
	local args = table.pack(...)
	local selected = string.lower(command)
	local expected = if selected == "spawn"
		then 3
		else if selected == "wind"
			then 2
			else if selected == "speed"
					or selected == "form"
					or selected == "condensation"
					or selected == "size"
					or selected == "seed"
					or selected == "cloudcount"
					or selected == "autoclouds"
				then 1
				else 0
	assert(args.n <= expected, "Too many weather command arguments")
	if selected == "seed" then
		local selectedSeed = WorldSeed.Validate(number(args[1], "World seed"))
		self.Generation.Seed = selectedSeed
		self.Generation.SeedSource = "DeveloperCommand"
		return string.format(
			"Next seeded initialization uses world seed %d. Use regenerate to apply it; the running atmosphere is unchanged.",
			selectedSeed
		)
	elseif selected == "cloudcount" then
		local count = number(args[1], "Cloud count")
		local limit = self.Generation.MaxInitialSources or 4
		assert(
			count % 1 == 0 and count >= 1 and count <= limit,
			string.format("Cloud count must be an integer from 1 to %d for this preset", limit)
		)
		self.Generation.InitialSourceCount = count
		return string.format(
			"Next seeded initialization has %d source regions. Use regenerate to apply it; existing clouds are unchanged.",
			count
		)
	elseif selected == "regenerate" then
		Controller.Regenerate(self.Config, self.Generation)
		return string.format(
			"Regenerated a clear seeded atmosphere: seed %d, %d warm/moist regions. Cloud water will form through microphysics.",
			self.Generation.Seed,
			self.Generation.InitialSourceCount or 2
		)
	elseif selected == "spawnseeded" then
		local id = Controller.SpawnSeeded()
		return "Queued deterministic source "
			.. id
			.. "; existing fields and simulation time are preserved. Source geometry is built over bounded fixed steps."
	elseif selected == "autoclouds" then
		assert(type(args[1]) == "string", "Use autoclouds on or autoclouds off")
		local setting = string.lower(args[1])
		assert(setting == "on" or setting == "off", "Use autoclouds on or autoclouds off")
		local enabled = setting == "on"
		Controller.SetAutoClouds(enabled)
		self.Generation.AutoClouds = enabled
		return if enabled
			then "Scheduled source formation enabled."
			else "New scheduled sources disabled; already queued sources and existing atmospheric clouds continue evolving."
	elseif selected == "seedstatus" then
		local status = Controller.GetSeedStatus()
		status.NextWorldSeed = self.Generation.Seed
		status.NextSeedSource = self.Generation.SeedSource or "Configured"
		status.NextInitialSourceCount = self.Generation.InitialSourceCount or 2
		status.MaximumInitialSourceCount = self.Generation.MaxInitialSources or 4
		status.NextSourceIntensity = self.Generation.SourceIntensity or 1
		status.NextAutoClouds = if self.Generation.AutoClouds == nil
			then true
			else self.Generation.AutoClouds
		return status
	elseif selected == "wind" then
		local u, v = number(args[1], "Wind U"), number(args[2], "Wind V")
		Controller.SetWind(u, v)
		self.Config.BackgroundU, self.Config.BackgroundV = u, v
		self.SettingsChanged(self.Config)
		return string.format(
			"Live physical wind: X %.2f, Z %.2f m/s. Existing cloud water is transported by the model.",
			u,
			v
		)
	elseif selected == "speed" then
		local value = Controller.ValidateSpeed(number(args[1], "Speed"))
		self.SetSpeed(value)
		return string.format(
			"Weather playback %.2fx; physical timestep remains 0.25 seconds.",
			value
		)
	elseif selected == "spawn" or selected == "reset" then
		return self:Spawn(args[1], args[2], args[3])
	elseif selected == "size" then
		assert(args[1] ~= nil, "Use size 0.5..1.5 (starts a new clear cloud source)")
		return self:Spawn(nil, nil, args[1])
	elseif selected == "condensation" then
		assert(
			args[1] ~= nil,
			"Use condensation Normal or condensation Fast (starts a new clear cloud source)"
		)
		return self:Spawn(nil, args[1])
	elseif selected == "form" then
		local seconds = if args[1] == nil then 60 else number(args[1], "Formation time")
		Controller.QueueFormation(seconds)
		return string.format(
			"Queued %.2f simulated seconds at at least 2x playback, within the existing work limits; normal speed resumes afterwards.",
			seconds
		)
	elseif selected == "pause" or selected == "resume" then
		Controller.SetPaused(selected == "pause")
		return if selected == "pause" then "Weather paused." else "Weather resumed."
	elseif selected == "status" then
		return Controller.GetDiagnostics()
	elseif selected == "help" then
		return "seed signed-32-bit integer (next initialization); cloudcount 1..preset limit (next initialization); regenerate (seeded reset); spawnseeded (adds source without reset); autoclouds on|off; seedstatus; wind U V (-30..30 m/s X/Z); speed 0.25..4; spawn [Round|Wide|Tower] [Normal|Fast] [size 0.5..1.5] (legacy reset); size 0.5..1.5 (legacy reset); condensation Normal|Fast (legacy reset); form [0.25..240 seconds, default 60]; pause; resume; reset (legacy); status"
	end
	error("Unknown weather command; use help")
end

function CloudControls:ExecuteText(text: string): any
	assert(
		type(text) == "string" and #text > 0 and #text <= 128,
		"WeatherCommand must contain 1..128 characters"
	)
	local tokens: { string } = {}
	for token in string.gmatch(text, "%S+") do
		table.insert(tokens, token)
	end
	assert(#tokens > 0, "Weather command is empty")
	return self:Execute(tokens[1], table.unpack(tokens, 2))
end

return CloudControls
