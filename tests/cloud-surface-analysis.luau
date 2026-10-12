--!strict

local fixture = require("./CloudRenderFixture")

return function(root: any, load: any, check: any, near: any, rejects: any, _quick: boolean?)
	local Surface = load(root.Rendering.CloudSurfaceAnalysis)
	local Codec = load(root.Rendering.CloudRenderSnapshot)
	local surface = Surface.new()
	local base, top, thickness, present = surface:Sample(0, 0)
	check(
		not present and base == 0 and top == 0 and thickness == 0,
		"No packet has no manufactured cloud envelope"
	)
	local empty = fixture(root, load)
	surface:Update(empty)
	check(surface.CloudColumns == 0, "Clear qc leaves every actual column clear")
	check(not select(4, surface:Sample(0, 0)), "Clear column has no cloud bounds")
	local shaped, physical = fixture(root, load, {
		QC = function(x: number, y: number, z: number)
			if z < 3 or z > 5 then
				return 0
			end
			if x == 3 and y >= 2 and y <= 3 then
				return 0.00002
			end
			if x == 4 and y >= 3 and y <= 5 then
				return 0.00004
			end
			if x == 5 and y >= 2 and y <= 4 then
				return 0.00001
			end
			return 0
		end,
	})
	local physicalBefore, packetBefore =
		buffer.tostring(physical.Fields.qc), buffer.tostring(shaped.Payload)
	surface:Update(shaped)
	check(
		surface.CloudColumns == 9,
		"Independent irregular cloudy columns are discovered from liquid only"
	)
	local x3, _, z4 = Codec.CellCenter(shaped, 3 + (4 - 1) * 8)
	local x4 = Codec.CellCenter(shaped, 4 + (4 - 1) * 8)
	local b3, t3, h3, c3 = surface:Sample(x3, z4)
	near(b3, 448, 0, "Local column base uses lowest liquid cell face")
	near(t3, 496, 0, "Local column top uses highest liquid cell face")
	near(h3, 48, 0, "Thin column does not inherit entire 144-stud box thickness")
	check(c3, "Cloudy local column is known")
	local b4, t4, h4 = surface:Sample(x4, z4)
	near(b4, 472, 0, "Higher irregular base is retained")
	near(t4, 544, 0, "Higher irregular top is retained")
	near(h4, 72, 0, "Taller column has its own physical thickness")
	local middleBase, middleTop = surface:Sample((x3 + x4) / 2, z4)
	near(
		middleBase,
		(b3 + b4) / 2,
		1e-10,
		"Column base interpolates smoothly without rigid horizontal stripes"
	)
	near(
		middleTop,
		(t3 + t4) / 2,
		1e-10,
		"Column top interpolates smoothly between resolved structures"
	)
	for _, y in { 448, 460, 472, 484, 496 } do
		local h, known = surface:SampleHeight(x3, y, z4)
		near(h, (y - 448) / 48, 1e-14, "Layered puff height is relative to actual local cloud")
		check(known and h >= 0 and h <= 1, "Local relative height remains bounded")
	end
	near(surface:SampleHeight(x3, 0, z4), 0, 0, "Height normalization bounds below local base")
	near(
		surface:SampleHeight(x3, 10000, z4),
		1,
		0,
		"Height normalization bounds above local top without growing cloud"
	)
	check(
		not select(4, surface:Sample(-1500, -1500)),
		"Far clear columns do not get global layer bounds"
	)
	near(
		surface:GetStorageBytes(),
		8 * 8 * 9,
		0,
		"Surface cache is packed nine bytes per horizontal column"
	)
	local originalBases = surface.Bases
	surface:Update(shaped)
	check(surface.Updates == 2, "Repeated same snapshot does not rescan columns")
	local changed = fixture(root, load, {
		QC = function()
			return 0.00002
		end,
	}, { Seed = 84219, Generation = 1, Sequence = 2, Time = 1, WallTime = 1 })
	surface:Update(changed)
	check(surface.Bases == originalBases, "Compatible-size updates reuse column buffers")
	check(surface.CloudColumns == 64, "Known newly cloudy columns overwrite previous empty entries")
	for _, seam in { -1007, 0, 1007, -2014 } do
		local leftBase, leftTop = surface:Sample(seam - 0.0001, 0)
		local rightBase, rightTop = surface:Sample(seam + 0.0001, 0)
		near(leftBase, rightBase, 0, "Uniform cloud-column envelope has no region or periodic seam")
		near(leftTop, rightTop, 0, "Uniform top has no region or periodic seam")
	end
	surface:Update(empty)
	check(
		surface.CloudColumns == 0 and not select(4, surface:Sample(0, 0)),
		"Evaporation removes cached cloudy envelope rather than persisting shapes"
	)
	check(
		buffer.tostring(physical.Fields.qc) == physicalBefore,
		"Column analysis cannot inject cloud mass"
	)
	check(
		buffer.tostring(shaped.Payload) == packetBefore,
		"Surface analysis does not modify incoming packet"
	)
	local cropped = table.clone(shaped)
	cropped.Complete = false
	rejects(function()
		surface:Update(cropped)
	end, "Incomplete column metadata cannot be substituted for a complete envelope")
	rejects(function()
		surface:Sample(0 / 0, 0)
	end, "NaN horizontal column position rejected")
	local sealed = fixture(root, load, {
		Boundary = "Sealed",
		QC = function()
			return 0.00002
		end,
	})
	surface:Update(sealed)
	check(
		not select(4, surface:Sample(-2020, 0)),
		"Sealed bounds do not invent columns outside world"
	)
	surface:Reset()
	check(
		not select(4, surface:Sample(0, 0)),
		"Regeneration cleanup discards cached surface identity"
	)
	return {
		CloudColumns = 9,
		ExampleCloudBaseStuds = b3,
		ExampleCloudTopStuds = t3,
		ExampleCloudThicknessStuds = h3,
		PackedBytesPerColumn = 9,
	}
end
