--!strict

-- Manufactured input fields exercise the real world state and render codec;
-- no stand-in interpolation or serialization implementation is used.
return function(root: any, load: any, settings: any?, metadata: any?): (any, any)
	local options = settings or {}
	local Coordinates = load(root.World.WorldCoordinates)
	local Field = load(root.World.WeatherField)
	local Codec = load(root.Rendering.CloudRenderSnapshot)
	local field = Field.new(Coordinates.new(), {
		SizeX = options.SizeX or 8,
		SizeY = options.SizeY or 6,
		SizeZ = options.SizeZ or 8,
		BackgroundU = options.U or 0,
		BackgroundV = options.V or 0,
		ShearU = 0,
		ShearV = 0,
		StreamfunctionAmplitude = 0,
		Boundary = options.Boundary or "Periodic",
		Microphysics = false,
	})
	for y = 1, field.SizeY do
		for z = 1, field.SizeZ do
			for x = 1, field.SizeX do
				local value = if options.QC then options.QC(x, y, z) else 0
				field.State:Set("qc", field.State.Grid:Index(x, y, z), value)
				if options.W then
					field.State:Set("w", field.State.Grid:Index(x, y, z), options.W)
				end
			end
		end
	end
	local meta = metadata or { Seed = 84219, Generation = 1, Sequence = 1, Time = 0, WallTime = 0 }
	return Codec.Decode(Codec.Encode(field, meta)), field
end
