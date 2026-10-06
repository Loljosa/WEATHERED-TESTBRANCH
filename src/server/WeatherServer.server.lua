--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Atmosphere = require(ReplicatedStorage.Shared.Atmosphere)

print("[WEATHERED] Atmosphere engine", Atmosphere.GetVersion())
