extends GdUnitTestSuite

const ROOT := "user://gw_test_overpass"


func after() -> void:
	GwTileCache.new(ROOT.path_join("cache")).clear()
	for f in DirAccess.get_files_at(ROOT):
		DirAccess.remove_absolute(ROOT.path_join(f))
	DirAccess.remove_absolute(ROOT)


static func _endpoint(file: String) -> GwTileProvider:
	var p := GwTileProvider.new()
	p.id = "local_" + file
	p.kind = GwTileProvider.Kind.VECTOR
	p.url_template = ROOT.path_join(file)
	return p


static func _client() -> GwOverpassClient:
	var c := GwOverpassClient.new()
	c.cache = GwTileCache.new(ROOT.path_join("cache"))
	return c


static func _write(file: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT)
	var f := FileAccess.open(ROOT.path_join(file), FileAccess.WRITE)
	f.store_string(text)


func test_build_query() -> void:
	var bbox := GwGeoBBox.from_sw_ne(35.65, 139.69, 35.68, 139.72)
	var q := GwOverpassClient.build_query(bbox, true, true, 60)
	assert_str(q).starts_with("[out:json][timeout:60][bbox:35.6500000,139.6900000,35.6800000")
	assert_str(q).contains('way["building"];relation["building"]["type"="multipolygon"];')
	assert_str(q).contains('way["highway"];')
	assert_str(q).ends_with("out geom;")
	var roads_only := GwOverpassClient.build_query(bbox, false, true)
	assert_str(roads_only).not_contains("building")


func test_fetch_falls_back_to_next_endpoint() -> void:
	_write("ok.json", '{"elements": []}')
	var endpoints: Array[GwTileProvider] = [_endpoint("missing.json"), _endpoint("ok.json")]
	var r: Dictionary = await _client().fetch("q1", endpoints)
	assert_bool(r["ok"]).is_true()
	assert_str(r["endpoint"]).is_equal("local_ok.json")
	assert_str(r["text"]).is_equal('{"elements": []}')


func test_fetch_reports_all_failures() -> void:
	_write("html.json", "<html>busy</html>")
	var endpoints: Array[GwTileProvider] = [_endpoint("missing.json"), _endpoint("html.json")]
	var r: Dictionary = await _client().fetch("q2", endpoints)
	assert_bool(r["ok"]).is_false()
	assert_str(r["error"]).contains("file not found")
	assert_str(r["error"]).contains("not a JSON response")


func test_runtime_error_remark_is_a_failure() -> void:
	var body := '{"elements": [], "remark": "runtime error: Query timed out in \\"query\\""}'
	assert_bool(GwOverpassClient._check_body(body)["ok"]).is_false()
	assert_bool(GwOverpassClient._check_body('{"elements": []}')["ok"]).is_true()


func test_cached_response_is_reused() -> void:
	var client := _client()
	var path := client.cache.blob_path(GwOverpassClient.CACHE_NAMESPACE, "q3", "json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string('{"elements": [1]}')
	var endpoints: Array[GwTileProvider] = [_endpoint("missing.json")]
	endpoints[0].cache_ttl_days = 7
	var r: Dictionary = await client.fetch("q3", endpoints)
	assert_bool(r["ok"]).is_true()
	assert_bool(r["from_cache"]).is_true()
	assert_str(r["text"]).is_equal('{"elements": [1]}')
