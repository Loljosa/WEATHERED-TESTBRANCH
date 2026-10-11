--!strict

-- Run real Phase 2.6 modules through the same Roblox require shim as the older
-- suites. --quick shortens long integration runs; it never substitutes physics.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local createLoader = require("../tests/RobloxModuleLoader")

assert(
	#process.args == 0 or (#process.args == 1 and process.args[1] == "--quick"),
	"Usage: lune run scripts/test-world-weather.luau [--quick]"
)
local quick = process.args[1] == "--quick"
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
	"world-weather-coverage",
	"cross-region-transport",
	"cloud-motion",
	"world-cloud-generation",
	"multiplayer-weather-consistency",
	"atmospheric-coupling",
	"world-weather-controls",
	"world-weather-bootstrap",
}
for _, name in tests do
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
check(
	fingerprint(productionDirectories, { ".lua", ".json" }) == productionFingerprint,
	"Production files changed while world-weather tests were running; rerun on a stable source tree"
)
check(
	fingerprint({ "scripts", "tests" }, { ".luau" }) == testFingerprint,
	"Test files changed while world-weather tests were running; rerun on a stable test tree"
)
local report = {
	Schema = 1,
	Suite = "Phase 2.6 world-weather production modules",
	Mode = if quick then "quick" else "full",
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
}
if not fs.isDir("build") then
	fs.writeDir("build")
end
local output = if quick
	then "build/phase26-world-tests-quick.json"
	else "build/phase26-world-tests.json"
fs.writeFile(output, serde.encode("json", report, true))
print(string.format("PASS: Phase 2.6 world-weather (%d checks; %s)", checks, report.Mode))
print("Report: " .. output)
