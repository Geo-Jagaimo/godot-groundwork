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
