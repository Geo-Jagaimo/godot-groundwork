extends GdUnitTestSuite


func test_compositor_extent_and_uv() -> void:
	# Elevation tile (100, 200); imagery 4x; no decimation.
	var c := GwImageryCompositor.create(Vector2i(100, 200), 4.0, 1)
	var e := c.chunk_extent(Rect2i(0, 0, 128, 128))
	assert_float(e[0]).is_equal((100 * 256 + 0.5) * 4.0)
	assert_float(e[2] - e[0]).is_equal(512.0)
	var out := c.compose(Rect2i(0, 0, 128, 128), {})
	var img: Image = out["image"]
	assert_int(img.get_width()).is_equal(512)
	assert_vector(out["uv_scale"]).is_equal(Vector2.ONE)
	assert_vector(out["uv_offset"]).is_equal(Vector2.ZERO)
	assert_int(out["missing"]).is_equal(c.tile_range(Rect2i(0, 0, 128, 128)).get_area())


func test_compositor_places_tiles() -> void:
	var c := GwImageryCompositor.create(Vector2i(0, 0), 1.0, 1)
	var red := Image.create_empty(256, 256, false, Image.FORMAT_RGB8)
	red.fill(Color.RED)
	var blue := Image.create_empty(256, 256, false, Image.FORMAT_RGB8)
	blue.fill(Color.BLUE)
	var tiles := {
		Vector2i(0, 0): red.save_png_to_buffer(), Vector2i(1, 0): blue.save_png_to_buffer()
	}
	var out := c.compose(Rect2i(250, 0, 10, 4), tiles)
	var img: Image = out["image"]
	assert_that(img.get_pixel(0, 0)).is_equal(Color.RED)
	assert_that(img.get_pixel(img.get_width() - 1, 0)).is_equal(Color.BLUE)
	# Half-pixel offset at zoom offset 0 is handled through the UV transform.
	assert_float(out["uv_offset"].x).is_greater(0.0)
