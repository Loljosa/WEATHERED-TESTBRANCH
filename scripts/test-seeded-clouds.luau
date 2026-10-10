--!strict

-- Focused Phase 2.5 production-module checks. The main test runner also calls
-- these modules; --quick shortens evolution scenarios without replacing physics.
local process = require("@lune/process")
local createLoader = require("../tests/RobloxModuleLoader")
local root, loadModule = createLoader("src/shared/Atmosphere")
assert(
	#process.args == 0 or (#process.args == 1 and process.args[1] == "--quick"),
	"Usage: lune run scripts/test-seeded-clouds.luau [--quick]"
)
local quick = process.args[1] == "--quick"
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

require("../tests/seeded-cloud-generation")(root, loadModule, check, near, rejects)
require("../tests/seeded-source-manager")(root, loadModule, check, near, rejects)
require("../tests/seeded-cloud-controls")(root, loadModule, check, near, rejects)
require("../tests/multi-cloud-evolution")(root, loadModule, check, near, rejects, quick)
print(
	string.format(
		"PASS: Phase 2.5 seeded generation, scheduling, commands and evolution (%d checks; %s)",
		checks,
		if quick then "quick" else "full"
	)
)
