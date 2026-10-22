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


func test_crop_parent() -> void:
	# 4 px parent with a ramp; child (1, 0) one level down is its top-right quarter.
	var parent := PackedFloat32Array()
	for y in 4:
		for x in 4:
			parent.append(x * 10.0 + y)
	var child := GwHeightfieldAssembler.crop_parent(parent, 4, 1, Vector2i(1, 0))
	assert_int(child.size()).is_equal(16)
	# Child pixel centres map to parent x = 1.75, 2.25, 2.75, 3.25 (clamped to 3).
	assert_float(child[0]).is_equal_approx(17.5, 1e-4)
	assert_float(child[3]).is_equal_approx(30.0, 1e-4)
	var nodata := PackedFloat32Array()
	nodata.resize(16)
	nodata.fill(NAN)
	(
		assert_bool(is_nan(GwHeightfieldAssembler.crop_parent(nodata, 4, 2, Vector2i(3, 3))[5]))
		. is_true()
	)


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


func test_fill_nodata_fallback_uses_region_minimum() -> void:
	# A deep value outside the region must not be used to fill holes inside it.
	var hf := GwHeightfield.create(64, 1, 1.0, Vector2.ZERO)
	hf.data.fill(NAN)
	hf.set_height(0, 0, -1000.0)
	hf.set_height(40, 0, 20.0)
	hf.set_height(41, 0, 25.0)
	hf.fill_nodata(1, Rect2i(30, 0, 20, 1))
	assert_float(hf.get_height(60, 0)).is_equal(20.0)


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


func test_decimated_keeps_the_far_edge() -> void:
	# 10 samples, step 4: 0, 4, 8 and one more that repeats sample 9.
	var hf := _ramp(10, 10, 1.0)
	var d := hf.decimated(4)
	assert_int(d.width).is_equal(4)
	assert_float(d.get_height(3, 0)).is_equal(hf.get_height(9, 0))
	assert_float((d.width - 1) * d.cell_size).is_greater_equal((hf.width - 1) * hf.cell_size)
