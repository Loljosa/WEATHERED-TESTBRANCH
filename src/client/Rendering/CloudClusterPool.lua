--!strict

-- Client-only volumetric voxel resources: exactly ONE genuine cubic Block Part
-- per proxy. No images, planes, billboards, particle systems or sphere fallback.
local CloudClusterPool = {}
CloudClusterPool.__index = CloudClusterPool

export type Options = {
	Limit: number,
	InactiveLimit: number?,
	Factory: ((string) -> any)?,
	Parent: any?,
}
export type Proxy = {
	Anchor: any,
	Id: number?,
	X: number,
	Y: number,
	Z: number,
	Size: number,
	Opacity: number,
	R: number,
	G: number,
	B: number,
	Displayed: boolean,
}
export type Pool = typeof(setmetatable(
	{} :: {
		Limit: number,
		InactiveLimit: number,
		Factory: (string) -> any,
		Folder: any,
		Proxies: { Proxy },
		Active: { [number]: Proxy },
		Free: { Proxy },
		CreatedThisUpdate: number,
		CreationLimit: number,
		ActiveCount: number,
		TotalCreated: number,
		TotalDestroyed: number,
		Destroyed: boolean,
	},
	CloudClusterPool
))

local function finite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end
local function hide(proxy: Proxy)
	if proxy.Displayed then
		proxy.Anchor.Transparency = 1
		proxy.Displayed = false
	end
end
local function create(pool: Pool): Proxy
	local anchor = pool.Factory("Part")
	anchor.Name = "CloudCube"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Material = Enum.Material.SmoothPlastic
	anchor.Shape = Enum.PartType.Block
	anchor.Size = Vector3.new(12, 12, 12)
	anchor.Transparency = 1
	anchor.Color = Color3.new(1, 1, 1)
	anchor.Parent = pool.Folder
	local proxy: Proxy = {
		Anchor = anchor,
		Id = nil,
		X = 0,
		Y = 0,
		Z = 0,
		Size = 12,
		Opacity = 0,
		R = 1,
		G = 1,
		B = 1,
		Displayed = false,
	}
	table.insert(pool.Proxies, proxy)
	pool.CreatedThisUpdate += 1
	pool.TotalCreated += 1
	return proxy
end
function CloudClusterPool.new(options: Options): Pool
	assert(
		options.Limit % 1 == 0 and options.Limit >= 1 and options.Limit <= 1280,
		"Cloud cube limit must be 1..1280"
	)
	local inactive = options.InactiveLimit or 0
	assert(
		inactive % 1 == 0 and inactive >= 0 and inactive <= 128,
		"Inactive cube cache must be 0..128"
	)
	local factory = options.Factory
		or function(className: string): any
			return Instance.new(className)
		end
	local folder = factory("Folder")
	folder.Name = "WEATHERED_CUBIC_CLOUDS"
	folder.Parent = options.Parent or workspace
	return setmetatable({
		Limit = options.Limit,
		InactiveLimit = inactive,
		Factory = factory,
		Folder = folder,
		Proxies = {},
		Active = {},
		Free = {},
		CreatedThisUpdate = 0,
		CreationLimit = 0,
		ActiveCount = 0,
		TotalCreated = 0,
		TotalDestroyed = 0,
		Destroyed = false,
	}, CloudClusterPool)
end
function CloudClusterPool:BeginUpdate(creationLimit: number)
	assert(not self.Destroyed, "Cloud pool was destroyed")
	assert(
		creationLimit % 1 == 0 and creationLimit >= 0 and creationLimit <= 16,
		"Cube creation budget must be 0..16/update"
	)
	self.CreatedThisUpdate, self.CreationLimit = 0, creationLimit
end
function CloudClusterPool:Acquire(id: number): Proxy?
	assert(not self.Destroyed, "Cloud pool was destroyed")
	assert(finite(id) and id % 1 == 0, "Cloud voxel identity must be an integer")
	if self.Active[id] then
		return self.Active[id]
	end
	if self.ActiveCount >= self.Limit then
		return nil
	end
	local proxy = table.remove(self.Free)
	if not proxy then
		if
			#self.Proxies >= self.Limit + self.InactiveLimit
			or self.CreatedThisUpdate >= self.CreationLimit
		then
			return nil
		end
		proxy = create(self)
	end
	proxy.Id = id
	proxy.Opacity = 0
	self.Active[id] = proxy
	self.ActiveCount += 1
	return proxy
