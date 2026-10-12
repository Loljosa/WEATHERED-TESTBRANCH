--!strict

local WorldWeatherClient = require(script.Parent.WorldWeatherClient)
local stop = WorldWeatherClient.Start(script)
script.Destroying:Connect(stop)
print("[WEATHERED] Cloud client initialized; Cubes is default; visual controls are local")
