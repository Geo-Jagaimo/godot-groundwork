extends GdUnitTestSuite


func test_known_tile_tokyo_station() -> void:
	# Tokyo Station (35.681236, 139.767125) at z15 is tile 29105/12903.
	assert_that(GwTileMath.lat_lon_to_tile(35.681236, 139.767125, 15)).is_equal(
		Vector2i(29105, 12903)
	)


func test_tile_origin_round_trip() -> void:
	for z: int in [0, 5, 12, 18]:
		var x: int = 123 % (1 << z)
		var y: int = 77 % (1 << z)
		var lon := GwTileMath.tile_x_to_lon(x, z)
		var lat := GwTileMath.tile_y_to_lat(y, z)
		assert_float(GwTileMath.lon_to_tile_x(lon, z)).is_equal_approx(x, 1e-9)
		assert_float(GwTileMath.lat_to_tile_y(lat, z)).is_equal_approx(y, 1e-9)


func test_world_edges() -> void:
	assert_float(GwTileMath.tile_y_to_lat(0, 0)).is_equal_approx(GwTileMath.MAX_LATITUDE, 1e-9)
	assert_float(GwTileMath.tile_x_to_lon(0, 3)).is_equal(-180.0)
	assert_float(GwTileMath.lat_to_tile_y(0.0, 1)).is_equal_approx(1.0, 1e-12)


func test_mercator_round_trip() -> void:
	for lat: float in [-80.0, -35.5, 0.0, 35.681236, 60.0]:
		var y := GwTileMath.mercator_y(lat)
		assert_float(GwTileMath.lat_from_mercator_y(y)).is_equal_approx(lat, 1e-10)
	assert_float(GwTileMath.mercator_x(180.0)).is_equal_approx(PI * GwTileMath.EARTH_RADIUS, 1e-6)


func test_ground_resolution() -> void:
	assert_float(GwTileMath.ground_resolution(0.0, 0)).is_equal_approx(156543.034, 1e-3)
	# ~3.9 m/px at 35°N, z15 (design table).
	assert_float(GwTileMath.ground_resolution(35.0, 15)).is_equal_approx(3.913, 0.01)
	assert_float(GwTileMath.ground_resolution(35.0, 14)).is_equal_approx(7.827, 0.01)


func test_resolution_to_zoom() -> void:
	# 10 m at 35°N: z14 (7.8 m) is closer than z13 (15.7 m).
	assert_int(GwTileMath.resolution_to_zoom(10.0, 35.0)).is_equal(14)
	assert_int(GwTileMath.resolution_to_zoom(4.0, 35.0)).is_equal(15)
	assert_int(GwTileMath.resolution_to_zoom(4.0, 35.0, 0, 14)).is_equal(14)
	assert_int(GwTileMath.resolution_to_zoom(1000.0, 35.0, 5, 15)).is_equal(7)


func test_tile_range_covers_bbox() -> void:
	var bbox := GwGeoBBox.from_sw_ne(35.65, 139.69, 35.68, 139.72)
	var r := GwTileMath.tile_range(bbox, 14)
	var nw := GwTileMath.tile_bounds(r.position.x, r.position.y, 14)
	var se := GwTileMath.tile_bounds(r.end.x - 1, r.end.y - 1, 14)
	assert_bool(nw.z >= bbox.north and nw.y <= bbox.west).is_true()
	assert_bool(se.x <= bbox.south and se.w >= bbox.east).is_true()
	assert_int(r.get_area()).is_equal(GwTileMath.tiles_in_range(r, 14).size())


func test_tile_range_exclusive_edges() -> void:
	# A bbox exactly equal to one tile must not include its neighbours.
	# (tile_bounds() returns a 32-bit Vector4, so build the box from doubles.)
	var b := GwGeoBBox.from_sw_ne(
		GwTileMath.tile_y_to_lat(201, 9),
		GwTileMath.tile_x_to_lon(100, 9),
		GwTileMath.tile_y_to_lat(200, 9),
		GwTileMath.tile_x_to_lon(101, 9)
	)
	var r := GwTileMath.tile_range(b, 9)
	assert_that(r).is_equal(Rect2i(100, 200, 1, 1))


func test_tile_range_edges_just_inside_boundaries() -> void:
	# Exact edges of tiles 14540..14542 x 6440..6442 at z14. The south edge comes
	# out ~1e-12 tile north of the boundary; it must not lose the last row.
	var b := GwGeoBBox.from_sw_ne(
		GwTileMath.tile_y_to_lat(6443, 14),
		GwTileMath.tile_x_to_lon(14540, 14),
		GwTileMath.tile_y_to_lat(6440, 14),
		GwTileMath.tile_x_to_lon(14543, 14)
	)
	assert_that(GwTileMath.tile_range(b, 14)).is_equal(Rect2i(14540, 6440, 3, 3))
	# The same after the text round trip import_request.tres goes through.
	var copy := GwGeoBBox.new()
	copy.bounds_text = b.bounds_text
	assert_that(GwTileMath.tile_range(copy, 14)).is_equal(Rect2i(14540, 6440, 3, 3))
	# The 1/4 of the edge tile is still included.
	b.east = GwTileMath.tile_x_to_lon(14543.25, 14)
	assert_int(GwTileMath.tile_range(b, 14).size.x).is_equal(4)


func test_tile_range_world_edge() -> void:
	var b := GwGeoBBox.from_sw_ne(10.0, 179.5, 10.5, 180.0)
	var r := GwTileMath.tile_range(b, 12)
	assert_int(r.end.x).is_equal(4096)
	assert_int(r.position.x).is_equal(GwTileMath.lat_lon_to_tile(10.5, 179.5, 12).x)
