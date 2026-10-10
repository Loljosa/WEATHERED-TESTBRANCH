--!native
--!strict

-- The terrain adapter supplies a canonical signed 32-bit integer. A development
-- fallback is explicit; malformed canonical seeds never silently select another world.
local WorldSeed = {}
local UINT32 = 4294967296
local INT32_MIN = -2147483648
local INT32_MAX = 2147483647

WorldSeed.DevelopmentSeed = 84219

function WorldSeed.Validate(seed: any): number
	assert(
		type(seed) == "number"
			and seed == seed
			and seed % 1 == 0
			and seed >= INT32_MIN
			and seed <= INT32_MAX,
		"World seed must be a signed 32-bit integer (-2147483648..2147483647)"
	)
	return seed
end

-- Exact modulo-2^32 multiplication: each partial product fits a double's
-- 53-bit integer mantissa. Direct uint32*uint32 multiplication would not.
local function multiply32(a: number, b: number): number
	local alo, ahi = a % 65536, math.floor(a / 65536)
	local blo, bhi = b % 65536, math.floor(b / 65536)
	return (alo * blo + ((ahi * blo + alo * bhi) % 65536) * 65536) % UINT32
end

function WorldSeed.Hash(value: number): number
	local h = value % UINT32
	h = multiply32(bit32.bxor(h, bit32.rshift(h, 16)), 2246822507)
	h = multiply32(bit32.bxor(h, bit32.rshift(h, 13)), 3266489909)
	return bit32.bxor(h, bit32.rshift(h, 16))
end

function WorldSeed.Derive(seed: number, stream: string, eventIndex: number?): number
	WorldSeed.Validate(seed)
	assert(type(stream) == "string" and #stream > 0, "Seed stream must be a nonempty string")
	local index = eventIndex or 0
	assert(
		index == index and index >= 0 and index % 1 == 0 and index <= INT32_MAX,
		"Event index must be an integer in 0..2147483647"
	)
	local hash = WorldSeed.Hash(seed)
	for byte = 1, #stream do
		hash = multiply32(bit32.bxor(hash, string.byte(stream, byte)), 16777619)
	end
	hash = WorldSeed.Hash(bit32.bxor(hash, WorldSeed.Hash(index)))
	return if hash > INT32_MAX then hash - UINT32 else hash
end

function WorldSeed.Resolve(canonical: any?, fallback: any?): (number, string)
	if canonical ~= nil then
		return WorldSeed.Validate(canonical), "canonical world seed"
	end
	return WorldSeed.Validate(if fallback ~= nil then fallback else WorldSeed.DevelopmentSeed),
		"development fallback (terrain seed adapter unavailable)"
end

return table.freeze(WorldSeed)
