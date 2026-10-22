extends GdUnitTestSuite


static func _ramp(w: int, h: int, cell: float = 2.0) -> GwHeightfield:
	var hf := GwHeightfield.create(w, h, cell, Vector2(-10, -20))
	for r in h:
		for c in w:
			hf.set_height(c, r, c * 1.0 + r * 10.0)
	hf.compute_min_max()
	return hf


static func _tile(size: int, value: float) -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(size * size)
	t.fill(value)
	return t


func test_assemble_places_tiles() -> void:
	var tiles := {
		Vector2i(10, 20): _tile(4, 1.0),
		Vector2i(11, 20): _tile(4, 2.0),
		Vector2i(10, 21): _tile(4, 3.0),
	}
	var hf := GwHeightfieldAssembler.assemble(Rect2i(10, 20, 2, 2), tiles, 1.0, Vector2.ZERO, 4)
	assert_int(hf.width).is_equal(8)
	assert_int(hf.height).is_equal(8)
	assert_float(hf.get_height(0, 0)).is_equal(1.0)
	assert_float(hf.get_height(7, 3)).is_equal(2.0)
	assert_float(hf.get_height(3, 7)).is_equal(3.0)
	# Missing tile (11, 21) becomes NoData.
	assert_bool(is_nan(hf.get_height(7, 7))).is_true()
	assert_int(hf.count_nodata()).is_equal(16)


func test_fill_nodata_interpolates() -> void:
	var hf := GwHeightfield.create(5, 5, 1.0, Vector2.ZERO)
	hf.data.fill(10.0)
	hf.set_height(2, 2, NAN)
	hf.set_height(3, 2, NAN)
	assert_int(hf.fill_nodata()).is_equal(0)
	assert_int(hf.count_nodata()).is_equal(0)
	assert_float(hf.get_height(2, 2)).is_equal_approx(10.0, 1e-6)


func test_fill_nodata_fallback_to_min() -> void:
	var hf := GwHeightfield.create(64, 1, 1.0, Vector2.ZERO)
	hf.data.fill(NAN)
	hf.set_height(0, 0, 5.0)
	hf.set_height(1, 0, 3.0)
	# Two iterations cannot reach the far end: the rest uses the minimum.
	var fallback := hf.fill_nodata(2)
	assert_int(fallback).is_equal(60)
	assert_float(hf.get_height(63, 0)).is_equal(3.0)
	assert_int(hf.count_nodata()).is_equal(0)


func test_fill_nodata_all_missing() -> void:
	var hf := GwHeightfield.create(4, 4, 1.0, Vector2.ZERO)
	hf.data.fill(NAN)
	assert_int(hf.fill_nodata()).is_equal(-1)


func test_sample_matches_grid_points() -> void:
	var hf := _ramp(6, 5)
	for r in 5:
		for c in 6:
			var p := hf.sample_position(c, r)
			assert_float(hf.sample(p)).is_equal_approx(hf.get_height(c, r), 1e-4)


func test_sample_interpolates_and_clamps() -> void:
	var hf := _ramp(6, 5)
	var mid := hf.sample_position(2, 2) + Vector2(1.0, 0.0)
	# Halfway between c=2 and c=3 on a linear ramp.
	assert_float(hf.sample(mid)).is_equal_approx(22.5, 1e-4)
	assert_float(hf.sample(Vector2(-1000, -1000))).is_equal(hf.get_height(0, 0))


func test_normal_flat_and_slope() -> void:
	var hf := GwHeightfield.create(3, 3, 1.0, Vector2.ZERO)
	hf.data.fill(7.0)
	assert_vector(hf.normal_at(1, 1)).is_equal_approx(Vector3.UP, Vector3(1e-6, 1e-6, 1e-6))
	var ramp := _ramp(4, 4, 1.0)
	var n := ramp.normal_at(1, 1)
	assert_float(n.length()).is_equal_approx(1.0, 1e-5)
	# Height grows to +X and +Z, so the normal leans to -X and -Z.
	assert_float(n.x).is_less(0.0)
	assert_float(n.z).is_less(0.0)


func test_decimated() -> void:
	var hf := _ramp(9, 5, 2.0)
	var d := hf.decimated(2)
	assert_int(d.width).is_equal(5)
	assert_int(d.height).is_equal(3)
	assert_float(d.cell_size).is_equal(4.0)
	assert_vector(d.origin).is_equal(hf.origin)
	assert_float(d.get_height(4, 2)).is_equal(hf.get_height(8, 4))
	assert_object(hf.decimated(1)).is_same(hf)
