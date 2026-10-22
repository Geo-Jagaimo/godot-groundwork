@tool
class_name GwBuildingBuilder
extends RefCounted
## Extrudes OSM building footprints into flat-roofed meshes, merged per terrain
## chunk.
##
## Height: [code]height[/code] tag, else [code]building:levels[/code] x level
## height, else a default. Walls start 0.5 m below the lowest ground point of the
## footprint so buildings on slopes do not float; the roof is at that ground
## point plus the height. Vertices are in the scene root's space. Pure and
## thread-safe.

## Metres per texture repeat on walls and roofs.
const TEXTURE_SCALE := 3.0
const BASE_SINK := 0.5
## Footprints smaller than this (m²) are skipped.
const MIN_AREA := 1.0


## Parses OSM lengths: "12", "12.5 m", "12,5", "40'", "40 ft", "12'6\"". NAN if invalid.
static func parse_length_m(text: String) -> float:
	var s := text.strip_edges().to_lower().replace(",", ".")
	if s.is_empty():
		return NAN
	var feet := RegEx.create_from_string(
		"^(\\d+(?:\\.\\d+)?)\\s*'\\s*(?:(\\d+(?:\\.\\d+)?)\\s*\")?$"
	)
	var m := feet.search(s)
	if m:
		return m.get_string(1).to_float() * 0.3048 + m.get_string(2).to_float() * 0.0254
	var num := RegEx.create_from_string("^(\\d+(?:\\.\\d+)?)\\s*(m|ft)?$").search(s)
	if num == null:
		return NAN
	var v := num.get_string(1).to_float()
	return v * 0.3048 if num.get_string(2) == "ft" else v


## Building height in metres from its tags.
static func height_for(tags: Dictionary, level_height: float, default_height: float) -> float:
	var h := parse_length_m(str(tags.get("height", "")))
	if not is_nan(h) and h > 0.0:
		return h
	# "building:levels" may be a list like "3;4": use the first value.
	var levels_text := str(tags.get("building:levels", "")).get_slice(";", 0).strip_edges()
	if levels_text.is_valid_float() and levels_text.to_float() > 0.0:
		return levels_text.to_float() * level_height
	return default_height


## Groups buildings by the terrain chunk containing their centroid. Buildings
## outside the heightfield are dropped. Returns {Vector2i: Array}.
static func group_by_chunk(buildings: Array, hf: GwHeightfield, chunk_size: int) -> Dictionary:
	var groups := {}
	var grid := GwTerrainChunkBuilder.chunk_grid(hf, chunk_size)
	var extent := Rect2(hf.origin, hf.get_extent())
	var span := hf.cell_size * chunk_size
	for b: GwOsmParser.Building in buildings:
		var c := _centroid(b.ring)
		if not extent.has_point(c):
			continue
		var key := Vector2i(
			clampi(floori((c.x - hf.origin.x) / span), 0, grid.x - 1),
			clampi(floori((c.y - hf.origin.y) / span), 0, grid.y - 1)
		)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(b)
	return groups


## Mesh arrays and collision faces for a group of buildings. Returns
## {"arrays": Array (null when nothing was built), "faces": PackedVector3Array,
## "built": int, "failed": int}.
static func build(
	buildings: Array, hf: GwHeightfield, level_height: float, default_height: float
) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var built := 0
	var failed := 0
	for b: GwOsmParser.Building in buildings:
		var ring := b.ring
		var area := signed_area(ring)
		if ring.size() < 3 or absf(area) < MIN_AREA:
			failed += 1
			continue
		var tris := Geometry2D.triangulate_polygon(ring)
		if tris.is_empty():
			failed += 1
			continue
		var ground := INF
		for p in ring:
			ground = minf(ground, hf.sample(p))
		var bottom := ground - BASE_SINK
		var top := ground + height_for(b.tags, level_height, default_height)

		# Roof.
		var roof_start := verts.size()
		for p in ring:
			verts.append(Vector3(p.x, top, p.y))
			normals.append(Vector3.UP)
			uvs.append(p / TEXTURE_SCALE)
		for t in range(0, tris.size(), 3):
			GwMeshUtil.add_triangle(
				indices,
				verts,
				roof_start + tris[t],
				roof_start + tris[t + 1],
				roof_start + tris[t + 2],
				Vector3.UP
			)

		# Walls, one quad per edge, facing outwards.
		var along := 0.0
		for i in ring.size():
			var a := ring[i]
			var c := ring[(i + 1) % ring.size()]
			var length := a.distance_to(c)
			if length < 0.001:
				continue
			var d := (c - a) / length
			var n2 := Vector2(d.y, -d.x) if area > 0.0 else Vector2(-d.y, d.x)
			var n := Vector3(n2.x, 0.0, n2.y)
			var s := verts.size()
			var u0 := along / TEXTURE_SCALE
			var u1 := (along + length) / TEXTURE_SCALE
			var v_bottom := (top - bottom) / TEXTURE_SCALE
			verts.append(Vector3(a.x, bottom, a.y))
			verts.append(Vector3(c.x, bottom, c.y))
			verts.append(Vector3(c.x, top, c.y))
			verts.append(Vector3(a.x, top, a.y))
			normals.append_array(PackedVector3Array([n, n, n, n]))
			uvs.append_array(
				PackedVector2Array(
					[Vector2(u0, v_bottom), Vector2(u1, v_bottom), Vector2(u1, 0), Vector2(u0, 0)]
				)
			)
			GwMeshUtil.add_triangle(indices, verts, s, s + 1, s + 2, n)
			GwMeshUtil.add_triangle(indices, verts, s, s + 2, s + 3, n)
			along += length
		built += 1

	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for i in indices.size():
		faces[i] = verts[indices[i]]
	var arrays: Variant = GwMeshUtil.surface_arrays(verts, normals, uvs, indices)
	return {"arrays": arrays, "faces": faces, "built": built, "failed": failed}


## Shoelace area in the XZ plane (sign gives the winding).
static func signed_area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in ring.size():
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		a += p.x * q.y - q.x * p.y
	return a / 2.0


static func _centroid(ring: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for p in ring:
		sum += p
	return sum / maxi(ring.size(), 1)
