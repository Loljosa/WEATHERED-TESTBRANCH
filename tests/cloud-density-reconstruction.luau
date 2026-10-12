--!strict

local fixture = require("./CloudRenderFixture")

return function(root: any, load: any, check: any, near: any, rejects: any, _quick: boolean?)
	local Reconstruction = load(root.Rendering.CloudDensityReconstruction)
	local Codec = load(root.Rendering.CloudRenderSnapshot)
	local reconstruct = Reconstruction.new({ VelocityAssist = false })
	near(reconstruct:SampleDensity(0, 480, 0, 0), 0, 0, "No snapshot produces no cloud")
	local empty, field = fixture(root, load)
	local before = buffer.tostring(field.Fields.qc)
	check(reconstruct:Push(empty, 0), "Complete empty snapshot is accepted")
	for y = 420, 580, 4 do
		for x = -2200, 2200, 200 do
			near(
				reconstruct:SampleDensity(x, y, -1010, 0),
				0,
				0,
				"Empty complete field stays exactly empty"
			)
		end
	end
	check(
		buffer.tostring(field.Fields.qc) == before,
		"Empty reconstruction does not mutate server qc"
	)
	local uniform = fixture(root, load, {
		QC = function()
			return 0.00002
		end,
	})
	local isolated = Reconstruction.new({ VelocityAssist = false })
	check(isolated:Push(uniform, 0), "Uniform complete packet accepted")
	local quantized = Codec.ReadQC(uniform, 1)
	local expected = 1 - math.exp(-quantized / 0.00005)
	for z = -2000, 2000, 161 do
		for x = -2000, 2000, 157 do
			near(
				isolated:SampleQC(x, 480, z, 0),
				quantized,
				1e-19,
				"Trilinear reconstruction preserves uniform interior qc"
			)
			near(
				isolated:SampleDensity(x, 480, z, 0),
				expected,
				1e-14,
				"Shared fixed density mapping preserves uniform appearance"
			)
		end
	end
	near(
		isolated:SampleDensity(0, 423.99, 0, 0),
		0,
		0,
		"No display density below physical cloud domain"
	)
	near(
		isolated:SampleDensity(0, 568.01, 0, 0),
		0,
		0,
		"No display density above physical cloud domain"
	)
	near(
		isolated:SampleDensity(0, 424, 0, 0),
		0,
		0,
		"Sealed bottom smoothly closes display support"
	)
	near(isolated:SampleDensity(0, 568, 0, 0), 0, 0, "Sealed top smoothly closes display support")
	check(
		isolated:SampleDensity(0, 425, 0, 0) < isolated:SampleDensity(0, 430, 0, 0),
		"Outer vertical half-cell smoothly fades without stretching depth"
	)
	local variable, variableField = fixture(root, load, {
		QC = function(x: number, y: number, z: number)
			return if x >= 3
					and x <= 5
					and z >= 3
					and z <= 5
					and y >= 2
					and y <= 4
				then (x + y + z) * 0.000002
				else 0
		end,
	})
	local variableBefore = buffer.tostring(variableField.Fields.qc)
	local variablePacketBefore = buffer.tostring(variable.Payload)
	local model = Reconstruction.new({ VelocityAssist = false })
	model:Push(variable, 0)
	local maximum = variable.MaxQc
	local previous = model:SampleQC(-500, 490, 0, 0)
	local maximumJump = 0
	for x = -499, 499 do
		local value = model:SampleQC(x, 490, 0, 0)
		check(
			value == value and value >= 0 and value <= maximum * (1 + 1e-7),
			"Nonuniform interpolation stays finite, nonnegative and within packet bounds"
		)
		local density = model:SampleDensity(x, 490, 0, 0)
		check(density >= 0 and density <= 1, "Normalized display density remains bounded")
		maximumJump = math.max(maximumJump, math.abs(value - previous))
		previous = value
	end
	check(maximumJump < maximum / 100, "Cloud edges have gradients rather than abrupt tile cuts")
	for _, seam in { -1007, 0, 1007 } do
		near(
			model:SampleQC(seam - 0.000001, 490, 0, 0),
			model:SampleQC(seam + 0.000001, 490, 0, 0),
			1e-12,
			"Internal logical region crossing has no reconstruction seam"
		)
	end
	near(
		model:SampleQC(-2014, 490, 0, 0),
		model:SampleQC(2014, 490, 0, 0),
		0,
		"Periodic fullworld outer edges have identical sampling"
	)
	near(
		model:SampleQC(-1900, 490, 0, 0),
		model:SampleQC(2128, 490, 0, 0),
		1e-19,
		"Only full-world width wraps sampling"
	)
	local gx, gy, gz = model:Gradient(0, 490, 0, 0)
	check(gx == gx and gy == gy and gz == gz, "Three-axis gradients are finite numeric values")
	check(
		math.abs(gx) < 1 and math.abs(gy) < 1 and math.abs(gz) < 1,
		"Gradient units are bounded density per stud"
	)
	check(
		buffer.tostring(variableField.Fields.qc) == variableBefore,
		"Visual field sampling leaves atmospheric state byte-identical"
	)
	check(
		buffer.tostring(variable.Payload) == variablePacketBefore,
		"Reconstruction never alters authoritative snapshot bytes"
	)
	local cropped = table.clone(variable)
	cropped.Complete = false
	check(
		not model:Push(cropped, 1),
		"Cropped records are rejected rather than treating missing cells as zeros"
	)
	check(
		not model:Push({ Complete = false }, 1),
		"Sparse diagnostic metadata cannot accidentally become render input"
	)
	local sealed = fixture(root, load, {
		Boundary = "Sealed",
		QC = function()
			return 0.00002
		end,
	})
	local walls = Reconstruction.new({ VelocityAssist = false })
	walls:Push(sealed, 0)
	near(
		walls:SampleQC(-2014.001, 490, 0, 0),
		0,
		0,
		"Sealed domain never wraps through its left wall"
	)
	near(
		walls:SampleQC(2014.001, 490, 0, 0),
		0,
		0,
		"Sealed domain never wraps through its right wall"
	)
	near(walls:SampleQC(-2014, 490, 0, 0), 0, 0, "Sealed lateral display support smoothly closes")
	check(walls:SampleQC(-1990, 490, 0, 0) > 0, "Valid near-wall cloud support is retained")
	rejects(function()
		model:SampleQC(0 / 0, 490, 0, 0)
	end, "NaN sampling positions fail explicitly")
	rejects(function()
		Reconstruction.new({ QcReference = 0 })
	end, "Invalid display concentration reference rejected")
	return {
		MaximumAdjacentQCJump = maximumJump,
		QcReference = model.QcReference,
		BoundaryWindow = "outer half-cell only; sealed Y, optional sealed XZ",
	}
end
