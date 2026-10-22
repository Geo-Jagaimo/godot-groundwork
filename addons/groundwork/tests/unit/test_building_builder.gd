extends GdUnitTestSuite


static func _flat(h: float = 50.0) -> GwHeightfield:
	var hf := GwHeightfield.create(65, 65, 2.0, Vector2(-64, -64))
	hf.data.fill(h)
	hf.compute_min_max()
	return hf


static func _slope() -> GwHeightfield:
	var hf := GwHeightfield.create(65, 65, 2.0, Vector2(-64, -64))
	for r in 65:
		for c in 65:
			hf.set_height(c, r, 100.0 + c * 1.0)
	hf.compute_min_max()
	return hf


static func _building(points: Array, tags: Dictionary = {}) -> GwOsmParser.Building:
	var b := GwOsmParser.Building.new()
	b.ring = PackedVector2Array(points)
	b.tags = tags
	return b


func test_parse_length() -> void:
	assert_float(GwBuildingBuilder.parse_length_m("12")).is_equal(12.0)
	assert_float(GwBuildingBuilder.parse_length_m("12.5 m")).is_equal(12.5)
	assert_float(GwBuildingBuilder.parse_length_m("7,5")).is_equal(7.5)
	assert_float(GwBuildingBuilder.parse_length_m("10 ft")).is_equal_approx(3.048, 1e-6)
	assert_float(GwBuildingBuilder.parse_length_m("12'6\"")).is_equal_approx(3.81, 1e-6)
	assert_bool(is_nan(GwBuildingBuilder.parse_length_m("tall"))).is_true()
	assert_bool(is_nan(GwBuildingBuilder.parse_length_m(""))).is_true()


func test_height_order() -> void:
	var f := func(tags: Dictionary) -> float: return GwBuildingBuilder.height_for(tags, 3.0, 6.0)
	assert_float(f.call({"height": "20", "building:levels": "3"})).is_equal(20.0)
	assert_float(f.call({"building:levels": "4"})).is_equal(12.0)
	assert_float(f.call({"building:levels": "2;3"})).is_equal(6.0)
	assert_float(f.call({"height": "unknown", "building:levels": "x"})).is_equal(6.0)
	assert_float(f.call({})).is_equal(6.0)


func test_box_geometry() -> void:
	var hf := _flat(50.0)
	var b := _building(
		[Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)], {"height": "20"}
	)
	var out := GwBuildingBuilder.build([b], hf, 3.0, 6.0)
	assert_int(out["built"]).is_equal(1)
	var verts: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = out["arrays"][Mesh.ARRAY_INDEX]
	# Roof: 4 vertices, 2 triangles. Walls: 4 quads of 4 vertices, 2 triangles each.
	assert_int(verts.size()).is_equal(4 + 16)
	assert_int(idx.size()).is_equal((2 + 8) * 3)
	var lo := INF
	var hi := -INF
	for v in verts:
		lo = minf(lo, v.y)
		hi = maxf(hi, v.y)
	assert_float(hi).is_equal_approx(70.0, 1e-4)
	assert_float(lo).is_equal_approx(50.0 - GwBuildingBuilder.BASE_SINK, 1e-4)
	assert_int((out["faces"] as PackedVector3Array).size()).is_equal(idx.size())


func test_faces_point_outwards_and_up() -> void:
	var hf := _flat()
	# Clockwise and counter-clockwise footprints must both face outwards.
	for ring: Array in [
		[Vector2(0, 0), Vector2(10, 0), Vector2(10, 6), Vector2(0, 6)],
		[Vector2(0, 0), Vector2(0, 6), Vector2(10, 6), Vector2(10, 0)],
	]:
		var out := GwBuildingBuilder.build([_building(ring)], hf, 3.0, 6.0)
		var verts: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = out["arrays"][Mesh.ARRAY_INDEX]
		var center := Vector3(5, 53, 3)
		for t in range(0, idx.size(), 3):
			var a := verts[idx[t]]
			var front := (verts[idx[t + 2]] - a).cross(verts[idx[t + 1]] - a)
			var tri_center := (a + verts[idx[t + 1]] + verts[idx[t + 2]]) / 3.0
			assert_float(front.dot(tri_center - center)).is_greater(0.0)


func test_concave_footprint_roof_area() -> void:
	# L-shape: 10x10 minus a 5x5 corner = 75 m².
	var ring := [
		Vector2(0, 0), Vector2(10, 0), Vector2(10, 5), Vector2(5, 5), Vector2(5, 10), Vector2(0, 10)
	]
	var out := GwBuildingBuilder.build([_building(ring)], _flat(), 3.0, 6.0)
	var verts: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = out["arrays"][Mesh.ARRAY_INDEX]
	var roof_area := 0.0
	for t in range(0, idx.size(), 3):
		var a := verts[idx[t]]
		var b := verts[idx[t + 1]]
		var c := verts[idx[t + 2]]
		if is_equal_approx(a.y, b.y) and is_equal_approx(b.y, c.y) and a.y > 50.0:
			roof_area += (b - a).cross(c - a).length() / 2.0
	assert_float(roof_area).is_equal_approx(75.0, 1e-3)


func test_slope_base_uses_lowest_point() -> void:
	var out := GwBuildingBuilder.build(
		[_building([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])],
		_slope(),
		3.0,
		6.0
	)
	var verts: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
	# Ground at x=0 is 100 + 32 = 132 (grid starts at -64).
	var lo := INF
	for v in verts:
		lo = minf(lo, v.y)
	assert_float(lo).is_equal_approx(132.0 - GwBuildingBuilder.BASE_SINK, 1e-3)
	assert_float(verts[0].y).is_equal_approx(132.0 + 6.0, 1e-3)


func test_degenerate_footprints_fail() -> void:
	var tiny := _building([Vector2(0, 0), Vector2(0.5, 0), Vector2(0.5, 0.5)])
	var line := _building([Vector2(0, 0), Vector2(5, 0), Vector2(10, 0)])
	var out := GwBuildingBuilder.build([tiny, line], _flat(), 3.0, 6.0)
	assert_int(out["failed"]).is_equal(2)
	assert_object(out["arrays"]).is_null()


func test_group_by_chunk() -> void:
	var hf := _flat()
	var a := _building([Vector2(-60, -60), Vector2(-55, -60), Vector2(-55, -55)])
	var b := _building([Vector2(40, 40), Vector2(45, 40), Vector2(45, 45)])
	var outside := _building([Vector2(500, 500), Vector2(505, 500), Vector2(505, 505)])
	# 64 cells, chunk size 32 -> 2 x 2 chunks of 64 m.
	var groups := GwBuildingBuilder.group_by_chunk([a, b, outside], hf, 32)
	assert_int(groups.size()).is_equal(2)
	assert_int(groups[Vector2i(0, 0)].size()).is_equal(1)
	assert_int(groups[Vector2i(1, 1)].size()).is_equal(1)
