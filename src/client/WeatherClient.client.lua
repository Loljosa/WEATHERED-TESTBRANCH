--!strict

local WorldWeatherClient = require(script.Parent.WorldWeatherClient)
local stop = WorldWeatherClient.Start()
script.Destroying:Connect(stop)
print("[WEATHERED] Weather client initialized; world diagnostics use server snapshots")
