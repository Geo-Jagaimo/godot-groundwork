extends GdUnitTestSuite


func test_geocoder_parse() -> void:
	var p := GwGeocoder.parse_coordinates(" 35.681, 139.767 ")
	assert_float(p.lat).is_equal(35.681)
	assert_float(p.lon).is_equal(139.767)
	var t := GwGeocoder.parse_coordinates("15/29105/12903")
	assert_float(t.zoom).is_equal(15.0)
	assert_bool(GwTileMath.lat_lon_to_tile(t.lat, t.lon, 15) == Vector2i(29105, 12903)).is_true()
	assert_bool(GwGeocoder.parse_coordinates("Mount Fuji").is_empty()).is_true()
	assert_bool(GwGeocoder.parse_coordinates("95, 10").is_empty()).is_true()
