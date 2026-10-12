--!strict
-- Offline mesh projection of ACTUAL production Part descriptors from the
-- benchmark. No discs, billboards, textures or reconstructed substitute shapes.
-- This script does not emulate Roblox lighting, sorting, GPU cost or Studio.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local input = process.args[1] or "build/phase265-cube-preview.json"
local output = process.args[2] or "build/phase265-cubic-geometry.svg"
local report = serde.decode("json", fs.readFile(input))
local scene = report.Scenes[1]
assert(scene and scene.Cubes and scene.DiagnosticVoxels, "Run the cubic benchmark first")
local W, H, F = 600, 300, 580
local function v(x: number, y: number, z: number): any
	return { x, y, z }
end
local function sub(a: any, b: any): any
	return v(a[1] - b[1], a[2] - b[2], a[3] - b[3])
end
local function dot(a: any, b: any): number
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
local function cross(a: any, b: any): any
	return v(a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1])
end
local function unit(a: any): any
	local n = math.sqrt(dot(a, a))
	assert(n > 0)
	return v(a[1] / n, a[2] / n, a[3] / n)
end
local weightedY, weight = 0, 0
local minY, maxY = math.huge, -math.huge
for _, cube in scene.Cubes do
	weightedY += cube.Y * cube.Opacity
	weight += cube.Opacity
	minY, maxY = math.min(minY, cube.Y), math.max(maxY, cube.Y)
end
assert(weight > 0, "The captured geometry contains no visible cubes")
local focus = v(scene.Camera.X, weightedY / weight, scene.Camera.Z)
local views = {
	{ Name = "Ground", Eye = v(focus[1], 100, focus[3] + 900), Target = focus },
	{ Name = "Side", Eye = v(focus[1] + 900, focus[2], focus[3]), Target = focus },
	{ Name = "Above", Eye = v(focus[1], 800, focus[3]), Target = focus },
	{
		Name = "Close oblique",
		Eye = v(focus[1] + 220, focus[2] + 60, focus[3] + 220),
		Target = focus,
	},
	{
		Name = "Inside / boundary",
		Eye = v(focus[1] + 6, focus[2], focus[3] + 6),
		Target = v(focus[1] + 186, focus[2], focus[3] + 6),
	},
}
local corners = {
	v(-1, -1, -1),
	v(1, -1, -1),
	v(1, -1, 1),
	v(-1, -1, 1),
	v(-1, 1, -1),
	v(1, 1, -1),
	v(1, 1, 1),
	v(-1, 1, 1),
}
local faces = {
	{ 1, 2, 3, 4 },
	{ 5, 8, 7, 6 },
	{ 1, 5, 6, 2 },
	{ 2, 6, 7, 3 },
	{ 3, 7, 8, 4 },
	{
		4,
		8,
		5,
		1,
	},
}
local shade = { 0.72, 1, 0.82, 0.94, 0.78, 0.88 }
local svg = {
	string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="%d" viewBox="0 0 1200 %d">',
		H * 5 + 100,
		H * 5 + 100
	),
	'<rect width="100%" height="100%" fill="#203041"/>',
	'<g font-family="sans-serif" fill="white"><text x="16" y="24" font-size="18">ACTUAL PART GEOMETRY: GIANT DIAGNOSTIC CELLS / POOLED 3D BLOCK CUBES</text><text x="16" y="47" font-size="13">Software face projection only; not a Roblox Studio capture, GPU benchmark or visual acceptance test.</text>',
	string.format(
		'<text x="16" y="69" font-size="13">Same natural qc at t=%.0f s. %d real cubes; equal XYZ. One captured Ultra geometry set, five viewpoints.</text></g>',
		scene.SimulatedSeconds,
		#scene.Cubes
	),
}
local function clip(poly: any): any
	local result = {}
	for i, a in poly do
		local b = poly[i % #poly + 1]
		local ai, bi = a[3] >= 3, b[3] >= 3
		if ai then
			table.insert(result, a)
		end
		if ai ~= bi then
			local t = (3 - a[3]) / (b[3] - a[3])
			table.insert(result, v(a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]), 3))
		end
	end
	return result
end
for row, view in views do
	local forward = unit(sub(view.Target, view.Eye))
	local up = v(0, 1, 0)
	if math.abs(dot(up, forward)) > 0.95 then
		up = v(0, 0, 1)
	end
	local right = unit(cross(forward, up))
	up = cross(right, forward)
	for column, items in { scene.DiagnosticVoxels, scene.Cubes } do
		local offsetX, offsetY = (column - 1) * W, 100 + (row - 1) * H
		local mesh = {}
		for _, part in items do
			assert(part.SizeX > 0 and part.SizeY > 0 and part.SizeZ > 0, "Degenerate geometry")
			if column == 2 then
				assert(
					part.Shape == "Block" and part.SizeX == part.SizeY and part.SizeY == part.SizeZ,
					"Not genuine cubic renderer data"
				)
			end
			local transformed = {}
			for _, corner in corners do
				local point = sub(
					v(
						part.X + corner[1] * part.SizeX / 2,
						part.Y + corner[2] * part.SizeY / 2,
						part.Z + corner[3] * part.SizeZ / 2
					),
					view.Eye
				)
				table.insert(transformed, v(dot(point, right), dot(point, up), dot(point, forward)))
			end
			for faceIndex, face in faces do
				local poly = {}
				local depth = 0
				for _, index in face do
					table.insert(poly, transformed[index])
					depth += transformed[index][3] / 4
				end
				poly = clip(poly)
				if #poly < 3 then
					continue
				end
				local points = {}
				local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
				for _, point in poly do
					local x, y = W / 2 + F * point[1] / point[3], H / 2 - F * point[2] / point[3]
					minX, minY, maxX, maxY =
						math.min(minX, x), math.min(minY, y), math.max(maxX, x), math.max(maxY, y)
					table.insert(points, string.format("%.2f,%.2f", x, y))
				end
				if maxX < 0 or maxY < 0 or minX > W or minY > H then
					continue
				end
				local r, g, b = part.R or 0.9, part.G or 0.93, part.B or 0.96
				local tint = shade[faceIndex]
				local color = string.format(
					"rgb(%d,%d,%d)",
					math.floor(r * tint * 255),
					math.floor(g * tint * 255),
					math.floor(b * tint * 255)
				)
				table.insert(mesh, {
					Depth = depth,
					SVG = string.format(
						'<polygon points="%s" fill="%s" fill-opacity="%.4f"/>',
						table.concat(points, " "),
						color,
						part.Opacity
					),
				})
			end
		end
		table.sort(mesh, function(a, b)
			return a.Depth > b.Depth
		end)
		local id = "v" .. row .. "c" .. column
		table.insert(
			svg,
			string.format(
				'<defs><clipPath id="%s"><rect width="%d" height="%d"/></clipPath></defs><g transform="translate(%d %d)"><rect width="%d" height="%d" fill="#7da3bf"/><g clip-path="url(#%s)">',
				id,
				W,
				H,
				offsetX,
				offsetY,
				W,
				H,
				id
			)
		)
		for _, face in mesh do
			table.insert(svg, face.SVG)
		end
		table.insert(
			svg,
			string.format(
				'</g><text x="12" y="24" fill="white" font-size="15" font-family="sans-serif">%s | %s</text></g>',
				view.Name,
				if column == 1 then "Original atmospheric cells" else "Actual small cubic volume"
			)
		)
	end
end
table.insert(svg, "</svg>")
fs.writeFile(output, table.concat(svg, "\n"))
print("Wrote actual cubic mesh projection: " .. output)
print("Studio appearance, material/alpha sorting and device FPS remain untested.")
