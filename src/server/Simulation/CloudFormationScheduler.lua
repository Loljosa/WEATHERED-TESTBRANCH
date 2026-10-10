--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldSeed = require(ReplicatedStorage.Shared.Atmosphere.Generation.WorldSeed)

local Scheduler = {}
Scheduler.__index = Scheduler

export type Settings = {
	IntervalTicks: number?,
	Enabled: boolean?,
	FormationProbability: number?,
}

export type Scheduler = typeof(setmetatable(
	{} :: {
		Seed: number,
		IntervalTicks: number,
		Enabled: boolean,
		FormationProbability: number,
		Tick: number,
		Opportunities: number,
		PreparedTick: number,
		PreparedOpportunity: number,
		PreparedFormation: boolean,
	},
	Scheduler
))

-- The schedule uses committed physical ticks. Quiet opportunities are seeded,
-- and disabled opportunities are skipped rather than replayed on re-enabling.
function Scheduler.new(seed: number, settings: Settings?): Scheduler
	local options = settings or {}
	local interval = options.IntervalTicks or 180 -- 45 physical seconds at 0.25 s.
	local probability = options.FormationProbability or 0.7
	assert(
		interval % 1 == 0 and interval >= 1 and interval <= 14400,
		"Source interval must be 1..14400 ticks"
	)
	assert(
		probability == probability and probability >= 0 and probability <= 1,
		"Formation probability must be 0..1"
	)
	assert(
		options.Enabled == nil or type(options.Enabled) == "boolean",
		"AutoClouds must be a boolean"
	)
	return setmetatable({
		Seed = WorldSeed.Validate(seed),
		IntervalTicks = interval,
		Enabled = if options.Enabled == nil then true else options.Enabled,
		FormationProbability = probability,
		Tick = 0,
		Opportunities = 0,
		PreparedTick = 0,
		PreparedOpportunity = 0,
		PreparedFormation = false,
	}, Scheduler)
end

function Scheduler:SetEnabled(enabled: boolean)
	assert(type(enabled) == "boolean", "AutoClouds must be a boolean")
	assert(
		self.PreparedTick == 0,
		"Cannot change source scheduling during an uncommitted physical step"
	)
	self.Enabled = enabled
end

-- Prepare is idempotent: a rejected atmosphere step gets exactly the same event
-- on retry. No random generator, os.clock, or Heartbeat duration enters this path.
function Scheduler:Prepare(nextTick: number): (boolean, number)
	assert(
		nextTick % 1 == 0 and nextTick == self.Tick + 1,
		"Source scheduler requires the next committed tick"
	)
	if self.PreparedTick == nextTick then
		return self.PreparedFormation, self.PreparedOpportunity
	end
	assert(self.PreparedTick == 0, "Previous source schedule is not committed")
	local opportunity = if nextTick % self.IntervalTicks == 0 then self.Opportunities + 1 else 0
	local forms = false
	if opportunity > 0 and self.Enabled then
		local derived = WorldSeed.Derive(self.Seed, "cloud-schedule", opportunity)
		local sample = (derived % 2147483647) / 2147483647
		forms = sample < self.FormationProbability
	end
	self.PreparedTick = nextTick
	self.PreparedOpportunity = opportunity
	self.PreparedFormation = forms
	return forms, opportunity
end

function Scheduler:Commit(nextTick: number)
	assert(
		self.PreparedTick == nextTick and nextTick == self.Tick + 1,
		"Source schedule commit must match its preparation"
	)
	self.Tick = nextTick
	if self.PreparedOpportunity > 0 then
		self.Opportunities = self.PreparedOpportunity
	end
	self.PreparedTick = 0
	self.PreparedOpportunity = 0
	self.PreparedFormation = false
end

return Scheduler