end
function CloudClusterPool:Release(id: number)
	local proxy = self.Active[id]
	if not proxy then
		return
	end
	self.Active[id] = nil
	proxy.Id = nil
	proxy.Opacity = 0
	hide(proxy)
	self.ActiveCount -= 1
	table.insert(self.Free, proxy)
end
function CloudClusterPool:Apply(
	proxy: Proxy,
	x: number,
	y: number,
	z: number,
	size: number,
	opacity: number,
	r: number,
	g: number,
	b: number,
	_rotation: number?
)
	assert(proxy.Id ~= nil and finite(x) and finite(y) and finite(z), "Invalid cloud cube position")
	assert(finite(size) and size >= 12 and size <= 48, "Cloud cube sides must be 12..48 studs")
	assert(finite(opacity) and opacity >= 0 and opacity <= 1, "Invalid cloud opacity")
	assert(
		finite(r)
			and finite(g)
			and finite(b)
			and r >= 0
			and r <= 1
			and g >= 0
			and g <= 1
			and b >= 0
			and b <= 1,
		"Cloud color must be normalized"
	)
	if proxy.X ~= x or proxy.Y ~= y or proxy.Z ~= z then
		proxy.Anchor.Position = Vector3.new(x, y, z)
		proxy.X, proxy.Y, proxy.Z = x, y, z
	end
	if proxy.Size ~= size then
		proxy.Anchor.Size = Vector3.new(size, size, size)
		proxy.Size = size
	end
	local rq, gq, bq =
		math.floor(r * 255 + 0.5) / 255,
		math.floor(g * 255 + 0.5) / 255,
		math.floor(b * 255 + 0.5) / 255
	if proxy.R ~= rq or proxy.G ~= gq or proxy.B ~= bq then
		proxy.Anchor.Color = Color3.new(rq, gq, bq)
		proxy.R, proxy.G, proxy.B = rq, gq, bq
	end
	local oq = math.floor(opacity * 255 + 0.5) / 255
	if proxy.Opacity ~= oq or (not proxy.Displayed and oq > 0) then
		proxy.Anchor.Transparency = 1 - oq
	end
	proxy.Opacity = oq
	proxy.Displayed = oq > 0
end
local function destroyProxy(pool: Pool, proxy: Proxy)
	if proxy.Id then
		pool.Active[proxy.Id] = nil
		pool.ActiveCount -= 1
	end
	local free = table.find(pool.Free, proxy)
	if free then
		table.remove(pool.Free, free)
	end
	local index = table.find(pool.Proxies, proxy)
	if index then
		table.remove(pool.Proxies, index)
	end
	proxy.Anchor:Destroy()
	pool.TotalDestroyed += 1
end
function CloudClusterPool:EndUpdate()
	while #self.Free > self.InactiveLimit do
		destroyProxy(self, self.Free[#self.Free])
	end
end
function CloudClusterPool:SetLimit(limit: number, inactiveLimit: number?)
	local inactive = inactiveLimit or self.InactiveLimit
	assert(limit % 1 == 0 and limit >= 1 and limit <= 1280, "Cube limit must be 1..1280")
	assert(
		inactive % 1 == 0 and inactive >= 0 and inactive <= 128,
		"Inactive cube limit must be 0..128"
	)
	self.Limit, self.InactiveLimit = limit, inactive
	while self.ActiveCount > limit do
		for _, proxy in self.Active do
			destroyProxy(self, proxy)
			break
		end
	end
	self:EndUpdate()
end
function CloudClusterPool:Hide()
	for id in self.Active do
		self:Release(id)
	end
	self:EndUpdate()
end
function CloudClusterPool:GetDiagnostics(): any
	return {
		ActiveCubes = self.ActiveCount,
		AllocatedCubes = #self.Proxies,
		AllocatedParts = #self.Proxies,
		RetainedInactiveCubes = #self.Free,
		AllocatedInstances = if self.Destroyed then 0 else 1 + #self.Proxies,
		ActiveEmitters = 0,
		EstimatedLiveParticles = 0,
		CreatedThisUpdate = self.CreatedThisUpdate,
		TotalCreated = self.TotalCreated,
		TotalDestroyed = self.TotalDestroyed,
	}
end
function CloudClusterPool:Destroy()
	if self.Destroyed then
		return
	end
	self.Destroyed = true
	self.Folder:Destroy()
	table.clear(self.Proxies)
	table.clear(self.Active)
	table.clear(self.Free)
	self.ActiveCount = 0
end
return table.freeze(CloudClusterPool)
