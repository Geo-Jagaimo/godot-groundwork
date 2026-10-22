extends GdUnitTestSuite


static func _slope() -> GwHeightfield:
	var hf := GwHeightfield.create(101, 101, 2.0, Vector2(-100, -100))
	for r in 101:
		for c in 101:
			hf.set_height(c, r, 50.0 + c * 0.2)
	hf.compute_min_max()
	return hf


static func _area(points: Array, holes: Array = []) -> GwOsmParser.WaterArea:
	var w := GwOsmParser.WaterArea.new()
	w.ring = PackedVector2Array(points)
	for h: Array in holes:
		w.holes.append(PackedVector2Array(h))
	return w


static func _surface_area(arrays: Array) -> float:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var total := 0.0
	for t in range(0, idx.size(), 3):
		var a := Vector2(v[idx[t]].x, v[idx[t]].z)
		var b := Vector2(v[idx[t + 1]].x, v[idx[t + 1]].z)
		var c := Vector2(v[idx[t + 2]].x, v[idx[t + 2]].z)
		total += absf((b - a).cross(c - a)) / 2.0
	return total


func test_lake_with_island_follows_terrain() -> void:
	var lake := _area(
		[Vector2(-60, -60), Vector2(60, -60), Vector2(60, 60), Vector2(-60, 60)],
		[[Vector2(-10, -10), Vector2(10, -10), Vector2(10, 10), Vector2(-10, 10)]]
	)
	var hf := _slope()
	var out := GwWaterBuilder.build([lake], [], hf)
	assert_int(out["areas"]).is_equal(1)
	assert_float(_surface_area(out["arrays"])).is_equal_approx(120.0 * 120.0 - 400.0, 0.5)
	var v: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = out["arrays"][Mesh.ARRAY_INDEX]
	var max_edge := maxf(hf.cell_size * 2.0, 6.0)
	for t in range(0, idx.size(), 3):
		assert_float(v[idx[t]].distance_to(v[idx[t + 1]])).is_less_equal(max_edge + 0.1)
	for p in v:
		var above := p.y - hf.sample(Vector2(p.x, p.z))
		assert_float(above).is_equal_approx(GwWaterBuilder.LIFT, 1e-3)


func test_area_is_clipped_to_the_terrain() -> void:
	var big := _area([Vector2(-500, -50), Vector2(500, -50), Vector2(500, 50), Vector2(-500, 50)])
	var hf := _slope()
	var out := GwWaterBuilder.build([big], [], hf)
	var v: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
	var rect := Rect2(hf.origin, hf.get_extent())
	for p in v:
		assert_bool(rect.has_point(Vector2(p.x, p.z))).is_true()


func test_river_line() -> void:
	var river := GwOsmParser.WaterLine.new()
	river.points = PackedVector2Array([Vector2(-80, 0), Vector2(80, 10)])
	river.waterway = "river"
	var out := GwWaterBuilder.build([], [river], _slope())
	assert_int(out["lines"]).is_equal(1)
	var v: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
	var width := Vector2(v[0].x, v[0].z).distance_to(Vector2(v[2].x, v[2].z))
	assert_float(width).is_equal_approx(GwWaterBuilder.LINE_WIDTHS["river"], 1e-3)


func test_parser_finds_water() -> void:
	var g := GwGeoReference.create(35.0, 139.0)
	var geom := func(points: Array) -> Array:
		var out := []
		for p: Vector2 in points:
			var ll := g.to_geo(Vector3(p.x, 0, p.y))
			out.append({"lat": ll[0], "lon": ll[1]})
		return out
	var pond := [Vector2(0, 0), Vector2(30, 0), Vector2(30, 30), Vector2(0, 0)]
	var data := {
		"elements":
		[
			{"type": "way", "tags": {"natural": "water"}, "geometry": geom.call(pond)},
			{"type": "way", "tags": {"landuse": "reservoir"}, "geometry": geom.call(pond)},
			{
				"type": "way",
				"tags": {"waterway": "stream"},
				"geometry": geom.call(pond.slice(0, 2))
			},
			{
				"type": "way",
				"tags": {"waterway": "stream", "tunnel": "culvert"},
				"geometry": geom.call(pond.slice(0, 2))
			},
			{"type": "way", "tags": {"waterway": "dam"}, "geometry": geom.call(pond.slice(0, 2))},
		]
	}
	var r := GwOsmParser.parse_data(data, g)
	assert_int(r.water_areas.size()).is_equal(2)
	assert_int(r.water_lines.size()).is_equal(1)
	assert_str(r.water_lines[0].waterway).is_equal("stream")


func test_query_includes_water_only_when_asked() -> void:
	var bbox := GwGeoBBox.from_sw_ne(35.0, 139.0, 35.01, 139.01)
	assert_str(GwOverpassClient.build_query(bbox, true, true)).not_contains("natural")
	var q := GwOverpassClient.build_query(bbox, false, false, 60, true)
	assert_str(q).contains('way["natural"="water"]')
	assert_str(q).contains('way["waterway"~"^(river|stream|canal|drain|ditch)$"]')
