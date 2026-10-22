extends GdUnitTestSuite


static func _area(result: Dictionary) -> float:
	var pts: PackedVector2Array = result["points"]
	var idx: PackedInt32Array = result["indices"]
	var total := 0.0
	for t in range(0, idx.size(), 3):
		total += absf((pts[idx[t + 1]] - pts[idx[t]]).cross(pts[idx[t + 2]] - pts[idx[t]])) / 2.0
	return total


static func _square(x: float, y: float, s: float) -> PackedVector2Array:
	return PackedVector2Array(
		[Vector2(x, y), Vector2(x + s, y), Vector2(x + s, y + s), Vector2(x, y + s)]
	)


func test_winding() -> void:
	var sq := _square(0, 0, 2)
	assert_float(GwPolygonUtil.signed_area(sq)).is_equal(4.0)
	assert_float(GwPolygonUtil.signed_area(GwPolygonUtil.with_winding(sq, false))).is_equal(-4.0)
	assert_object(GwPolygonUtil.with_winding(sq, true)).is_equal(sq)


func test_without_holes() -> void:
	var holes: Array[PackedVector2Array] = []
	var r := GwPolygonUtil.triangulate(_square(0, 0, 10), holes)
	assert_bool(r["holes_dropped"]).is_false()
	assert_float(_area(r)).is_equal_approx(100.0, 1e-4)


func test_one_hole() -> void:
	var holes: Array[PackedVector2Array] = [_square(3, 3, 4)]
	var r := GwPolygonUtil.triangulate(_square(0, 0, 10), holes)
	assert_bool(r["holes_dropped"]).is_false()
	assert_float(_area(r)).is_equal_approx(100.0 - 16.0, 1e-4)


func test_several_holes_and_any_winding() -> void:
	var outer := GwPolygonUtil.with_winding(_square(0, 0, 30), false)
	var holes: Array[PackedVector2Array] = [
		_square(2, 2, 5), GwPolygonUtil.with_winding(_square(20, 3, 6), true), _square(10, 18, 8)
	]
	var r := GwPolygonUtil.triangulate(outer, holes)
	assert_bool(r["holes_dropped"]).is_false()
	assert_float(_area(r)).is_equal_approx(900.0 - 25.0 - 36.0 - 64.0, 1e-3)


func test_concave_outline_with_hole() -> void:
	# U shape with a hole in its left arm.
	var outer := PackedVector2Array(
		[
			Vector2(0, 0),
			Vector2(30, 0),
			Vector2(30, 30),
			Vector2(20, 30),
			Vector2(20, 10),
			Vector2(10, 10),
			Vector2(10, 30),
			Vector2(0, 30)
		]
	)
	var holes: Array[PackedVector2Array] = [_square(3, 15, 4)]
	var r := GwPolygonUtil.triangulate(outer, holes)
	assert_bool(r["holes_dropped"]).is_false()
	assert_float(_area(r)).is_equal_approx(900.0 - 200.0 - 16.0, 1e-3)
