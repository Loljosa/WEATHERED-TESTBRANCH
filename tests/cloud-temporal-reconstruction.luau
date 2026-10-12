--!strict

local fixture = require("./CloudRenderFixture")

return function(root: any, load: any, check: any, near: any, rejects: any, _quick: boolean?)
	local Reconstruction = load(root.Rendering.CloudDensityReconstruction)
	local Codec = load(root.Rendering.CloudRenderSnapshot)
	local function packet(
		sequence: number,
		time: number,
		wall: number,
		value: number,
		generation: number?,
		seed: number?
	): any
		return fixture(root, load, {
			QC = function()
				return value
			end,
		}, {
			Seed = seed or 84219,
			Generation = generation or 1,
			Sequence = sequence,
			Time = time,
			WallTime = wall,
		})
	end
	local model = Reconstruction.new({ VelocityAssist = false, StaleAfter = 10, StaleFade = 20 })
	local first = packet(1, 0, 0, 0.00001)
	local second = packet(2, 4, 1, 0.00004)
	check(model:Push(first, 100), "Late join immediately accepts complete current weather")
	local qa = Codec.ReadQC(first, 1)
	local qb = Codec.ReadQC(second, 1)
	near(
		model:SampleQC(0, 480, 0, 100),
		qa,
		1e-19,
		"First snapshot has no artificial wait for earlier cloud history"
	)
	check(model:Push(second, 101), "Increasing sequence accepted")
	near(model:SampleQC(0, 480, 0, 101), qa, 1e-19, "Temporal playback starts at preceding packet")
	near(
		model:SampleQC(0, 480, 0, 101.5),
		(qa + qb) / 2,
		1e-19,
		"Wall interval controls interpolation independently of simulation speed"
	)
	near(
		model:GetTemporalState(101.5).Time,
		2,
		1e-14,
		"Four simulated seconds interpolate across one wall second"
	)
	near(model:SampleQC(0, 480, 0, 102), qb, 1e-19, "Playback reaches latest known cloud field")
	near(
		model:SampleQC(0, 480, 0, 105),
		qb,
		1e-19,
		"Lost packet freezes endpoint without indefinite extrapolation"
	)
	check(not model:Push(first, 105), "Out-of-order older sequence rejected")
	check(not model:Push(second, 105), "Duplicate sequence rejected")
	local reversed = packet(3, 3, 2, 0.00003)
	check(not model:Push(reversed, 105), "Same-generation simulation-time regression rejected")
	local wallReversed = packet(3, 5, 0.5, 0.00003)
	check(
		not model:Push(wallReversed, 105),
		"Same-generation server wall-clock regression rejected"
	)
	local pause = packet(3, 4, 2, 0.00004)
	check(model:Push(pause, 106), "Paused time accepts new sequence for late join and diagnostics")
	near(
		model:GetTemporalState(106.5).Time,
		4,
		0,
		"Pause cannot advance physical interpolation timeline"
	)
	near(model:SampleQC(0, 480, 0, 106.5), qb, 1e-19, "Pause does not erase cloud support")
	near(
		model:SampleQC(0, 480, 0, 136),
		0,
		0,
		"Disconnected stale visual data fades out within a finite 30-second bound"
	)
	check(
		model:GetTemporalState(121).StaleFade > 0 and model:GetTemporalState(121).StaleFade < 1,
		"Temporary stale fallback uses a smooth bounded fade"
	)
	local reset = packet(1, 0, 0, 0, 2, -1)
	check(model:Push(reset, 137), "Explicit regenerated world accepts reset sequence and timeline")
	check(
		model.Previous == nil,
		"Incompatible generation and seed invalidate all interpolation history"
	)
	near(
		model:SampleQC(0, 480, 0, 137),
		0,
		0,
		"Regeneration never blends old clouds into newly clear world"
	)
	check(not model:Push(second, 138), "Old generation cannot return after regeneration")
	local seeded = packet(2, 1, 1, 0.00002, 2, 0)
	check(model:Push(seeded, 138), "Changed canonical seed is accepted only with a newer packet")
	check(model.Previous == nil, "Seed change invalidates stable visual history")
	model:Reset()
	near(model:SampleDensity(0, 480, 0, 139), 0, 0, "Renderer reset clears visible cloud support")
	check(model.Current == nil and model.Previous == nil, "Reset drops both packet references")
	local lifecycle = Reconstruction.new({ VelocityAssist = false })
	lifecycle:Push(second, 0)
	local clear = packet(3, 5, 2, 0)
	lifecycle:Push(clear, 1)
	check(
		lifecycle:SampleDensity(0, 480, 0, 1.5) > 0,
		"Evaporation fades through endpoint interpolation"
	)
	near(
		lifecycle:SampleDensity(0, 480, 0, 2),
		0,
		0,
		"Clear authoritative endpoint releases all optical density"
	)
	local geometryChanged = fixture(
		root,
		load,
		{ SizeX = 12 },
		{ Seed = 84219, Generation = 1, Sequence = 4, Time = 6, WallTime = 3 }
	)
	check(lifecycle:Push(geometryChanged, 2), "New complete geometry can replace prior packet")
	check(lifecycle.Previous == nil, "Changed geometry invalidates interpolation neighborhoods")
	local movingOld, oldField = fixture(root, load, {
		U = 8,
		V = 2,
		QC = function(x: number, _y: number, z: number)
			return if x == 4 and z == 4 then 0.00005 else 0
		end,
	}, { Seed = 84219, Generation = 1, Sequence = 1, Time = 0, WallTime = 0 })
	for _ = 1, 4 do
		oldField:Step(0.25)
	end
	local movingNew = Codec.Decode(
		Codec.Encode(
			oldField,
			{ Seed = 84219, Generation = 1, Sequence = 2, Time = 1, WallTime = 1 }
		)
	)
	local moving = Reconstruction.new()
	local staticOld, staticNew =
		Reconstruction.new({ VelocityAssist = false }),
		Reconstruction.new({ VelocityAssist = false })
	moving:Push(movingOld, 0)
	moving:Push(movingNew, 1)
	staticOld:Push(movingOld, 0)
	staticNew:Push(movingNew, 0)
	local u, v, w = moving:SampleVelocity(0, 480, 0, 1.5)
	near(u, 8, 0.001, "Velocity interpolation retains physical m/s X axis")
	near(v, 2, 0.001, "Velocity interpolation retains physical m/s Z axis")
	near(w, 0, 0.001, "Vertical m/s uses w rather than horizontal v")
	local x, y, z = Codec.CellCenter(movingOld, 4 + 3 * 8 + 2 * 64)
	local expectedWarp = 0.5 * staticOld:SampleQC(x - u, y, z - v, 0)
		+ 0.5 * staticNew:SampleQC(x + u, y, z + v, 0)
	-- dt=1s * alpha=.5 * TWO studs/m => offset = u or v studs.
	near(
		moving:SampleQC(x, y, z, 1.5),
		expectedWarp,
		1e-18,
		"Velocity assistance uses bounded backward/forward tracing with explicit stud conversion"
	)
	local saved = buffer.tostring(oldField.Fields.qc)
	for index = 1, 1000 do
		local value = moving:SampleDensity(x + index % 17, y, z, 1 + index / 1000)
		check(
			value >= 0 and value <= 1 and value == value,
			"Flow-coherent temporal samples stay finite and bounded"
		)
	end
	check(
		buffer.tostring(oldField.Fields.qc) == saved,
		"Temporal flow reconstruction never modifies physical transport buffers"
	)
	local rising = Reconstruction.new()
	local risingOld = fixture(root, load, {
		W = 2,
		QC = function()
			return 0.00002
		end,
	}, { Seed = 84219, Generation = 1, Sequence = 1, Time = 0, WallTime = 0 })
	local risingNew = fixture(root, load, {
		W = 2,
		QC = function()
			return 0.00002
		end,
	}, { Seed = 84219, Generation = 1, Sequence = 2, Time = 1, WallTime = 1 })
	rising:Push(risingOld, 0)
	rising:Push(risingNew, 1)
	for _, yOutside in { 423, 424, 568, 569 } do
		near(
			rising:SampleDensity(0, yOutside, 0, 1.5),
			0,
			0,
			"Vertical velocity assistance cannot extend the physical atmosphere"
		)
	end
	check(
		rising:SampleDensity(0, 567.99, 0, 1.5) < rising:SampleDensity(0, 567, 0, 1.5),
		"Query-position support taper remains continuous under vertical warp"
	)
	rejects(function()
		moving:Push(movingNew, 0 / 0)
	end, "NaN receipt time rejected explicitly")
	rejects(function()
		moving:SampleQC(0, 480, 0, 0 / 0)
	end, "NaN playback time rejected explicitly")
	return {
		PlaybackDelay = "one authoritative packet interval",
		StaleAfterWallSeconds = 10,
		StaleFadeWallSeconds = 20,
		MaxVisualAdvectionSeconds = moving.MaxVisualAdvectionSeconds,
		Accepted = model.Accepted,
		Rejected = model.Rejected,
	}
end
