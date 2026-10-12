--!strict

-- Compare the same world numerical model against the frozen Phase 2.6 source.
-- All durations are native-host elapsed CPU/runtime observations. Instance spies
-- exercise production renderer work; they cannot measure Studio/GPU overdraw.
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local createLoader = require("../tests/RobloxModuleLoader")
local InstanceSpy = require("../tests/CloudRenderInstanceSpy")

local baselinePath: string? = nil
local selectedPreset: string? = nil
local quick = false
local argIndex = 1
while argIndex <= #process.args do
	local argument = process.args[argIndex]
	if argument == "--baseline" then
		assert(
			baselinePath == nil and process.args[argIndex + 1] ~= nil,
			"Provide one frozen baseline path"
		)
		baselinePath = process.args[argIndex + 1]
		argIndex += 1
	elseif argument == "--laptop" or argument == "--full" then
		assert(selectedPreset == nil, "Select at most one preset")
		selectedPreset = if argument == "--laptop" then "Laptop" else "Full"
	elseif argument == "--quick" then
		assert(not quick, "Provide --quick at most once")
		quick = true
	else
		error("Unknown benchmark argument: " .. argument)
	end
	argIndex += 1
end
assert(
	baselinePath ~= nil,
	"Usage: lune run scripts/benchmark-cloud-render-data.luau --baseline <frozen-phase26-repository> [--laptop|--full] [--quick]"
)
local frozenPath = baselinePath :: string
assert(
	fs.isFile(frozenPath .. "/src/shared/Atmosphere/World/WeatherField.lua"),
	"Baseline requires Phase 2.6 world modules"
)

local root, loadModule = createLoader("src/shared/Atmosphere")
local frozenRoot, loadFrozen = createLoader(frozenPath .. "/src/shared/Atmosphere")
local Coordinates = loadModule(root.World.WorldCoordinates)
local Field = loadModule(root.World.WeatherField)
local Sources = loadModule(root.World.WorldCloudSources)
local RenderSnapshot = loadModule(root.Rendering.CloudRenderSnapshot)
local Reconstruction = loadModule(root.Rendering.CloudDensityReconstruction)
local Surface = loadModule(root.Rendering.CloudSurfaceAnalysis)
local Detail = loadModule(root.Rendering.CloudDetailNoise)
local Config = loadModule(root.Rendering.CloudRenderConfig)
local Lighting = loadModule(root.Rendering.CloudLighting)
local OldSnapshot = loadFrozen(frozenRoot.World.WeatherSnapshot)
local FrozenCoordinates = loadFrozen(frozenRoot.World.WorldCoordinates)
local FrozenField = loadFrozen(frozenRoot.World.WeatherField)
local FrozenSources = loadFrozen(frozenRoot.World.WorldCloudSources)
local serverRoot, loadServer = createLoader("src/server/Simulation", {
	game = {
		GetService = function(_self: any, name: string): any
			assert(name == "ReplicatedStorage")
			return { Shared = { Atmosphere = root } }
		end,
	},
})
local frozenServerRoot, loadFrozenServer = createLoader(frozenPath .. "/src/server/Simulation", {
	game = {
		GetService = function(_self: any, name: string): any
			assert(name == "ReplicatedStorage")
			return { Shared = { Atmosphere = frozenRoot } }
		end,
	},
})
local RenderReplication = loadServer(serverRoot.CloudRenderReplication)
local OldReplication = loadFrozenServer(frozenServerRoot.WeatherReplication)
local WARMUP_STEPS = 8
local TIMED_STEPS = if quick then 40 else 232
local SEED = 84219
assert(Field.FixedDt == FrozenField.FixedDt, "Comparison requires matching fixed timestep")

