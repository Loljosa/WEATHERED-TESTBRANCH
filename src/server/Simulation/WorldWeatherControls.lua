--!strict

local Root = game:GetService("ReplicatedStorage").Shared.Atmosphere
local WorldSeed = require(Root.Generation.WorldSeed)
local Coverage = require(Root.World.Coverage)
local Controller = require(script.Parent.WorldWeatherController)
local Controls = {}
Controls.__index = Controls

local function number(value: any, label: string): number
	local n = if type(value) == "number"
		then value
		else if type(value) == "string" then tonumber(value) else nil
	assert(n ~= nil and n == n and math.abs(n) < math.huge, label .. " must be finite")
	return n :: number
end
local function enabled(value: any): boolean
	assert(value == "on" or value == "off", "Use on or off")
	return value == "on"
end

function Controls.new(controller: any): any
	return setmetatable({ Controller = controller }, Controls)
end

function Controls:Execute(command: string, ...: any): any
	assert(type(command) == "string", "Command must be a string")
	local args = table.pack(...)
	local cmd = string.lower(command)
	local c = self.Controller
	local arity = if cmd == "wind"
		then 2
		else if cmd == "spawn"
			then 3
			else if cmd == "worldsize"
					or cmd == "form"
					or cmd == "detail"
				then 1
				else if cmd == "seed"
						or cmd == "cloudcount"
						or cmd == "cloudcoverage"
						or cmd == "debugregions"
						or cmd == "debugvectors"
						or cmd == "speed"
						or cmd == "autoclouds"
						or cmd == "size"
						or cmd == "condensation"
					then 1
					else 0
	assert(args.n <= arity, "Too many command arguments")
	if cmd == "worldsize" then
		assert(
			args[1] == nil or number(args[1], "World size") == 4028,
			"This world supports exactly 4028 x 4028 studs; other sizes require a separately validated engine configuration"
		)
		return { WidthStuds = 4028, DepthStuds = 4028, Coordinates = c.Field.Coordinates }
	elseif cmd == "weatherregions" then
		return c.Field:GetRegionDiagnostics()
	elseif cmd == "cloudmotion" or cmd == "status" then
		return c:GetDiagnostics()
	elseif cmd == "seedstatus" then
		local result = c.Sources:GetDiagnostics()
		result.NextWorldSeed, result.NextCoverage =
			c.NextOptions.Seed, c.NextOptions.Coverage or "Scattered"
		result.NextInitialSourceCount = c.NextOptions.InitialSourceCount
		result.SeedSource = c.Options.SeedSource or "Configured"
		return result
	elseif cmd == "cloudcoverage" then
		assert(type(args[1]) == "string", "Use cloudcoverage clear|few|scattered|broken|overcast")
		local scenario = Coverage.Get(args[1])
		c.NextOptions.Coverage, c.NextOptions.InitialSourceCount = scenario.Name, nil
		return "Next coverage: "
			.. scenario.Name
			.. "; use regenerate. Current fields are preserved."
	elseif cmd == "seed" then
		c.NextOptions.Seed = WorldSeed.Validate(number(args[1], "Seed"))
		c.NextOptions.SeedSource = "DeveloperCommand"
		return "Seed selected for next regenerate."
	elseif cmd == "cloudcount" then
		local count = number(args[1], "Source count")
		assert(count % 1 == 0 and count >= 0 and count <= 16, "Cloud count must be 0..16")
		c.NextOptions.InitialSourceCount = count
		return "Initial source count selected for next regenerate."
	elseif cmd == "regenerate" or cmd == "reset" then
		c:Regenerate()
		return "World regenerated intentionally; cloud water starts clear."
	elseif cmd == "spawnseeded" then
		return c.Sources:QueueSource()
	elseif cmd == "autoclouds" then
		local value = enabled(args[1])
		c.Sources:SetAutoClouds(value)
		c.NextOptions.AutoClouds, c.Options.AutoClouds = value, value
		return "Automatic source scheduling " .. args[1]
	elseif cmd == "debugregions" or cmd == "debugvectors" then
		local value = enabled(args[1])
		if cmd == "debugregions" then
			c.DebugRegions = value
		else
			c.DebugVectors = value
		end
		return cmd .. " " .. args[1]
	elseif cmd == "wind" then
		local u, v = number(args[1], "U"), number(args[2], "V")
		c.Field:SetWind(u, v)
		c.Options.BackgroundU, c.Options.BackgroundV = u, v
		c.NextOptions.BackgroundU, c.NextOptions.BackgroundV = u, v
		return string.format("Live world wind X %.2f / Z %.2f m/s", u, v)
	elseif cmd == "speed" then
		c.Speed = Controller.ValidateSpeed(number(args[1], "Speed"))
		return "Playback updated; fixed dt remains 0.25 seconds."
	elseif cmd == "pause" or cmd == "resume" then
		c.Paused = cmd == "pause"
		return cmd
	elseif cmd == "form" then
		local seconds = if args[1] == nil then 60 else number(args[1], "Formation time")
		assert(
			seconds >= 0.25 and seconds <= 240 and seconds / 0.25 % 1 == 0,
			"Formation time must be 0.25..240 in 0.25-second increments"
		)
		c.FormationRemainingSeconds, c.Paused = seconds, false
		return "Bounded formation preview queued; dropped steps do not count as completed time."
	elseif cmd == "detail" then
		c.Coupling:SetEnabled(enabled(args[1]))
		return "Optional one-way MAC diagnostic " .. args[1]
	elseif cmd == "spawn" or cmd == "size" or cmd == "condensation" then
		assert(
			c.Coupling.StartExperiment ~= nil,
			"Legacy primitive controls require WorldWeatherEnabled=false; world generation uses seeded multi-axis geometry"
		)
		return c.Coupling:StartExperiment(cmd, table.unpack(args, 1, args.n))
	elseif cmd == "help" then
		return "worldsize [4028]; weatherregions; cloudmotion; cloudcoverage clear|few|scattered|broken|overcast (next regenerate); seed N; cloudcount 0..16 (next regenerate); regenerate|reset; spawnseeded; autoclouds on|off; seedstatus; wind U V; speed 0.25..4; pause|resume; form [seconds]; debugregions on|off; debugvectors on|off; detail on|off; spawn/size/condensation (local diagnostic experiment)"
	end
	error("Unknown world weather command; use help")
end

function Controls:ExecuteText(text: string): any
	assert(
		type(text) == "string" and #text > 0 and #text <= 128,
		"Command must contain 1..128 characters"
	)
	local tokens = {}
	for token in string.gmatch(text, "%S+") do
		table.insert(tokens, token)
	end
	assert(#tokens > 0, "Command is empty")
	return self:Execute(tokens[1], table.unpack(tokens, 2))
end
return Controls
