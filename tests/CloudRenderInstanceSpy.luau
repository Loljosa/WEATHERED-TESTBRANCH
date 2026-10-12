--!strict

-- Only the Roblox Instance boundary is replaced. Production pooling, density,
-- noise, lighting, LOD and resource ownership execute unchanged. The spy does
-- not emulate GPU alpha sorting or Roblox engine allocation cost.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local Spy = {}

function Spy.Create(): any
	local records: { [any]: any } = {}
	local instances = {}
	local live, total, writes = 0, 0, 0
	local newInstance: (string) -> any
	newInstance = function(className: string): any
		local instance = {}
		local record = {
			ClassName = className,
			Properties = {},
			Attributes = {},
			Children = {},
			Destroyed = false,
		}
		records[instance] = record
		table.insert(instances, instance)
		live += 1
		total += 1
		setmetatable(instance, {
			__index = function(_self: any, key: string): any
				if key == "Destroy" then
					return function()
						if record.Destroyed then
							return
						end
						for _, child in table.clone(record.Children) do
							child:Destroy()
						end
						instance.Parent = nil
						record.Destroyed = true
						live -= 1
					end
				elseif key == "SetAttribute" then
					return function(_selfAgain: any, name: string, value: any)
						record.Attributes[name] = value
					end
				elseif key == "GetAttribute" then
					return function(_selfAgain: any, name: string): any
						return record.Attributes[name]
					end
				elseif key == "IsA" then
					return function(_selfAgain: any, name: string): boolean
						return className == name
					end
				elseif key == "GetChildren" then
					return function(): any
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
				elseif key == "ClassName" then
					return className
				end
				return record.Properties[key]
			end,
			__newindex = function(_self: any, key: string, value: any)
				assert(not record.Destroyed, "Property write to destroyed cloud Instance")
				writes += 1
				if key == "Parent" then
					local previous = record.Properties.Parent
					if previous then
						local siblings = records[previous].Children
						local index = table.find(siblings, instance)
						if index then
							table.remove(siblings, index)
						end
					end
					if value then
						table.insert(records[value].Children, instance)
					end
				end
				record.Properties[key] = value
			end,
		})
		return instance
	end
	local world = newInstance("Workspace")
	local result: any =
		{ Factory = newInstance, Workspace = world, Instances = instances, Records = records }
	function result:GetDiagnostics(): any
		return { LiveInstances = live - 1, TotalCreated = total - 1, PropertyWrites = writes }
	end
	function result:Load(root: any, loadShared: any): (any, any)
		local modules: any = { Name = "Rendering" }
		modules.CloudClusterPool = {
			Name = "CloudClusterPool",
			Parent = modules,
			Path = "src/client/Rendering/CloudClusterPool.lua",
		}
		modules.CloudRenderer = {
			Name = "CloudRenderer",
			Parent = modules,
			Path = "src/client/Rendering/CloudRenderer.lua",
		}
		local cache = {}
		local loadClient: (any) -> any
		loadClient = function(node: any): any
			if node.Path == nil then
				return loadShared(node)
			end
			if cache[node] then
				return cache[node]
			end
			local execute = luau.load(
				"return function(script, require, game, workspace, Instance, Vector3, Color3, UDim2, Enum)\n"
					.. fs.readFile(node.Path)
					.. "\nend",
				{ debugName = "@" .. node.Path, codegenEnabled = true }
			)
			local module = execute()(
				node,
				loadClient,
				{
					GetService = function(_self: any, name: string): any
						assert(name == "ReplicatedStorage")
						return { Shared = { Atmosphere = root } }
					end,
				},
				world,
				{ new = newInstance },
				roblox.Vector3,
				roblox.Color3,
				roblox.UDim2,
				{
					Material = { SmoothPlastic = "SmoothPlastic" },
					PartType = { Ball = "Ball", Block = "Block" },
				}
			)
			cache[node] = module
			return module
		end
		return loadClient(modules.CloudRenderer), loadClient(modules.CloudClusterPool)
	end

	function result:LoadVoxel(root: any, loadShared: any, sourcePath: string?): any
		local source =
			fs.readFile(sourcePath or "src/shared/Atmosphere/World/WorldVoxelDebugRenderer.lua")
		local execute = luau.load(
			"return function(script, require, workspace, Instance, Vector3, Color3, UDim2, Enum, CFrame)\n"
				.. source
				.. "\nend",
			{ debugName = "@" .. (sourcePath or "WorldVoxelDebugRenderer"), codegenEnabled = true }
		)
		return execute()(
			{ Parent = root.World },
			loadShared,
			world,
			{ new = newInstance },
			roblox.Vector3,
			roblox.Color3,
			roblox.UDim2,
			{
				Material = { SmoothPlastic = "SmoothPlastic" },
				PartType = { Ball = "Ball", Block = "Block" },
			},
			roblox.CFrame
		)
	end
	return result
end
return Spy