local function statistics(values: { number }): any
	assert(#values > 0, "No benchmark samples")
	local ordered = table.clone(values)
	table.sort(ordered)
	local total = 0
	for _, value in ordered do
		total += value
	end
	return {
		Samples = #ordered,
		MeanMilliseconds = total / #ordered,
		MedianMilliseconds = ordered[math.ceil(#ordered * 0.5)],
		P95Milliseconds = ordered[math.ceil(#ordered * 0.95)],
		MaximumMilliseconds = ordered[#ordered],
	}
end

local function ownedBuffers(value: any, seen: { [any]: boolean }?): (number, number)
	local visited = seen or {}
	if visited[value] then
		return 0, 0
	end
	if typeof(value) == "buffer" then
		visited[value] = true
		return 1, buffer.len(value)
	elseif type(value) == "table" then
		visited[value] = true
		local count, bytes = 0, 0
		for _, child in value do
			local childCount, childBytes = ownedBuffers(child, visited)
			count += childCount
			bytes += childBytes
		end
		return count, bytes
	end
	return 0, 0
end

local function fingerprint(directory: string): string
	local paths = {}
	local function collect(relative: string)
		for _, name in fs.readDir(directory .. "/" .. relative) do
			local path = relative .. "/" .. name
			if fs.isDir(directory .. "/" .. path) then
				collect(path)
			elseif string.sub(path, -4) == ".lua" or string.sub(path, -5) == ".json" then
				table.insert(paths, path)
			end
		end
	end
	for _, folder in { "src/shared/Atmosphere", "src/server", "src/client" } do
		collect(folder)
	end
	table.sort(paths)
	local contents = {}
	for _, path in paths do
		table.insert(contents, path .. "\0" .. fs.readFile(directory .. "/" .. path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local function checksum(field: any): string
	local contents = {}
	for _, name in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
		table.insert(contents, name .. "\0" .. buffer.tostring(field.State.Fields[name]) .. "\0")
	end
	for _, name in { "U", "V", "W" } do
		table.insert(contents, name .. "\0" .. buffer.tostring(field.Faces[name]) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end

local productionFingerprint, frozenFingerprint = fingerprint("."), fingerprint(frozenPath)
local function benchmarkFingerprint(): string
	local contents = {}
	for _, path in
		{
			"scripts/benchmark-cloud-render-data.luau",
			"tests/RobloxModuleLoader.luau",
			"tests/CloudRenderInstanceSpy.luau",
		}
	do
		table.insert(contents, path .. "\0" .. fs.readFile(path) .. "\0")
	end
	return serde.hash("sha256", table.concat(contents))
end
local scriptFingerprint = benchmarkFingerprint()
local revision = string.gsub(process.exec("git", { "rev-parse", "HEAD" }).stdout, "%s+$", "")
local dirty = process.exec("git", { "status", "--porcelain" }).stdout ~= ""
local runs = {}
local presets = if selectedPreset then { selectedPreset } else { "Laptop", "Full" }
for _, preset in presets do
	local full = preset == "Full"
	for _, mode in { "FrozenPhase26", "Phase265" } do
		local coordinateModule = if mode == "FrozenPhase26" then FrozenCoordinates else Coordinates
		local fieldModule = if mode == "FrozenPhase26" then FrozenField else Field
		local sourceModule = if mode == "FrozenPhase26" then FrozenSources else Sources
		local coverage = sourceModule.GetCoverage("Scattered", full)
		local started = os.clock()
		local field = fieldModule.new(coordinateModule.new(), {
			SizeX = if full then 48 else 32,
			SizeY = 6,
			SizeZ = if full then 48 else 32,
			BackgroundU = 8,
			BackgroundV = 2,
			ShearU = 0,
			ShearV = 0,
			BackgroundRelativeHumidity = coverage.EnvironmentalRH,
		})
		local initMs = (os.clock() - started) * 1000
		started = os.clock()
		local manager = sourceModule.new(field, {
			Seed = SEED,
			Coverage = "Scattered",
			FullPreset = full,
			InitialSourceCount = coverage.InitialSourceCount,
			BuildSamplesPerStep = if full then 192 else 128,
			AutoClouds = true,
		})
		manager:InitializeSources()
		local sourceInitMs = (os.clock() - started) * 1000
		local count, bytes = ownedBuffers({ field, manager })
		assert(field:GetDiagnostics().QcSum == 0, "Production initial sources must not paint qc")
		table.insert(runs, {
			Preset = preset,
			Mode = mode,
			Field = field,
			Manager = manager,
			FieldInitMs = initMs,
			SourceInitMs = sourceInitMs,
			BufferCount = count,
			BufferBytes = bytes,
			CoreTimes = {},
			SourceTimes = {},
			CombinedTimes = {},
			MaximumSourceSamples = 0,
			MaximumCourant = 0,
			MaximumSubsteps = 1,
		})
	end
end

for tick = 1, WARMUP_STEPS + TIMED_STEPS do
	for position = 1, #runs do
		local index = ((position + tick - 2) % #runs) + 1
		if tick % 2 == 0 then
			index = #runs + 1 - index
		end
		local run = runs[index]
		local started = os.clock()
		if tick == 120 then
			run.Manager:QueueSource()
		end
		local forcing = run.Manager:PrepareStep(tick, Field.FixedDt)
		local sourceMs = (os.clock() - started) * 1000
		started = os.clock()
		run.Field:Step(Field.FixedDt, forcing)
		local coreMs = (os.clock() - started) * 1000
		started = os.clock()
		run.Manager:CommitStep(tick)
		sourceMs += (os.clock() - started) * 1000
		if tick > WARMUP_STEPS then
			table.insert(run.CoreTimes, coreMs)
			table.insert(run.SourceTimes, sourceMs)
			table.insert(run.CombinedTimes, coreMs + sourceMs)
		end
		run.MaximumSourceSamples = math.max(run.MaximumSourceSamples, run.Manager.SamplesLastStep)
		run.MaximumCourant = math.max(run.MaximumCourant, run.Field.MaxCourant)
		run.MaximumSubsteps = math.max(run.MaximumSubsteps, run.Field.Substeps)
	end
	if tick % 60 == 0 or tick == WARMUP_STEPS + TIMED_STEPS then
		for index = 1, #runs, 2 do
			assert(
				checksum(runs[index].Field) == checksum(runs[index + 1].Field),
				"Rendering release changed numerical trajectory"
			)
		end
	end
end

local numerical = {}
for _, run in runs do
	local count, bytes = ownedBuffers({ run.Field, run.Manager })
	assert(count == run.BufferCount and bytes == run.BufferBytes, "Owned numerical buffers grew")
	local row = {
		Preset = run.Preset,
		Mode = run.Mode,
		FixedDtSeconds = Field.FixedDt,
		SimulatedSeconds = run.Field.Time,
		Core = statistics(run.CoreTimes),
		SourcesOutsideCore = statistics(run.SourceTimes),
		Combined = statistics(run.CombinedTimes),
		FieldInitializationMilliseconds = run.FieldInitMs,
		SourceInitializationMilliseconds = run.SourceInitMs,
		BufferCount = count,
		BufferBytes = bytes,
		MaximumSourceSamplesPerStep = run.MaximumSourceSamples,
		MaximumCourant = run.MaximumCourant,
		MaximumSubsteps = run.MaximumSubsteps,
		ScalarUpdatesPerOneSubstep = run.Field.Count * 4,
		MicrophysicsCallsPerOneSubstep = run.Field.Count,
		ServerGridCells = run.Field.Count,
		FinalStateSHA256 = checksum(run.Field),
		Diagnostics = run.Field:GetDiagnostics(),
		Sources = run.Manager:GetDiagnostics(),
		DroppedSimulationTime = 0,
		DroppedTimeNote = "Direct fixed-step benchmark has no wall-frame accumulator; Studio dropped time requires profiling the controller",
	}
	table.insert(numerical, row)
	print(
		string.format(
			"%s %s step mean %.3f / median %.3f / p95 %.3f ms",
			row.Preset,
			row.Mode,
			row.Combined.MeanMilliseconds,
			row.Combined.MedianMilliseconds,
			row.Combined.P95Milliseconds
		)
	)
end

local dataResults = {}
local rendererResults = {}
local previewScenes = {}
local SAMPLE_COUNT = if quick then 512 else 2048
local BATCHES = if quick then 5 else 20
for _, run in runs do
	if run.Mode ~= "Phase265" then
		continue
	end
	local field, full = run.Field, run.Preset == "Full"
	local before = checksum(field)
	local legacyWorkspace = OldSnapshot.NewWorkspace(if full then 512 else 256)
	local meta = {
		SizeX = field.SizeX,
		SizeY = field.SizeY,
		SizeZ = field.SizeZ,
		Seed = SEED,
		Time = field.Time,
		WidthStuds = 4028,
		DepthStuds = 4028,
		StudsPerMeter = field.Coordinates.StudsPerMeter,
		MinXStuds = field.Coordinates.MinX,
		MinZStuds = field.Coordinates.MinZ,
		BottomYStuds = field.Coordinates.BottomStuds,
		LayerHeightStuds = field.Dy * field.Coordinates.StudsPerMeter,
	}
	local legacyEncode, renderEncode, decodeTimes = {}, {}, {}
	local payload, legacyPayload, snapshot = nil, nil, nil
	for sequence = 1, BATCHES do
		local started = os.clock()
		legacyPayload =
			OldSnapshot.Encode(field.Fields, meta, legacyWorkspace, 0.00001, field.ValueBytes)
		table.insert(legacyEncode, (os.clock() - started) * 1000)
		started = os.clock()
		payload = RenderSnapshot.Encode(field, {
			Seed = SEED,
			Generation = 1,
			Sequence = sequence,
			Time = field.Time,
			WallTime = sequence,
		})
		table.insert(renderEncode, (os.clock() - started) * 1000)
		started = os.clock()
		snapshot = RenderSnapshot.Decode(payload)
		table.insert(decodeTimes, (os.clock() - started) * 1000)
	end
	local current = snapshot :: any
	local oldDecoded = OldSnapshot.Decode(legacyPayload :: buffer)
	local voxelSpy = InstanceSpy.Create()
	local ActualFrozenVoxel = voxelSpy:LoadVoxel(
		frozenRoot,
		loadFrozen,
		frozenPath .. "/src/shared/Atmosphere/World/WorldVoxelDebugRenderer.lua"
	)
	local frozenVoxelRenderer = ActualFrozenVoxel.new(if full then 512 else 256)
	local oldRendererTimes = {}
	for _ = 1, (if quick then 20 else 80) do
		local started = os.clock()
		frozenVoxelRenderer:Update(oldDecoded, oldDecoded, 1)
		table.insert(oldRendererTimes, (os.clock() - started) * 1000)
	end
	local oldVoxelDescriptors = {}
	for _, part in frozenVoxelRenderer.Pool do
		if part.Transparency < 1 then
			table.insert(oldVoxelDescriptors, {
				X = part.Position.X,
				Y = part.Position.Y,
				Z = part.Position.Z,
				SizeX = part.Size.X,
				SizeY = part.Size.Y,
				SizeZ = part.Size.Z,
				Opacity = 1 - part.Transparency,
			})
		end
	end
	local legacyRendererResult = {
		Preset = run.Preset,
		Mode = "FrozenPhase26Voxels",
		Fixture = "Same naturally condensed final field encoded as the legacy sparse diagnostic packet",
		ScheduledUpdates = statistics(oldRendererTimes),
		RefreshHz = 5,
		VisibleParts = frozenVoxelRenderer.Visible,
		AllocatedVoxelParts = #frozenVoxelRenderer.Pool,
		InstanceSpy = voxelSpy:GetDiagnostics(),
		RobloxGPUOrInstanceCostMeasured = false,
	}
	table.insert(rendererResults, legacyRendererResult)
	frozenVoxelRenderer:Destroy()
	assert(
		voxelSpy:GetDiagnostics().LiveInstances == 0,
		"Frozen voxel renderer benchmark leaked resources"
	)
	local broadcastBytes = 0
	local function transport(): any
		return {
			Broadcast = function(data: buffer)
				broadcastBytes += buffer.len(data)
			end,
			SetRequestHandler = function(_handler: any) end,
			Destroy = function() end,
		}
	end
	local renderReplication = RenderReplication.new(field, { Seed = SEED, RateHz = 1 }, transport())
	local oldReplication = OldReplication.new(field, {
		Seed = SEED,
		MaxRecords = if full then 512 else 256,
		RateHz = if full then 2 else 1,
		Threshold = 0.00001,
	}, transport())
	local publicationTimes, oldPublicationTimes = {}, {}
	for _ = 1, BATCHES do
		local started = os.clock()
		renderReplication:Publish()
		table.insert(publicationTimes, (os.clock() - started) * 1000)
		started = os.clock()
		oldReplication:Publish()
		table.insert(oldPublicationTimes, (os.clock() - started) * 1000)
	end
	local publicationDiagnostics = renderReplication:GetDiagnostics()
	renderReplication:Destroy()
	oldReplication:Destroy()
	local maxError, sumSquare, actualNonzero, quantizedZero = 0, 0, 0, 0
	for index = 1, field.Count do
		local actual = buffer.readf64(field.Fields.qc, (index - 1) * 8)
		local rendered, known = RenderSnapshot.ReadQC(current, index)
		assert(known, "Complete render lattice lost a neighborhood sample")
		local difference = math.abs(rendered - actual)
		maxError = math.max(maxError, difference)
		sumSquare += difference * difference
		if actual > 0 then
			actualNonzero += 1
			if rendered == 0 then
				quantizedZero += 1
			end
		end
	end
	local reconstruction = Reconstruction.new()
	local previous = RenderSnapshot.Decode(RenderSnapshot.Encode(field, {
		Seed = SEED,
		Generation = 1,
		Sequence = BATCHES - 1,
		Time = math.max(0, field.Time - 1),
		WallTime = BATCHES - 1,
	}))
	assert(
		reconstruction:Push(previous, 0) and reconstruction:Push(current, 1),
		"Benchmark reconstruction rejected valid packets"
	)
	local surface = Surface.new()
	local surfaceTimes = {}
	for _ = 1, BATCHES do
		surface:Reset()
		local started = os.clock()
		surface:Update(current)
		table.insert(surfaceTimes, (os.clock() - started) * 1000)
	end
	local parameters = Detail.Create(SEED)
	local quality = Config.GetQuality("Balanced")
	local reconstructionTimes, detailTimes, gradientTimes, lightingTimes = {}, {}, {}, {}
	local guard = 0
	for _ = 1, BATCHES do
		local started = os.clock()
		for sample = 1, SAMPLE_COUNT do
			local x = current.MinXStuds + ((sample * 47) % 997 + 0.5) / 997 * current.WidthStuds
			local z = current.MinZStuds + ((sample * 79) % 991 + 0.5) / 991 * current.DepthStuds
			local y = current.BottomYStuds
				+ ((sample * 31) % 127 + 0.5) / 127 * current.LayerHeightStuds * current.SizeY
			guard += reconstruction:SampleDensity(x, y, z, 1.5)
		end
		table.insert(reconstructionTimes, (os.clock() - started) * 1000)
		started = os.clock()
		for sample = 1, SAMPLE_COUNT do
			guard += Detail.Sample(
				parameters,
				sample * 1.1 - 1000,
				450 + sample % 120,
				sample * 2.3 - 2000,
				(sample % 100) / 100,
				0.5,
				quality
			)
		end
		table.insert(detailTimes, (os.clock() - started) * 1000)
		started = os.clock()
		for sample = 1, math.floor(SAMPLE_COUNT / 8) do
			local gx, gy, gz = reconstruction:Gradient(
				current.MinXStuds + sample * 11,
				480,
				current.MinZStuds + sample * 17,
				1.5
			)
			guard += gx + gy + gz
		end
		table.insert(gradientTimes, (os.clock() - started) * 1000)
		started = os.clock()
		for sample = 1, SAMPLE_COUNT do
			local a, b, c =
				Lighting.Shade(0.5, (sample % 100) / 100, 0.001, -0.002, 0.001, 0.2, 0.9, 0.3, 0.5)
			guard += a + b + c
		end
		table.insert(lightingTimes, (os.clock() - started) * 1000)
	end
	assert(guard == guard and math.abs(guard) < math.huge, "Nonfinite render benchmark result")
	assert(checksum(field) == before, "Encoding/reconstruction/detail mutated atmospheric buffers")
	local peakCell, peakQc = 1, -1
	for index = 1, field.Count do
		local value = buffer.readf64(field.Fields.qc, (index - 1) * 8)
		if value > peakQc then
			peakCell, peakQc = index, value
		end
	end
	-- A global centroid can lie in clear space between separate clouds. The
	-- actual maximum-liquid cell provides a reproducible cloudy camera anchor.
	local cx, cy, cz = RenderSnapshot.CellCenter(current, peakCell)
	local views = {
		{ Name = "Ground", X = cx, Y = 70, Z = cz + 1000, LookX = 0, LookY = 0.4, LookZ = -0.9165 },
		{
			Name = "Side",
			X = cx + 650,
			Y = cy,
			Z = cz + 700,
			LookX = -0.7071,
			LookY = 0,
			LookZ = -0.7071,
		},
		{ Name = "Above", X = cx, Y = 800, Z = cz, LookX = 0, LookY = -1, LookZ = 0 },
		{
			Name = "Close",
			X = cx + 150,
			Y = cy,
			Z = cz + 150,
			LookX = -0.7071,
			LookY = 0,
			LookZ = -0.7071,
		},
		{ Name = "Inside", X = cx, Y = cy, Z = cz, LookX = 1, LookY = 0, LookZ = 0 },
	}
	for _, qualityName in { "Mobile", "Balanced", "High", "Ultra" } do
		for _, view in views do
			local spy = InstanceSpy.Create()
			local ActualRenderer = spy:Load(root, loadModule)
			local renderReconstruction = Reconstruction.new()
			assert(
				renderReconstruction:Push(current, 0),
				"Renderer benchmark rejected complete natural cloud"
			)
			local renderer = ActualRenderer.new(renderReconstruction, {
				Quality = qualityName,
				Factory = spy.Factory,
				Parent = spy.Workspace,
			})
			local allFrames, activeFrames = {}, {}
			local frames = if quick then 240 else 960
			local maxActive, maxInstances, maxWritesPerFrame = 0, 0, 0
			local sequence = BATCHES + 1
			for frameIndex = 1, frames do
				local wall = frameIndex / 60
				if frameIndex % 60 == 0 then
					-- Hold the actual final qc field and SIMULATION time fixed, as
					-- a paused server does. Wall heartbeat packets prevent stale fade.
					local held = RenderSnapshot.Decode(RenderSnapshot.Encode(field, {
						Seed = SEED,
						Generation = 1,
						Sequence = sequence,
						Time = field.Time,
						WallTime = BATCHES + wall,
					}))
					assert(
						renderReconstruction:Push(held, wall),
						"Renderer benchmark packet sequence rejected"
					)
					sequence += 1
				end
				local previousUpdates = renderer.TotalUpdates
				local previousWrites = spy:GetDiagnostics().PropertyWrites
				local started = os.clock()
				renderer:Update(
					wall,
					1 / 60,
					view,
					{ SunX = 0.2, SunY = 0.9, SunZ = 0.3, Ambient = 0.5 }
				)
				local elapsed = (os.clock() - started) * 1000
				table.insert(allFrames, elapsed)
				if renderer.TotalUpdates ~= previousUpdates then
					table.insert(activeFrames, elapsed)
				end
				maxActive = math.max(maxActive, renderer.Pool.ActiveCount)
				local spyDiagnostics = spy:GetDiagnostics()
				maxInstances = math.max(maxInstances, spyDiagnostics.LiveInstances)
				maxWritesPerFrame =
					math.max(maxWritesPerFrame, spyDiagnostics.PropertyWrites - previousWrites)
			end
			local rendererDiagnostics, spyDiagnostics =
				renderer:GetDiagnostics(), spy:GetDiagnostics()
			local _, packedBytes = ownedBuffers(renderer)
			local row = {
				Preset = run.Preset,
				Quality = qualityName,
				CameraView = view.Name,
				Fixture = "Actual naturally condensed final field, held at paused simulation time while wall snapshots continue",
				FrameCalls = frames,
				SimulatedRenderWallSeconds = frames / 60,
				EveryFrameCall = statistics(allFrames),
				ScheduledUpdates = statistics(activeFrames),
				MaximumActiveProxies = maxActive,
				MaximumActiveCubes = maxActive,
				Primitive = "Actual three-dimensional equal-axis Block Part",
				CameraCloudAnchor = { Cell = peakCell, Qc = peakQc, X = cx, Y = cy, Z = cz },
				MaximumLiveSpyInstances = maxInstances,
				MaximumPropertyWritesPerFrameCall = maxWritesPerFrame,
				PackedBytesIncludingRetainedRenderPackets = packedBytes,
				Diagnostics = rendererDiagnostics,
				InstanceSpy = spyDiagnostics,
				RobloxGPUOrInstanceCostMeasured = false,
			}
			table.insert(rendererResults, row)
			if run.Preset == "Laptop" and qualityName == "Ultra" and view.Name == "Above" then
				local descriptors = {}
				for id, proxy in renderer.Pool.Active do
					if proxy.Opacity > 0 then
						local part = proxy.Part or proxy.Anchor
						assert(
							part.ClassName == "Part" and part.Shape == "Block",
							"Cloud preview must describe actual three-dimensional Block Parts"
						)
						assert(
							part.Size.X > 0
								and part.Size.X == part.Size.Y
								and part.Size.Y == part.Size.Z,
							"Cloud preview requires equal XYZ cube dimensions"
						)
						table.insert(descriptors, {
							Id = id,
							X = part.Position.X,
							Y = part.Position.Y,
							Z = part.Position.Z,
							SizeX = part.Size.X,
							SizeY = part.Size.Y,
							SizeZ = part.Size.Z,
							Opacity = 1 - part.Transparency,
							R = part.Color.R,
							G = part.Color.G,
							B = part.Color.B,
							Shape = part.Shape,
						})
					end
				end
				table.sort(descriptors, function(a: any, b: any): boolean
					return a.Id < b.Id
				end)
				table.insert(previewScenes, {
					Preset = run.Preset,
					Quality = qualityName,
					Source = "Actual production renderer and naturally condensed final qc field",
					Camera = view,
					SimulatedSeconds = field.Time,
					WorldBounds = {
						MinX = current.MinXStuds,
						MinZ = current.MinZStuds,
						Width = current.WidthStuds,
						Depth = current.DepthStuds,
						Bottom = current.BottomYStuds,
						Top = current.BottomYStuds + current.LayerHeightStuds * current.SizeY,
					},
					Cubes = descriptors,
					Geometry = "Actual supported Roblox Block Parts with equal positive XYZ dimensions; no billboards, images, particles, balls or Gaussian proxies",
					DiagnosticVoxels = oldVoxelDescriptors,
					Diagnostics = rendererDiagnostics,
				})
			end
			renderer:Destroy()
			assert(
				spy:GetDiagnostics().LiveInstances == 0,
				"Renderer benchmark shutdown leaked resources"
			)
		end
	end
	assert(checksum(field) == before, "Renderer benchmark mutated atmospheric buffers")
	table.insert(dataResults, {
		Preset = run.Preset,
		SnapshotFixture = "Actual naturally condensed field after numerical scenario; previous packet repeats it with prior metadata solely to exercise temporal interpolation",
		SparsePhase26 = {
			Encode = statistics(legacyEncode),
			PublicationWithTransportSpy = statistics(oldPublicationTimes),
			Bytes = buffer.len(legacyPayload :: buffer),
			Records = oldDecoded.Count,
			AboveDiagnosticThreshold = oldDecoded.AboveThreshold,
			CompleteNeighborhoodsGuaranteed = false,
			BytesPerSecondBeforeProtocolOverhead = buffer.len(legacyPayload :: buffer)
				* (if full then 2 else 1),
		},
		CompletePhase265 = {
			Encode = statistics(renderEncode),
			Decode = statistics(decodeTimes),
			PublicationWithTransportSpy = statistics(publicationTimes),
			PublicationDiagnostics = publicationDiagnostics,
			Bytes = buffer.len(payload :: buffer),
			PublicationHz = 1,
			BytesPerSecondBeforeProtocolOverhead = buffer.len(payload :: buffer),
			Cells = current.Count,
			VelocityCells = current.VelocityCount,
			CompleteNeighborhoodsGuaranteed = current.Complete,
			MaxQuantizationErrorKgPerKg = maxError,
			RMSEKgPerKg = math.sqrt(sumSquare / field.Count),
			ActualNonzeroCells = actualNonzero,
			NonzeroValuesQuantizedToKnownZero = quantizedZero,
		},
		DensitySamplesPerBatch = SAMPLE_COUNT,
		GradientSamplesPerBatch = math.floor(SAMPLE_COUNT / 8),
		DensityReconstruction = statistics(reconstructionTimes),
		DetailNoiseBalanced = statistics(detailTimes),
		Gradient = statistics(gradientTimes),
		Lighting = statistics(lightingTimes),
		SurfaceConstruction = statistics(surfaceTimes),
		SurfacePackedBytes = surface:GetStorageBytes(),
		RetainedCompletePacketBytesForTwoSnapshots = buffer.len(payload :: buffer) * 2,
		RenderChangesAuthoritativeField = false,
	})
	print(
		string.format(
			"%s complete snapshot %d B; encode %.3f / decode %.3f ms; density %d samples %.3f ms",
			run.Preset,
			buffer.len(payload :: buffer),
			statistics(renderEncode).MeanMilliseconds,
			statistics(decodeTimes).MeanMilliseconds,
			SAMPLE_COUNT,
			statistics(reconstructionTimes).MeanMilliseconds
		)
	)
end

assert(
	fingerprint(".") == productionFingerprint,
	"Production source changed during benchmark; rerun on stable source"
)
assert(fingerprint(frozenPath) == frozenFingerprint, "Frozen Phase 2.6 baseline changed")
assert(benchmarkFingerprint() == scriptFingerprint, "Benchmark changed while running")
local report = {
	Schema = 1,
	Suite = "Phase 2.65 numerical regression and cloud render-data benchmark",
	RendererImplementation = "Corrected 3D Block cubes; supersedes historical billboard/puff prototype",
	Mode = if quick then "quick" else "full",
	SourceRevision = revision,
	WorkingTreeChanged = dirty,
	ProductionSourceSHA256 = productionFingerprint,
	FrozenProductionSourceSHA256 = frozenFingerprint,
	BenchmarkSourceSHA256 = scriptFingerprint,
	FrozenBaseline = frozenPath,
	FrozenBaselineCommit = "bba3a693f5c01f5425488959e06bb68778995e6b",
	Timing = "Lune host elapsed os.clock milliseconds; not Roblox Studio FPS/GPU overdraw or real Instance creation cost",
	WarmupSteps = WARMUP_STEPS,
	TimedSteps = TIMED_STEPS,
	WorldSeed = SEED,
	WindUMetersPerSecond = 8,
	WindVMetersPerSecond = 2,
	NumericalTrajectoriesByteIdenticalToFrozenPhase26 = true,
	Numerical = numerical,
	RenderData = dataResults,
	RendererInstanceBoundaryCPU = rendererResults,
	RobloxStudioTested = false,
	VisualAcceptanceValidated = false,
	HardwareFPSTested = false,
	RendererGPUOverdrawMeasured = false,
}
if not fs.isDir("build") then
	fs.writeDir("build")
end
local output = if quick
	then "build/phase265-render-benchmark-quick.json"
	else "build/phase265-render-benchmark.json"
fs.writeFile(output, serde.encode("json", report, true))
fs.writeFile(
	"build/phase265-cube-preview.json",
	serde.encode("json", {
		Schema = 1,
		SourceRevision = revision,
		ProductionSourceSHA256 = productionFingerprint,
		Note = "Actual production Block Part geometry descriptors; any offline preview must project XYZ cube faces and must not substitute Gaussian discs, sprites or spheres. This is not Roblox Studio/GPU visual acceptance.",
		Scenes = previewScenes,
	}, true)
)
print("Report: " .. output)
