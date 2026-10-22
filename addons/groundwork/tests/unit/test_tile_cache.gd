extends GdUnitTestSuite
## Tile provider URLs and the disk cache.

const CACHE_ROOT := "user://gw_test_cache"


func after() -> void:
	GwTileCache.new(CACHE_ROOT).clear()


func _provider() -> GwTileProvider:
	var p := GwTileProvider.new()
	p.id = "cache test"
	p.url_template = "https://example.invalid/{z}/{x}/{y}.png?key={key}"
	return p


func test_provider_url() -> void:
	var p := _provider()
	assert_str(p.tile_url(Vector3i(1, 2, 3), "abc")).is_equal(
		"https://example.invalid/3/1/2.png?key=abc"
	)
	assert_str(p.tile_extension()).is_equal("png")
	assert_bool(p.is_local()).is_false()


func test_cache_store_lookup() -> void:
	var cache := GwTileCache.new(CACHE_ROOT)
	var p := _provider()
	var t := Vector3i(5, 6, 7)
	assert_int(cache.lookup(p, t).status).is_equal(GwTileCache.Status.MISS)
	cache.store(p, t, PackedByteArray([1, 2, 3]))
	var hit := cache.lookup(p, t)
	assert_int(hit.status).is_equal(GwTileCache.Status.HIT)
	assert_array(Array(hit.data)).is_equal([1, 2, 3])
	cache.store_missing(p, Vector3i(0, 0, 1))
	assert_int(cache.lookup(p, Vector3i(0, 0, 1)).status).is_equal(GwTileCache.Status.KNOWN_MISSING)
	assert_int(cache.get_size_bytes()).is_equal(3)
	p.cacheable = false
	assert_int(cache.lookup(p, t).status).is_equal(GwTileCache.Status.MISS)


func test_looks_like_image() -> void:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGB8)
	assert_bool(GwImageUtil.looks_like_image(img.save_png_to_buffer())).is_true()
	assert_bool(GwImageUtil.looks_like_image(img.save_jpg_to_buffer())).is_true()
	var html := "<html><body>Please log in</body></html>".to_utf8_buffer()
	assert_bool(GwImageUtil.looks_like_image(html)).is_false()


func test_retry_rules() -> void:
	assert_bool(GwTileFetcher._is_retryable(HTTPRequest.RESULT_TIMEOUT, 0)).is_true()
	assert_bool(GwTileFetcher._is_retryable(HTTPRequest.RESULT_CANT_RESOLVE, 0)).is_false()
	assert_bool(GwTileFetcher._is_retryable(HTTPRequest.RESULT_SUCCESS, 503)).is_true()
	assert_bool(GwTileFetcher._is_retryable(HTTPRequest.RESULT_SUCCESS, 403)).is_false()
	var headers := PackedStringArray(["Content-Type: text/html", "Retry-After: 12"])
	assert_float(GwTileFetcher.retry_after_sec(headers)).is_equal(12.0)
	assert_float(GwTileFetcher.retry_after_sec(PackedStringArray(["Retry-After: 9999"]))).is_equal(
		GwTileFetcher.MAX_PAUSE_SEC
	)
	var date := PackedStringArray(["Retry-After: Wed, 21 Oct 2026 07:28:00 GMT"])
	assert_float(GwTileFetcher.retry_after_sec(date)).is_equal(0.0)
