--!strict

-- Load the actual Rojo modules without changing production require(script.Parent...).
-- Lune supplies real Vector3 userdata and Luau's native float32 buffer implementation.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

type Node = {
	Name: string,
	Parent: Node?,
	SourcePath: string?,
	[string]: any,
}

local function directory(path: string, name: string, parent: Node?): Node
	local node: Node = { Name = name, Parent = parent }
	if fs.isFile(path .. "/init.lua") then
		node.SourcePath = path .. "/init.lua"
	end
	for _, entry in fs.readDir(path) do
		local entryPath = path .. "/" .. entry
		if fs.isDir(entryPath) then
			node[entry] = directory(entryPath, entry, node)
		elseif string.sub(entry, -4) == ".lua" and entry ~= "init.lua" then
			local moduleName = string.sub(entry, 1, -5)
			node[moduleName] = { Name = moduleName, Parent = node, SourcePath = entryPath }
		end
	end
	return node
end

local function create(path: string, globals: { [string]: any }?): (Node, (Node) -> any)
	local root = directory(path, "Atmosphere", nil)
	local cache: { [Node]: any } = {}
	local loading: { [Node]: boolean } = {}
	local loadModule: (Node) -> any
	loadModule = function(node: Node): any
		assert(node ~= nil and node.SourcePath ~= nil, "Test require target is not a ModuleScript")
		if cache[node] ~= nil then
			return cache[node]
		end
		assert(not loading[node], "Circular require: " .. node.SourcePath)
		loading[node] = true
		-- Lexical parameters provide Roblox-only globals without disabling Lune
		-- codegen through a custom global environment. The module body is unchanged.
		local source = "return function(script, require, Vector3, game, print, warn)\n"
			.. fs.readFile(node.SourcePath)
			.. "\nend"
		local execute = luau.load(source, {
			debugName = "@" .. node.SourcePath,
			codegenEnabled = true,
		})
		local module = execute()
		local result = module(
			node,
			loadModule,
			roblox.Vector3,
			if globals then globals.game else nil,
			if globals and globals.print then globals.print else print,
			if globals and globals.warn then globals.warn else warn
		)
		assert(result ~= nil, "Module must return a value: " .. node.SourcePath)
		loading[node] = nil
		cache[node] = result
		return result
	end
	return root, loadModule
end

return create
