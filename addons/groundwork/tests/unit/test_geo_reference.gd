extends GdUnitTestSuite

const LAT0 := 35.6812
const LON0 := 139.7671


func _georef() -> GwGeoReference:
	return GwGeoReference.create(LAT0, LON0)


func test_origin_is_zero() -> void:
	var p := _georef().to_local(LAT0, LON0, 12.5)
	assert_vector(p).is_equal_approx(Vector3(0, 12.5, 0), Vector3(1e-6, 1e-6, 1e-6))


func test_axes() -> void:
	var g := _georef()
	var north := g.to_local(LAT0 + 0.01, LON0)
	var east := g.to_local(LAT0, LON0 + 0.01)
	assert_float(north.z).is_less(0.0)
	assert_float(absf(north.x)).is_less(1e-6)
	assert_float(east.x).is_greater(0.0)
	assert_float(absf(east.z)).is_less(1e-6)


func test_approximate_metres() -> void:
	# 0.01° of latitude is ~1110 m; 0.01° of longitude at 35.68°N is ~904 m.
	var g := _georef()
	assert_float(-g.to_local(LAT0 + 0.01, LON0).z).is_equal_approx(1110.0, 5.0)
	assert_float(g.to_local(LAT0, LON0 + 0.01).x).is_equal_approx(904.0, 5.0)


func test_round_trip_geo_local_geo() -> void:
	var g := _georef()
	for d: Vector2 in [Vector2(0.0, 0.0), Vector2(0.03, -0.04), Vector2(-0.045, 0.045)]:
		var lat := LAT0 + d.x
		var lon := LON0 + d.y
		var back := g.to_geo(g.to_local(lat, lon))
		# Local positions are 32-bit (~1 mm at 5 km), i.e. ~1e-8 degrees.
		assert_float(back[0]).is_equal_approx(lat, 1e-7)
		assert_float(back[1]).is_equal_approx(lon, 1e-7)


func test_round_trip_local_geo_local() -> void:
	var g := _georef()
	for p: Vector3 in [
		Vector3(0, 0, 0), Vector3(1234.5, 10, -2345.25), Vector3(-4999.0, -3, 4999.0)
	]:
		var geo := g.to_geo(p)
		var back := g.to_local(geo[0], geo[1], p.y)
		assert_vector(back).is_equal_approx(p, Vector3(1e-3, 1e-6, 1e-3))


func test_saved_resource_restores_origin_cache() -> void:
	var path := "user://gw_test_georef.tres"
	assert_int(ResourceSaver.save(_georef(), path)).is_equal(OK)
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GwGeoReference
	assert_vector(loaded.to_local(LAT0, LON0)).is_equal_approx(
		Vector3.ZERO, Vector3(1e-6, 1e-6, 1e-6)
	)
	DirAccess.remove_absolute(path)


func test_text_resources_keep_full_precision() -> void:
	# Godot 4.4 writes floats with 6 significant digits in .tres files.
	var g := GwGeoReference.create(35.3606123456, 138.7274123456)
	var b := GwGeoBBox.from_sw_ne(35.3471234567, 138.7112345678, 35.3741234567, 138.7436345678)
	g.set_bbox(b)
	var path := "user://gw_test_precision.tres"
	assert_int(ResourceSaver.save(g, path)).is_equal(OK)
	var lg := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GwGeoReference
	assert_float(lg.origin_lat).is_equal(35.3606123456)
	assert_float(lg.origin_lon).is_equal(138.7274123456)
	assert_float(lg.scale_k).is_equal(cos(deg_to_rad(35.3606123456)))
	assert_float(lg.get_bbox().east).is_equal(138.7436345678)
	assert_float(lg.get_bbox().south).is_equal(35.3471234567)
	assert_int(ResourceSaver.save(b, path)).is_equal(OK)
	var lb := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GwGeoBBox
	assert_float(lb.west).is_equal(138.7112345678)
	assert_float(lb.north).is_equal(35.3741234567)
	DirAccess.remove_absolute(path)


func test_sample_elevation_without_heightfield() -> void:
	assert_bool(is_nan(_georef().sample_elevation(Vector2.ZERO))).is_true()


func test_bbox_from_center_size() -> void:
	var b := GwGeoBBox.from_center_size(LAT0, LON0, 2000.0, 1000.0)
	assert_float(b.width_m()).is_equal_approx(2000.0, 1.0)
	assert_float(b.height_m()).is_equal_approx(1000.0, 1.0)
	assert_float(b.center_lon()).is_equal_approx(LON0, 1e-9)
	assert_bool(b.is_valid()).is_true()
