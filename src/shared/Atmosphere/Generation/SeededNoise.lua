--!native
--!strict

local WorldSeed = require(script.Parent.WorldSeed)

local SeededNoise = {}
export type Parameters = { Seed: number, OffsetX: number, OffsetY: number, OffsetZ: number }
local UINT32 = 4294967296

local function fade(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function lattice(seed: number, x: number, y: number, z: number): number
	local hash = WorldSeed.Hash(bit32.bxor(seed, WorldSeed.Hash(x % UINT32)))
	hash = WorldSeed.Hash(bit32.bxor(hash, WorldSeed.Hash(y % UINT32), 2654435769))
	hash = WorldSeed.Hash(bit32.bxor(hash, WorldSeed.Hash(z % UINT32), 1013904223))
	return hash / 2147483647.5 - 1
end

function SeededNoise.Create(seed: number, stream: string?): Parameters
	local derived = WorldSeed.Derive(seed, stream or "noise")
	return table.freeze({
		Seed = derived,
		OffsetX = WorldSeed.Hash(derived) / UINT32 * 256,
		OffsetY = WorldSeed.Hash(bit32.bxor(derived, 2654435769)) / UINT32 * 256,
		OffsetZ = WorldSeed.Hash(bit32.bxor(derived, 1013904223)) / UINT32 * 256,
	})
end

local function coordinate(value: number): number
	assert(value == value and math.abs(value) < math.huge, "Noise coordinate must be finite")
	-- A wrapped lattice hash supports negative/global coordinates without relying
	-- on signed integer conversion outside bit32's exact uint32 range.
	return value
end

function SeededNoise.Sample2D(parameters: Parameters, x: number, y: number): number
	x = coordinate(x) + parameters.OffsetX
	y = coordinate(y) + parameters.OffsetY
	local ix, iy = math.floor(x), math.floor(y)
	local tx, ty = fade(x - ix), fade(y - iy)
	local seed = parameters.Seed
	return lerp(
		lerp(lattice(seed, ix, iy, 0), lattice(seed, ix + 1, iy, 0), tx),
		lerp(lattice(seed, ix, iy + 1, 0), lattice(seed, ix + 1, iy + 1, 0), tx),
		ty
	)
end

function SeededNoise.Sample3D(parameters: Parameters, x: number, y: number, z: number): number
	x = coordinate(x) + parameters.OffsetX
	y = coordinate(y) + parameters.OffsetY
	z = coordinate(z) + parameters.OffsetZ
	local ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
	local tx, ty, tz = fade(x - ix), fade(y - iy), fade(z - iz)
	local seed = parameters.Seed
	return lerp(
		lerp(
			lerp(lattice(seed, ix, iy, iz), lattice(seed, ix + 1, iy, iz), tx),
			lerp(lattice(seed, ix, iy + 1, iz), lattice(seed, ix + 1, iy + 1, iz), tx),
			ty
		),
		lerp(
			lerp(lattice(seed, ix, iy, iz + 1), lattice(seed, ix + 1, iy, iz + 1), tx),
			lerp(lattice(seed, ix, iy + 1, iz + 1), lattice(seed, ix + 1, iy + 1, iz + 1), tx),
			ty
		),
		tz
	)
end

local function octaves(value: number?): number
	local count = value or 3
	assert(count % 1 == 0 and count >= 1 and count <= 4, "Noise octaves must be 1..4")
	return count
end

function SeededNoise.Fractal2D(parameters: Parameters, x: number, y: number, count: number?): number
	local total, weight, amplitude = 0, 0, 1
	for _ = 1, octaves(count) do
		total += amplitude * SeededNoise.Sample2D(parameters, x, y)
		weight += amplitude
		x *= 2
		y *= 2
		amplitude *= 0.5
	end
	return total / weight
end

function SeededNoise.Fractal3D(
	parameters: Parameters,
	x: number,
	y: number,
	z: number,
	count: number?
): number
	local total, weight, amplitude = 0, 0, 1
	for _ = 1, octaves(count) do
		total += amplitude * SeededNoise.Sample3D(parameters, x, y, z)
		weight += amplitude
		x *= 2
		y *= 2
		z *= 2
		amplitude *= 0.5
	end
	return total / weight
end

return table.freeze(SeededNoise)
