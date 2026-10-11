--!strict

-- Exercise the production conversion and partitioning without recreating its
-- equations in a test-only world model. Region boundaries are bookkeeping;
-- only the outer domain boundary may be wrapped by an explicit request.
return function(root: any, loadModule: any, check: any, near: any, rejects: any)
	local Coordinates = loadModule(root.World.WorldCoordinates)
	local Generator = loadModule(root.Generation.CloudSourceGenerator)
	local world = Coordinates.new()
	near(world.WidthStuds, 4028, 0, "World width is exactly 4028 studs")
	near(world.DepthStuds, 4028, 0, "World depth is exactly 4028 studs")
	near(world.MinX, -2014, 0, "Default west boundary is -2014 studs")
	near(world.MaxX, 2014, 0, "Default east boundary is +2014 studs")
	near(world.MinZ, -2014, 0, "Default south boundary is -2014 studs")
	near(world.MaxZ, 2014, 0, "Default north boundary is +2014 studs")
	near(world.StudsPerMeter, 2, 0, "Default conversion is two studs per physical meter")
	near(world.WidthMeters, 2014, 0, "One conversion sets the physical horizontal width")
	near(world.DepthMeters, 2014, 0, "One conversion sets the physical horizontal depth")
	near(world.MinXMeters, -1007, 0, "World X corner is physically global")
	near(world.MinZMeters, -1007, 0, "World Z corner is physically global")
	near(world.BottomStuds, 424, 0, "Visual base retains the existing cloud altitude")
	near(world.TopStuds, 568, 0, "Physical 72-meter column maps to 144 studs")
	near(world.BaseAltitudeMeters, 1000, 0, "Thermodynamics receives absolute base altitude")
	near(world.TopAltitudeMeters, 1072, 0, "Absolute top altitude uses the same meter scale")
	near(world.RegionCount, 16, 0, "Four by four logical regions are bounded")
	near(world.RegionSizeStuds, 1007, 0, "Regions each span exactly 1007 studs")
	check(table.isfrozen(world) and table.isfrozen(world.Bounds), "Unit mapping is immutable")
	rejects(function()
		world.StudsPerMeter = 1
	end, "An active world's unit scale cannot change silently")
	local area = 0
	for rz = 0, 3 do
		for rx = 0, 3 do
			local bounds = world:RegionBounds(rx, rz)
			check(table.isfrozen(bounds), "Cached region bounds are immutable")
			check(world:RegionBounds(rx, rz) == bounds, "Region queries reuse cached bounds")
			near(bounds.WidthStuds, 1007, 0, "Region X width is exactly 1007 studs")
			near(bounds.DepthStuds, 1007, 0, "Region Z depth is exactly 1007 studs")
			near(bounds.MaxX - bounds.MinX, 1007, 0, "Region X span is exact")
			near(bounds.MaxZ - bounds.MinZ, 1007, 0, "Region Z span is exact")
			near(bounds.Id, rz * 4 + rx + 1, 0, "Region IDs have stable Z-major indexing")
			local ix, iz = world:RegionCoordinates(bounds.Id)
			near(ix, rx, 0, "Region ID inverse preserves integer X")
			near(iz, rz, 0, "Region ID inverse preserves integer Z")
			local leftX, frontZ, id = world:WorldToRegion(bounds.MinX, bounds.MinZ)
			near(leftX, rx, 0, "Lower region X bound belongs to that region")
			near(frontZ, rz, 0, "Lower region Z bound belongs to that region")
			near(id, bounds.Id, 0, "Lower region corner maps to one ID")
			local centerX, centerZ, centerId = world:WorldToRegion(
				(bounds.MinX + bounds.MaxX) * 0.5,
				(bounds.MinZ + bounds.MaxZ) * 0.5
			)
			near(centerX, rx, 0, "Region center X is correctly classified")
			near(centerZ, rz, 0, "Region center Z is correctly classified")
			near(centerId, id, 0, "Region center ID is deterministic")
			if rx < 3 then
				near(
					bounds.MaxX,
					world:RegionBounds(rx + 1, rz).MinX,
					0,
					"X regions share one boundary"
				)
				local nextX, nextZ = world:WorldToRegion(bounds.MaxX, bounds.MinZ)
				near(nextX, rx + 1, 0, "Crossing an internal X edge enters its neighbor")
				near(nextZ, rz, 0, "Crossing an internal X edge preserves Z")
				near(world:WrapX(bounds.MaxX), bounds.MaxX, 0, "An internal X boundary never wraps")
			end
			if rz < 3 then
				near(
					bounds.MaxZ,
					world:RegionBounds(rx, rz + 1).MinZ,
					0,
					"Z regions share one boundary"
				)
				local nextX, nextZ = world:WorldToRegion(bounds.MinX, bounds.MaxZ)
				near(nextX, rx, 0, "Crossing an internal Z edge preserves X")
				near(nextZ, rz + 1, 0, "Crossing an internal Z edge enters its neighbor")
				near(world:WrapZ(bounds.MaxZ), bounds.MaxZ, 0, "An internal Z boundary never wraps")
			end
			area += bounds.WidthStuds * bounds.DepthStuds
		end
	end
	near(area, 4028 * 4028, 0, "All logical regions exactly tile the horizontal world")
	for _, point in
		{
			{ world.MaxX, 0 },
			{ 0, world.MaxZ },
			{ world.MinX - 0.01, 0 },
			{ 0, world.MinZ - 0.01 },
			{ world.MaxX + 0.01, 0 },
			{ 0, world.MaxZ + 0.01 },
		}
	do
		local x, z, id = world:WorldToRegion(point[1], point[2])
		check(x == nil and z == nil and id == nil, "Outer bounds are explicitly half-open")
	end
	near(world:WrapX(world.MaxX), world.MinX, 0, "Only the full-world X seam wraps")
	near(world:WrapZ(world.MaxZ), world.MinZ, 0, "Only the full-world Z seam wraps")
	near(
		world:WrapX(world.MinX - 1),
		world.MaxX - 1,
		0,
		"Negative X wrapping retains world position"
	)
	near(
		world:WrapZ(world.MinZ - 1),
		world.MaxZ - 1,
		0,
		"Negative Z wrapping retains world position"
	)
	local immediatelyInside = 2014 - 2 ^ -42 -- nearest binary64 value below +2014
	local lastX, lastZ, lastId = world:WorldToRegion(immediatelyInside, immediatelyInside)
	near(lastX, 3, 0, "Representable point below the east edge stays in the last region")
	near(lastZ, 3, 0, "Representable point below the north edge stays in the last region")
	near(lastId, 16, 0, "Floating-point subtraction cannot produce a seventeenth region")
	near(
		world:WrapX(immediatelyInside),
		immediatelyInside,
		0,
		"Inside X positions never wrap due to subtraction rounding"
	)
	near(
		world:WrapZ(immediatelyInside),
		immediatelyInside,
		0,
		"Inside Z positions never wrap due to subtraction rounding"
	)
	near(
		world:WrapPhysicalX(immediatelyInside / 2),
		immediatelyInside / 2,
		0,
		"Inside physical X positions never wrap due to rounding"
	)
	near(
		world:WrapPhysicalZ(immediatelyInside / 2),
		immediatelyInside / 2,
		0,
		"Inside physical Z positions never wrap due to rounding"
	)
	local edgeX, edgeY, edgeZ =
		world:WorldToCell(immediatelyInside, 436, immediatelyInside, 32, 6, 32)
	near(edgeX, 32, 0, "Inside east-edge cell index cannot round outside its buffer")
	near(edgeY, 1, 0, "Horizontal edge correction preserves vertical cell indexing")
	near(edgeZ, 32, 0, "Inside north-edge cell index cannot round outside its buffer")
	for turns = -8, 8 do
		near(
			world:WrapX(185 + turns * 4028),
			185,
			0,
			"X periodicity uses the whole 4028-stud domain"
		)
		near(
			world:WrapZ(-947 + turns * 4028),
			-947,
			0,
			"Z periodicity uses the whole 4028-stud domain"
		)
		near(
			world:WrapPhysicalX(73.5 + turns * 2014),
			73.5,
			0,
			"Physical X periodicity matches world units"
		)
		near(
			world:WrapPhysicalZ(-281.5 + turns * 2014),
			-281.5,
			0,
			"Physical Z periodicity matches world units"
		)
	end
	for _, configuration in
		{
			{},
			{ CenterX = -913.25, CenterZ = 287.5, StudsPerMeter = 0.5 },
			{
				CenterX = 1372,
				CenterZ = -2601,
				StudsPerMeter = 10,
				BottomStuds = 520,
				BaseAltitudeMeters = 1700,
				HeightMeters = 36,
			},
		}
	do
		local coordinates = Coordinates.new(configuration)
		near(
			coordinates.MaxX - coordinates.MinX,
			4028,
			0,
			"Changing origin preserves exact horizontal width"
		)
		near(
			coordinates.MaxZ - coordinates.MinZ,
			4028,
			0,
			"Changing origin preserves exact horizontal depth"
		)
		for _, position in
			{
				{ coordinates.MinX, coordinates.BottomStuds, coordinates.MinZ },
				{
					coordinates.CenterX,
					(coordinates.BottomStuds + coordinates.TopStuds) * 0.5,
					coordinates.CenterZ,
				},
				{ coordinates.MaxX, coordinates.TopStuds, coordinates.MaxZ },
				{
					coordinates.MinX - 91.375,
					coordinates.TopStuds + 117,
					coordinates.MaxZ + 72.625,
				},
			}
		do
			local px, py, pz = coordinates:WorldToPhysical(position[1], position[2], position[3])
			local wx, wy, wz = coordinates:PhysicalToWorld(px, py, pz)
			near(
				wx,
				position[1],
				1e-10,
				"World/physical X round trip preserves negative coordinates"
			)
			near(wy, position[2], 1e-10, "World/physical Y round trip preserves altitude offset")
			near(
				wz,
				position[3],
				1e-10,
				"World/physical Z round trip preserves negative coordinates"
			)
		end
		for _, speed in { -12, -1, 0, 2, 8, 30 } do
			near(
				coordinates:StudsToMeters(coordinates:MetersToStuds(speed)),
				speed,
				1e-12,
				"Velocity distance conversions use the same scale"
			)
		end
	end
	for _, resolution in { { 32, 6, 32 }, { 48, 6, 48 }, { 8, 12, 16 } } do
		local nx, ny, nz = resolution[1], resolution[2], resolution[3]
		local region = world:PhysicalRegion(nx, ny, nz)
		check(table.isfrozen(region), "Physical source region is immutable")
		near(region.OriginX, -1007, 0, "Source X origin uses physical world coordinates")
		near(region.OriginY, 1000, 0, "Source Y origin uses absolute physical altitude")
		near(region.OriginZ, -1007, 0, "Source Z origin uses physical world coordinates")
		near(
			region.SizeX * world.StudsPerMeter,
			4028,
			0,
			"Generator and transport share horizontal meter extent"
		)
		near(
			region.SizeY * world.StudsPerMeter,
			144,
			0,
			"Generator and renderer share vertical meter extent"
		)
		near(region.Dx * nx, region.SizeX, 1e-10, "Physical X cell spacing tiles the world")
		near(region.Dy * ny, region.SizeY, 1e-10, "Physical Y cell spacing tiles the atmosphere")
		near(region.Dz * nz, region.SizeZ, 1e-10, "Physical Z cell spacing tiles the world")
		for y = 1, ny do
			for z = 1, nz do
				for x = 1, nx do
					local wx, wy, wz = world:CellCenterWorld(x, y, z, nx, ny, nz)
					local ix, iy, iz = world:WorldToCell(wx, wy, wz, nx, ny, nz)
					near(ix, x, 0, "World-to-cell inverse preserves X")
					near(iy, y, 0, "World-to-cell inverse preserves Y")
					near(iz, z, 0, "World-to-cell inverse preserves Z")
				end
			end
		end
		local ix, iy, iz = world:WorldToCell(world.MinX, world.BottomStuds, world.MinZ, nx, ny, nz)
		near(ix, 1, 0, "World lower X bound maps to the first cell")
		near(iy, 1, 0, "World lower Y bound maps to the first cell")
		near(iz, 1, 0, "World lower Z bound maps to the first cell")
		check(
			world:WorldToCell(world.MaxX, world.BottomStuds, 0, nx, ny, nz) == nil,
			"World upper X bound is outside all cells"
		)
		check(
			world:WorldToCell(0, world.TopStuds, 0, nx, ny, nz) == nil,
			"World upper Y bound is outside all cells"
		)
		check(
			world:WorldToCell(0, world.BottomStuds, world.MaxZ, nx, ny, nz) == nil,
			"World upper Z bound is outside all cells"
		)
	end
	local generationRegion = world:PhysicalRegion(32, 6, 32)
	local visited: { [number]: boolean } = {}
	for event = 0, 127 do
		local source = Generator.Generate(84219, event, generationRegion)
		local repeatSource = Generator.Generate(84219, event, generationRegion)
		near(source.X, repeatSource.X, 0, "World-wide source X is deterministic")
		near(source.Y, repeatSource.Y, 0, "World-wide source altitude is deterministic")
		near(source.Z, repeatSource.Z, 0, "World-wide source Z is deterministic")
		check(source.Id == repeatSource.Id, "World-wide source identity is deterministic")
		local wx, wy, wz = world:PhysicalToWorld(source.X, source.Y, source.Z)
		local rx, rz, id = world:WorldToRegion(wx, wz)
		check(
			rx ~= nil and rz ~= nil and id ~= nil,
			"Generated source belongs to exactly one logical world region"
		)
		visited[id] = true
		check(
			wy >= world.BottomStuds and wy <= world.TopStuds,
			"World source altitude maps inside the visual column"
		)
		check(
			source.BaseAltitude >= 1000 and source.TopAltitude <= 1072,
			"World source altitude remains physically bounded"
		)
	end
	local visitedCount = 0
	for _ in visited do
		visitedCount += 1
	end
	near(visitedCount, 16, 0, "Seeded source stream samples all sixteen world regions")
	for _, invalid in
		{
			{ WidthStuds = 2014 },
			{ WidthStuds = 4029 },
			{ DepthStuds = 4029 },
			{ StudsPerMeter = 0 },
			{ StudsPerMeter = -2 },
			{ StudsPerMeter = 0.09 },
			{ StudsPerMeter = 101 },
			{ StudsPerMeter = math.huge },
			{ StudsPerMeter = 0 / 0 },
			{ CenterX = math.huge },
			{ CenterZ = 0 / 0 },
			{ CenterX = 1e30 },
			{ BottomStuds = math.huge },
			{ BaseAltitudeMeters = 0 / 0 },
			{ HeightMeters = 0 },
			{ HeightMeters = -72 },
			{ HeightMeters = math.huge },
			{ BottomStuds = 1e30 },
			{ BaseAltitudeMeters = 1e30 },
		}
	do
		rejects(function()
			Coordinates.new(invalid)
		end, "Invalid geometry or unrepresentable bounds are rejected")
	end
	for _, invalid in { -1, 0.5, 4, math.huge, 0 / 0 } do
		rejects(function()
			world:RegionBounds(invalid, 0)
		end, "Invalid integer region X is rejected")
		rejects(function()
			world:RegionBounds(0, invalid)
		end, "Invalid integer region Z is rejected")
	end
	for _, invalid in { 0, -1, 1.5, 17, math.huge, 0 / 0 } do
		rejects(function()
			world:RegionCoordinates(invalid)
		end, "Invalid region IDs are rejected")
	end
	for _, invalid in { math.huge, -math.huge, 0 / 0 } do
		rejects(function()
			world:WorldToRegion(invalid, 0)
		end, "Region conversion rejects non-finite X")
		rejects(function()
			world:WorldToPhysical(0, invalid, 0)
		end, "World conversion rejects non-finite altitude")
		rejects(function()
			world:PhysicalToWorld(0, 1000, invalid)
		end, "Physical conversion rejects non-finite Z")
		rejects(function()
			world:WrapX(invalid)
		end, "Periodic boundary conversion rejects non-finite X")
	end
	rejects(function()
		world:CellCenterPhysical(0, 1, 1, 32, 6, 32)
	end, "Zero-based cell coordinate cannot be confused with logical region indexing")
	rejects(function()
		world:CellCenterPhysical(1, 7, 1, 32, 6, 32)
	end, "Out-of-range cell altitude is rejected")
	rejects(function()
		world:PhysicalRegion(0, 6, 32)
	end, "Invalid physical source grid resolution is rejected")
	print(
		string.format(
			"World geometry: exact 4028x4028 studs; 16 logical regions; %d source regions sampled",
			visitedCount
		)
	)
end
