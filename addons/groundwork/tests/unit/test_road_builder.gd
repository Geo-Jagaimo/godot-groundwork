extends GdUnitTestSuite


static func _hill() -> GwHeightfield:
	var hf := GwHeightfield.create(101, 101, 2.0, Vector2(-100, -100))
	for r in 101:
		for c in 101:
			hf.set_height(c, r, 20.0 + 10.0 * sin(c * 0.1) * cos(r * 0.07))
	hf.compute_min_max()
	return hf


static func _road(points: Array, highway: String = "residential") -> GwOsmParser.Road:
	var r := GwOsmParser.Road.new()
	r.points = PackedVector2Array(points)
	r.highway = highway
	return r


func test_widths_and_classes() -> void:
	assert_float(GwRoadBuilder.width_for("motorway")).is_equal(12.0)
	assert_float(GwRoadBuilder.width_for("primary_link")).is_equal_approx(7.0, 1e-6)
	assert_float(GwRoadBuilder.width_for("unknown_kind")).is_equal(GwRoadBuilder.DEFAULT_WIDTH)
	assert_float(GwRoadBuilder.width_for("footway", {"footway": 3.5})).is_equal(3.5)
	assert_str(GwRoadBuilder.road_class("trunk_link")).is_equal("motorway")
	assert_str(GwRoadBuilder.road_class("steps")).is_equal("path")
	assert_str(GwRoadBuilder.road_class("something")).is_equal("residential")


func test_resample_spacing() -> void:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(23, 0), Vector2(23, 2)])
	var out := GwRoadBuilder.resample(pts, 5.0)
	assert_vector(out[0]).is_equal(Vector2(0, 0))
	assert_vector(out[out.size() - 1]).is_equal(Vector2(23, 2))
	assert_bool(Vector2(23, 0) in out).is_true()
	for i in range(1, out.size()):
		assert_float(out[i - 1].distance_to(out[i])).is_less_equal(5.0 + 1e-4)


func test_clip_splits_runs() -> void:
	var pts := PackedVector2Array(
		[Vector2(0, 0), Vector2(1, 0), Vector2(50, 0), Vector2(2, 0), Vector2(3, 0)]
	)
	var runs := GwRoadBuilder.clip(pts, Rect2(-10, -10, 20, 20))
	assert_int(runs.size()).is_equal(2)
	assert_int(runs[0].size()).is_equal(2)


func test_ribbon_sits_above_terrain() -> void:
	var hf := _hill()
	var out := GwRoadBuilder.build([_road([Vector2(-50, -20), Vector2(60, 30)])], hf, "residential")
	assert_int(out["built"]).is_equal(1)
	var verts: PackedVector3Array = out["arrays"][Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = out["arrays"][Mesh.ARRAY_INDEX]
	assert_int(verts.size() % 3).is_equal(0)
	assert_int(idx.size()).is_equal((verts.size() / 3 - 1) * 4 * 3)
	var lift := GwRoadBuilder.LIFT + 2 * GwRoadBuilder.CLASS_LIFT
	for v in verts:
		var above := v.y - hf.sample(Vector2(v.x, v.z))
		assert_float(above).is_between(lift - 1e-3, lift + 0.02)
	# Ribbon is 6 m wide: left and right vertices are 6 m apart.
	var left := Vector2(verts[0].x, verts[0].z)
	var right := Vector2(verts[2].x, verts[2].z)
	assert_float(left.distance_to(right)).is_equal_approx(6.0, 1e-3)
	for t in range(0, idx.size(), 3):
		var a := verts[idx[t]]
		var front := (verts[idx[t + 2]] - a).cross(verts[idx[t + 1]] - a)
		assert_float(front.y).is_greater(0.0)


func test_roads_outside_terrain_are_dropped() -> void:
	var out := GwRoadBuilder.build([_road([Vector2(500, 500), Vector2(600, 500)])], _hill(), "path")
	assert_int(out["built"]).is_equal(0)
	assert_object(out["arrays"]).is_null()


func test_group_by_class() -> void:
	var groups := GwRoadBuilder.group_by_class(
		[_road([], "primary"), _road([], "footway"), _road([], "steps")]
	)
	assert_int(groups["path"].size()).is_equal(2)
	assert_int(groups["primary"].size()).is_equal(1)
