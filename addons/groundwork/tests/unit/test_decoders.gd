extends GdUnitTestSuite


static func _image(pixels: Array[Color]) -> Image:
	var img := Image.create_empty(pixels.size(), 1, false, Image.FORMAT_RGB8)
	for i in pixels.size():
		img.set_pixel(i, 0, pixels[i])
	return img


static func _rgb(r: int, g: int, b: int) -> Color:
	return Color8(r, g, b)


func test_terrarium_known_values() -> void:
	assert_float(GwTerrariumDecoder.decode_pixel(128, 0, 0)).is_equal(0.0)
	assert_float(GwTerrariumDecoder.decode_pixel(129, 0, 0)).is_equal(256.0)
	assert_float(GwTerrariumDecoder.decode_pixel(128, 100, 128)).is_equal(100.5)
	assert_float(GwTerrariumDecoder.decode_pixel(127, 255, 0)).is_equal(-1.0)
	# Mt. Fuji summit, 3776 m = 128 * 256 + 3776 -> R=142, G=192.
	assert_float(GwTerrariumDecoder.decode_pixel(142, 192, 0)).is_equal(3776.0)


func test_terrarium_image() -> void:
	var img := _image([_rgb(128, 0, 0), _rgb(129, 0, 0), _rgb(128, 100, 128)])
	var h := GwTerrariumDecoder.new().decode(img)
	assert_array(Array(h)).is_equal([0.0, 256.0, 100.5])


func test_terrarium_accepts_rgba() -> void:
	var img := _image([_rgb(129, 0, 0)])
	img.convert(Image.FORMAT_RGBA8)
	assert_float(GwTerrariumDecoder.new().decode(img)[0]).is_equal(256.0)


func test_gsi_known_values() -> void:
	assert_float(GwGsiDemDecoder.decode_pixel(0, 0, 100)).is_equal_approx(1.0, 1e-6)
	# 3776.00 m = 377600 = 0x05C300
	assert_float(GwGsiDemDecoder.decode_pixel(0x05, 0xC3, 0x00)).is_equal_approx(3776.0, 1e-4)
	# -1.00 m = 2^24 - 100
	assert_float(GwGsiDemDecoder.decode_pixel(0xFF, 0xFF, 0x9C)).is_equal_approx(-1.0, 1e-6)


func test_gsi_nodata() -> void:
	assert_bool(is_nan(GwGsiDemDecoder.decode_pixel(128, 0, 0))).is_true()
	var h := GwGsiDemDecoder.new().decode(_image([_rgb(128, 0, 0), _rgb(0, 0, 0)]))
	assert_bool(is_nan(h[0])).is_true()
	assert_float(h[1]).is_equal(0.0)


func test_decode_bytes_png() -> void:
	var img := Image.create_empty(256, 256, false, Image.FORMAT_RGB8)
	img.fill(_rgb(128, 0, 0))
	img.set_pixel(1, 0, _rgb(129, 0, 0))
	var h := GwTerrariumDecoder.new().decode_bytes(img.save_png_to_buffer())
	assert_int(h.size()).is_equal(256 * 256)
	assert_float(h[0]).is_equal(0.0)
	assert_float(h[1]).is_equal(256.0)


func test_decode_bytes_resamples_other_tile_sizes() -> void:
	var img := Image.create_empty(512, 512, false, Image.FORMAT_RGB8)
	img.fill(_rgb(129, 0, 0))
	img.set_pixel(511, 511, _rgb(130, 0, 0))
	var h := GwTerrariumDecoder.new().decode_bytes(img.save_png_to_buffer())
	assert_int(h.size()).is_equal(256 * 256)
	assert_float(h[0]).is_equal(256.0)
	assert_float(h[256 * 256 - 1]).is_equal(512.0)


func test_decode_bytes_garbage() -> void:
	var junk := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13])
	assert_int(GwTerrariumDecoder.new().decode_bytes(junk).size()).is_equal(0)


func test_provider_creates_decoder() -> void:
	var p := GwTileProvider.new()
	p.decoder = GwTileProvider.Decoder.GSI_DEM
	assert_object(p.create_decoder()).is_instanceof(GwGsiDemDecoder)
	p.decoder = GwTileProvider.Decoder.NONE
	assert_object(p.create_decoder()).is_null()
