@tool
class_name GwWaterBuilder
extends RefCounted
## Builds water surfaces from OSM: areas (lakes, ponds, river areas, with islands
## cut out) and waterway lines (rivers, streams, canals) as ribbons.
##
## Surfaces are draped over the terrain, which already sits at the water level
## in most elevation data, and lifted a little; long triangles are split so the
## surface follows the terrain. Roads are lifted more, so bridges stay on top.
## No collision. Pure and thread-safe.

## Width in metres per waterway=* line value.
const LINE_WIDTHS := {"river": 12.0, "canal": 8.0, "stream": 3.0, "drain": 2.0, "ditch": 1.5}
const LIFT := 0.1
## Metres per texture repeat.
const TEXTURE_SCALE := 25.0
const COLOR := Color(0.1, 0.25, 0.33)


## Mesh arrays for all water. Returns {"arrays": Array or null, "areas": int,
## "lines": int}.
static func build(areas: Array, lines: Array, hf: GwHeightfield) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var rect := Rect2(hf.origin, hf.get_extent()).grow(-hf.cell_size)
	var max_edge := maxf(hf.cell_size * 2.0, 6.0)
	var built_areas := 0
	for w: GwOsmParser.WaterArea in areas:
		for poly in clip_to_rect(w.ring, w.holes, rect):
			var tri := GwPolygonUtil.triangulate(poly["outer"], poly["holes"])
			var pts: PackedVector2Array = tri["points"]
			var idx: PackedInt32Array = tri["indices"]
			for t in range(0, idx.size(), 3):
				_add_draped_triangle(
					pts[idx[t]],
					pts[idx[t + 1]],
					pts[idx[t + 2]],
					max_edge,
					hf,
					verts,
					normals,
					uvs,
					indices
				)
			if not idx.is_empty():
				built_areas += 1
	var built_lines := 0
	for line: GwOsmParser.WaterLine in lines:
		var half := float(LINE_WIDTHS.get(line.waterway, 3.0)) / 2.0
		for run in GwRoadBuilder.clip(GwRoadBuilder.resample(line.points), rect):
			GwRoadBuilder.add_ribbon(run, half, LIFT, hf, verts, normals, uvs, indices)
			built_lines += 1
	return {
		"arrays": GwMeshUtil.surface_arrays(verts, normals, uvs, indices),
		"areas": built_areas,
		"lines": built_lines,
	}


## Pieces of [param outer] minus [param holes] inside [param rect], as
## [{"outer": PackedVector2Array, "holes": Array[PackedVector2Array]}].
static func clip_to_rect(
	outer: PackedVector2Array, holes: Array[PackedVector2Array], rect: Rect2
) -> Array:
	var box := PackedVector2Array(
		[
			rect.position,
			Vector2(rect.end.x, rect.position.y),
			rect.end,
			Vector2(rect.position.x, rect.end.y)
		]
	)
	var pieces := []
	for piece: PackedVector2Array in Geometry2D.intersect_polygons(outer, box):
		if absf(GwPolygonUtil.signed_area(piece)) < 1.0:
			continue
		var piece_holes: Array[PackedVector2Array] = []
		pieces.append({"outer": piece, "holes": piece_holes})
	for hole in holes:
		for clipped: PackedVector2Array in Geometry2D.intersect_polygons(hole, box):
			for p: Dictionary in pieces:
				if Geometry2D.is_point_in_polygon(clipped[0], p["outer"]):
					p["holes"].append(clipped)
					break
	return pieces


## Splits the triangle along its longest edge until every edge is at most
## [param max_edge] long, then drapes the pieces over the terrain.
static func _add_draped_triangle(
	a: Vector2,
	b: Vector2,
	c: Vector2,
	max_edge: float,
	hf: GwHeightfield,
	verts: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> void:
	var stack: Array[PackedVector2Array] = [PackedVector2Array([a, b, c])]
	var limit := max_edge * max_edge
	while not stack.is_empty():
		var t: PackedVector2Array = stack.pop_back()
		var e0 := t[0].distance_squared_to(t[1])
		var e1 := t[1].distance_squared_to(t[2])
		var e2 := t[2].distance_squared_to(t[0])
		if maxf(e0, maxf(e1, e2)) > limit:
			if e0 >= e1 and e0 >= e2:
				var m := (t[0] + t[1]) / 2.0
				stack.append(PackedVector2Array([t[0], m, t[2]]))
				stack.append(PackedVector2Array([m, t[1], t[2]]))
			elif e1 >= e2:
				var m := (t[1] + t[2]) / 2.0
				stack.append(PackedVector2Array([t[0], t[1], m]))
				stack.append(PackedVector2Array([t[0], m, t[2]]))
			else:
				var m := (t[2] + t[0]) / 2.0
				stack.append(PackedVector2Array([t[0], t[1], m]))
				stack.append(PackedVector2Array([m, t[1], t[2]]))
			continue
		var s := verts.size()
		for p in t:
			verts.append(Vector3(p.x, hf.sample(p) + LIFT, p.y))
			normals.append(Vector3.UP)
			uvs.append(p / TEXTURE_SCALE)
		GwMeshUtil.add_triangle(indices, verts, s, s + 1, s + 2, Vector3.UP)
