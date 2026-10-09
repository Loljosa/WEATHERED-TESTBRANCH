--!strict

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

-- Instance/property spies execute the real renderer without claiming a Studio
-- GPU/replication benchmark. Grid coordinates and float32 fields remain real.
return function(root: any, loadModule: any, check: any, near: any, rejects: any)
	local Grid3D = loadModule(root.Core.Grid3D)
	local State = loadModule(root.Core.AtmosphereState)
	local writes: { [string]: number } = {}
	local instances: { any } = {}
	local backing: { [any]: any } = {}
	local function countWrites(): number
		local total = 0
		for _, count in writes do
			total += count
		end
		return total
	end
	local function children(instance: any): { any }
		return backing[instance].Children
	end
	local function newInstance(className: string): any
		local instance = {}
		local record: any = { ClassName = className, Properties = {}, Children = {} }
		backing[instance] = record
		table.insert(instances, instance)
		setmetatable(instance, {
			__index = function(_self: any, key: string): any
				if key == "IsA" then
					return function(_selfAgain: any, expectedClass: string): boolean
						return className == expectedClass
					end
				elseif key == "GetChildren" then
					return function(): { any }
						return table.clone(record.Children)
					end
				elseif key == "FindFirstChild" then
					return function(_selfAgain: any, name: string): any
						for _, child in record.Children do
							if child.Name == name then
								return child
							end
						end
						return nil
					end
				elseif key == "Destroy" then
					return function()
						for _, child in table.clone(record.Children) do
							child:Destroy()
						end
						instance.Parent = nil
						record.Destroyed = true
					end
				end
				return record.Properties[key]
			end,
			__newindex = function(_self: any, key: string, value: any)
				writes[key] = (writes[key] or 0) + 1
				if key == "Parent" then
					local previous = record.Properties.Parent
					if previous then
						local siblings = children(previous)
						local index = table.find(siblings, instance)
						if index then
							table.remove(siblings, index)
						end
					end
					if value then
						table.insert(children(value), instance)
					end
				end
				record.Properties[key] = value
			end,
		})
		return instance
	end
	local fakeWorkspace = newInstance("Workspace")
	local execute = luau.load(
		"return function(require, game, workspace, Instance, Color3, Enum, Vector3)\n"
			.. fs.readFile("src/server/Debug/VoxelDebugRenderer.lua")
			.. "\nend",
		{ debugName = "@src/server/Debug/VoxelDebugRenderer.lua", codegenEnabled = true }
	)
	local renderer = execute()(
		loadModule,
		{
			GetService = function(_self: any, name: string): any
				assert(name == "ReplicatedStorage")
				return { Shared = { Atmosphere = root } }
			end,
		},
		fakeWorkspace,
		{ new = newInstance },
		roblox.Color3,
		{ Material = { SmoothPlastic = "SmoothPlastic" } },
		roblox.Vector3
	)
	local grid = Grid3D.new(12, 2, 2, 12, roblox.Vector3.new(-72, 24, -12))
	local state = State.new(grid)
	local function visibleParts(): { any }
		local visible = {}
		for _, instance in instances do
			if instance:IsA("Part") and instance.Parent and instance.Transparency < 1 then
				table.insert(visible, instance)
			end
		end
		return visible
	end
	local function partAt(index: number, selectedGrid: any?): any
		local targetGrid = selectedGrid or grid
		local x, y, z = targetGrid:Coordinates(index)
		local position = targetGrid:GridToWorld(x, y, z)
		for _, part in visibleParts() do
			if part.Position == position then
				return part
			end
		end
		return nil
	end
	check(renderer.Render(state) == 0, "Clear initial atmosphere allocates no debug Parts")
	for _, index in { 2, 5, 8 } do
		state:Set("qc", index, 0.0003)
	end
	check(renderer.Render(state) == 3, "Renderer selects each cloudy cell")
	local retainedFive, retainedEight = partAt(5), partAt(8)
	check(retainedFive ~= nil and retainedEight ~= nil, "Debug Parts use real grid centers")
	near(retainedFive.Transparency, 0.46, 1e-12, "Density maps to 0.01-quantized visual opacity")
	for _, part in visibleParts() do
		check(
			part.Size == roblox.Vector3.new(12, 12, 12),
			"Debug cubes retain exact 12-stud dimensions"
		)
		check(
			not part.CanCollide and not part.CanTouch and not part.CanQuery and not part.CastShadow,
			"Debug Parts disable physics and shadow overhead"
		)
	end
	table.clear(writes)
	check(renderer.Render(state) == 3, "Unchanged cloud retains visible selection")
	check(countWrites() == 0, "Unchanged cloud generates zero Instance property writes")
	state:Set("qc", 5, 0.000300001)
	table.clear(writes)
	renderer.Render(state)
	check(countWrites() == 0, "Sub-bin density changes generate no replicated opacity writes")
	state:Set("qc", 5, 0.0004)
	table.clear(writes)
	renderer.Render(state)
	check(
		countWrites() == 1 and writes.Transparency == 1,
		"Density change updates only affected opacity"
	)
	state:Set("qc", 2, 0)
	state:Set("qc", 9, 0.0003)
	table.clear(writes)
	check(renderer.Render(state) == 3, "Disappearing cell immediately supplies a pooled slot")
	check(
		partAt(5) == retainedFive and partAt(8) == retainedEight,
		"Surviving cells retain their Parts when earlier cells disappear"
	)
	check(partAt(2) == nil and partAt(9) ~= nil, "Reassigned pool entry has the new cell position")
	check(writes.Position == 1 and writes.Size == nil, "Cell replacement moves only one Part")
	check(renderer.Render(state, nil, 1) == 1, "Lower renderer limit releases excess selection")
	check(#visibleParts() == 1 and partAt(5) == retainedFive, "Limit leaves no stale visible Parts")
	local movedGrid = Grid3D.new(12, 2, 2, 6, roblox.Vector3.new(50, 30, 10))
	local movedState = State.new(movedGrid)
	movedState:Set("qc", 5, 0.0003)
	check(renderer.Render(movedState) == 1, "New grid can reuse the existing Part pool")
	local movedPart = partAt(5, movedGrid)
	check(
		movedPart ~= nil and movedPart.Size == roblox.Vector3.new(6, 6, 6),
		"Grid replacement invalidates cached geometry without stale positions"
	)
	movedState:Set("qc", 5, 0)
	check(
		renderer.Render(movedState) == 0 and #visibleParts() == 0,
		"Clear state hides active Parts"
	)
	table.clear(writes)
	renderer.Render(movedState)
	check(countWrites() == 0, "Already-hidden pooled Parts produce no repeated writes")
	rejects(function()
		renderer.Render(movedState, nil, 1201)
	end, "Renderer enforces the maximum Part pool")
	renderer.Destroy()
	check(#children(fakeWorkspace) == 0, "Destroy removes debug folder and its Parts")

	local fullGrid = Grid3D.new(40, 1, 1, 12, roblox.Vector3.zero)
	local fullState = State.new(fullGrid)
	fullState:Fill("qc", 0.0003)
	check(renderer.Render(fullState) == 32, "Instance creation is capped at 32 per update")
	check(
		renderer.Render(fullState) == 40,
		"Later updates finish the cloud without losing retained cells"
	)
	table.clear(writes)
	check(
		renderer.Render(fullState) == 40 and countWrites() == 0,
		"Completed pool remains write-free"
	)
	local debugFolder = fakeWorkspace:FindFirstChild("WEATHERED_DEBUG_VOXELS")
	debugFolder:Destroy()
	check(
		renderer.Render(fullState) == 32,
		"Externally removed debug folder rebuilds a bounded pool"
	)
	renderer.Destroy()
	local budgetGrid = Grid3D.new(100, 1, 1, 12, roblox.Vector3.zero)
	local budgetState = State.new(budgetGrid)
	budgetState:Set("qc", 99, 0.0003)
	budgetState:Set("qc", 100, 0.0003)
	check(renderer.Render(budgetState) == 2, "Late-index cells initially acquire their own Parts")
	local retainedLate = partAt(100, budgetGrid)
	budgetState:Fill("qc", 0.0003)
	check(
		renderer.Render(budgetState) == 34 and #visibleParts() == 34,
		"Creation limit still counts retained cells later in the selection"
	)
	check(
		partAt(100, budgetGrid) == retainedLate,
		"Exhausted creation budget does not skip updating retained later cells"
	)
	renderer.Destroy()
	print(
		"PASS: debug pool preserves cells, unchanged opacity/geometry writes zero properties, cloud changes move only new cells, grid resets invalidate geometry, and creation is capped at 32"
	)
end
