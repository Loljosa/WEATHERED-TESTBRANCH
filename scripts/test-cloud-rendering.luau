--!strict

-- Production render modules run through the existing Roblox require adapter.
-- This validates numerical reconstruction and API/resource behavior, not GPU
-- appearance. Studio camera, texture and hardware gates remain separate.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local createLoader = require("../tests/RobloxModuleLoader")

local quick = false
local selectedTest: string? = nil
local argIndex = 1
while argIndex <= #process.args do
	local argument = process.args[argIndex]
	if argument == "--quick" then
		assert(not quick, "Provide --quick at most once")
		quick = true
	elseif argument == "--test" then
		assert(selectedTest == nil and process.args[argIndex + 1] ~= nil, "Provide one test name")
		selectedTest = process.args[argIndex + 1]
		argIndex += 1
	else
		error("Usage: lune run scripts/test-cloud-rendering.luau [--quick] [--test <name>]")
	end
	argIndex += 1
end

local root, loadModule = createLoader("src/shared/Atmosphere")
local checks = 0
local function check(value: boolean, message: string)
	assert(value, message)
	checks += 1
end
local function near(actual: number, expected: number, tolerance: number, message: string)
	check(
		math.abs(actual - expected) <= tolerance,
		message .. string.format(" (%.12g vs %.12g)", actual, expected)
	)
end
local function rejects(callback: () -> (), message: string)
	check(not pcall(callback), message)
end

local function fingerprint(directories: { string }, suffixes: { string }): string
	local paths = {}
	local function collect(path: string)
		for _, name in fs.readDir(path) do
			local child = path .. "/" .. name
			if fs.isDir(child) then
				collect(child)
			else
				for _, suffix in suffixes do
					if string.sub(child, -#suffix) == suffix then
						table.insert(paths, child)
						break
					end
				end
			end
		end
	end
	for _, directory in directories do
		collect(directory)
	end
	table.sort(paths)
	local contents = {}
	for _, path in paths do
		table.insert(contents, path .. "\0" .. fs.readFile(path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local productionDirectories = { "src/shared/Atmosphere", "src/server", "src/client" }
local productionFingerprint = fingerprint(productionDirectories, { ".lua", ".json" })
local testFingerprint = fingerprint({ "scripts", "tests" }, { ".luau" })
local revision = string.gsub(process.exec("git", { "rev-parse", "HEAD" }).stdout, "%s+$", "")
local dirty = process.exec("git", { "status", "--porcelain" }).stdout ~= ""
local started = os.clock()
local results = {}
local tests = {
	"cloud-density-reconstruction",
	"cloud-surface-analysis",
	"cloud-temporal-reconstruction",
	"cloud-snapshot-completeness",
	"cloud-render-seeding",
	"cloud-visual-consistency",
	"cloud-render-resource-bounds",
	"cloud-vertical-preparation",
	"cloud-render-client",
	"cloud-cubic-geometry",
}
local selectedFound = selectedTest == nil
for _, name in tests do
	if selectedTest == nil or selectedTest == name then
		selectedFound = true
		local previousChecks = checks
		local testStarted = os.clock()
		local result = require("../tests/" .. name)(root, loadModule, check, near, rejects, quick)
		local milliseconds = (os.clock() - testStarted) * 1000
		table.insert(results, {
			Name = name,
			Checks = checks - previousChecks,
			ElapsedMilliseconds = milliseconds,
			Result = result,
		})
		print(string.format("PASS: %s (%d checks)", name, checks - previousChecks))
	end
end
assert(selectedFound, "Unknown cloud-rendering test: " .. tostring(selectedTest))
check(
	fingerprint(productionDirectories, { ".lua", ".json" }) == productionFingerprint,
	"Production files changed while cloud-rendering tests were running; rerun on a stable source tree"
)
check(
	fingerprint({ "scripts", "tests" }, { ".luau" }) == testFingerprint,
	"Test files changed while cloud-rendering tests were running; rerun on a stable test tree"
)
local report = {
	Schema = 1,
	Suite = "Phase 2.65 cloud rendering production modules",
	Mode = if quick then "quick" else "full",
	SelectedTest = selectedTest,
	Checks = checks,
	ElapsedMilliseconds = (os.clock() - started) * 1000,
	SourceRevision = revision,
	WorkingTreeChanged = dirty,
	ProductionSourceSHA256 = productionFingerprint,
	ProductionFingerprintScope = productionDirectories,
	TestSourceSHA256 = testFingerprint,
	TestFingerprintScope = { "scripts/**/*.luau", "tests/**/*.luau" },
	Tests = results,
	RobloxStudioTested = false,
	VisualAcceptanceValidated = false,
}
if not fs.isDir("build") then
	fs.writeDir("build")
end
local suffix = if selectedTest then "-" .. selectedTest else (if quick then "-quick" else "")
local output = "build/phase265-render-tests" .. suffix .. ".json"
fs.writeFile(output, serde.encode("json", report, true))
print(string.format("PASS: Phase 2.65 cloud-rendering (%d checks; %s)", checks, report.Mode))
print("Report: " .. output)
