--!strict

local Vector3 = require("@lune/roblox").Vector3

return function(root: any, loadModule: any, check: any, near: any, rejects: any)
	local Atmosphere = loadModule(root)
	local Grid3D = loadModule(root.Core.Grid3D)
	local grid = Grid3D.new(8, 6, 7, 12, Vector3.new(-48, 24, -42), { Dx = 40, Dy = 80, Dz = 100 })
	local function snapshot(simulation: any): any
		local captured = {
			State = simulation.State,
			Fields = simulation.State.Fields,
			Faces = simulation.Faces,
			Profile = simulation.Profile,
			Geometry = simulation.Geometry,
			Projection = simulation.Projection,
			Correction = simulation.Projection.Correction,
			CorrectionBytes = buffer.tostring(simulation.Projection.Correction),
			Last = simulation.Projection.Last,
			LastValues = table.clone(simulation.Projection.Last),
			Time = simulation.Time,
			Diagnostics = simulation:GetDiagnostics(),
			Buffers = {},
		}
		for _, field in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
			captured.Buffers[field] = {
				Buffer = simulation.State.Fields[field],
				Bytes = buffer.tostring(simulation.State.Fields[field]),
			}
		end
		for _, field in { "U", "V", "W" } do
			captured.Buffers[field] = {
				Buffer = simulation.Faces[field],
				Bytes = buffer.tostring(simulation.Faces[field]),
			}
		end
		return captured
	end
	local function unchanged(simulation: any, captured: any)
		for _, field in { "State", "Faces", "Profile", "Geometry", "Projection", "Time" } do
			check(
				simulation[field] == captured[field],
				"Failed step preserves committed simulation objects and clock"
			)
		end
		check(
			simulation.State.Fields == captured.Fields,
			"Failed step preserves the public field table"
		)
		for field, saved in captured.Buffers do
			local current = if field == "U"
					or field == "V"
					or field == "W"
				then simulation.Faces[field]
				else simulation.State.Fields[field]
			check(
				current == saved.Buffer and buffer.tostring(current) == saved.Bytes,
				"Failed step preserves every public physical buffer reference and byte"
			)
		end
		check(
			simulation.Projection.Correction == captured.Correction
				and buffer.tostring(simulation.Projection.Correction)
					== captured.CorrectionBytes,
			"Failed step restores the pressure warm-start buffer"
		)
		check(
			simulation.Projection.Last == captured.Last,
			"Failed step preserves the pressure diagnostics object"
		)
		for field, value in captured.LastValues do
			check(
				simulation.Projection.Last[field] == value,
				"Failed step restores pressure diagnostics values"
			)
		end
		local diagnostics = simulation:GetDiagnostics()
		for field, value in captured.Diagnostics do
			check(
				diagnostics[field] == value,
				"Failed step preserves public simulation diagnostics"
			)
		end
	end
	local function samePhysics(actual: any, expected: any)
		near(
			actual.Time,
			expected.Time,
			0,
			"Retry advances the same physical time as a fresh simulation"
		)
		for _, field in { "u", "v", "w", "theta", "qv", "qc", "qr", "pressure" } do
			check(
				buffer.tostring(actual.State.Fields[field])
					== buffer.tostring(expected.State.Fields[field]),
				"Retry matches a fresh simulation field snapshot exactly"
			)
		end
		for _, field in { "U", "V", "W" } do
			check(
				buffer.tostring(actual.Faces[field]) == buffer.tostring(expected.Faces[field]),
				"Retry matches a fresh authoritative face snapshot exactly"
			)
		end
		check(
			buffer.tostring(actual.Projection.Correction)
				== buffer.tostring(expected.Projection.Correction),
			"Retry restores reproducible pressure warm-start evolution"
		)
	end

	local failed =
		Atmosphere.new(grid, { BackgroundU = 0.5, ProjectionOptions = { MaxIterations = 1 } })
	local fresh = Atmosphere.new(grid, { BackgroundU = 0.5 })
	local beforeFailure = snapshot(failed)
	rejects(function()
		failed:Step(0.25)
	end, "Pressure iteration exhaustion fails the complete simulation step")
	unchanged(failed, beforeFailure)
	failed.Projection.MaxIterations = fresh.Projection.MaxIterations
	failed:Step(0.25)
	fresh:Step(0.25)
	samePhysics(failed, fresh)
	local forcedGrid = Grid3D.new(3, 4, 3, 12, Vector3.zero, { Dx = 0.03, Dy = 0.03, Dz = 0.03 })
	local function forcedFixture(): any
		local simulation = Atmosphere.new(forcedGrid, { MomentumOptions = { Viscosity = 0 } })
		simulation.State:SetCell("theta", 2, 2, 2, 340)
		simulation.State:SetCell("qv", 2, 2, 2, 0.01)
		return simulation
	end
	local forced = forcedFixture()
	local beforeForcedFailure = snapshot(forced)
	local success, failure = pcall(function()
		forced:Step(0.25)
	end)
	check(
		not success and string.find(tostring(failure), "Transport outgoing CFL", 1, true) ~= nil,
		"Post-force transport CFL failure occurs after momentum and projection"
	)
	unchanged(forced, beforeForcedFailure)
	forced:Step(0.125)
	local freshForced = forcedFixture()
	freshForced:Step(0.125)
	samePhysics(forced, freshForced)

	-- Force failure after the predictor, projection, and transport succeeded.
	-- theta=400 K is finite but beyond the liquid-water saturation domain.
	local thermalIndex = grid:Index(4, 3, 4)
	local validTheta = failed.State:Get("theta", thermalIndex)
	failed.State:Set("theta", thermalIndex, 400)
	local beforeLateFailure = snapshot(failed)
	rejects(function()
		failed:Step(0.25)
	end, "Late saturation failure rolls back the complete simulation step")
	unchanged(failed, beforeLateFailure)
	failed.State:Set("theta", thermalIndex, validTheta)
	failed:Step(0.25)
	fresh:Step(0.25)
	samePhysics(failed, fresh)
	print(
		"PASS: pressure and late-thermodynamic failure rollback preserve all committed buffers, time, diagnostics and pressure cache; retries match fresh evolution"
	)
end
