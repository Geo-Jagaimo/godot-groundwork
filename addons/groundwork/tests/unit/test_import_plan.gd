extends GdUnitTestSuite


static func _provider(kind: GwTileProvider.Kind, max_zoom: int = 15) -> GwTileProvider:
	var p := GwTileProvider.new()
	p.id = "test_%d" % kind
	p.kind = kind
	p.url_template = "user://nowhere/{z}/{x}/{y}.png"
	p.max_zoom = max_zoom
	p.decoder = (
		GwTileProvider.Decoder.TERRARIUM
		if kind == GwTileProvider.Kind.ELEVATION
		else GwTileProvider.Decoder.NONE
	)
	return p


static func _request(size_m: float = 2000.0, lat: float = 35.36) -> GwImportRequest:
	var req := GwImportRequest.new()
	req.import_name = "plan_test"
	req.bbox = GwGeoBBox.from_center_size(lat, 138.73, size_m, size_m)
	req.elevation_provider = _provider(GwTileProvider.Kind.ELEVATION)
	return req


func test_valid_plan() -> void:
	var plan := GwImportPlan.from_request(_request())
	assert_bool(plan.is_valid()).is_true()
	assert_int(plan.elevation_zoom).is_equal(14)
	assert_int(plan.grid_width).is_equal(plan.elevation_tiles.size.x * 256)
	assert_float(plan.cell_size_m).is_equal_approx(GwTileMath.ground_resolution(35.36, 14), 0.01)
	assert_int(plan.triangle_count).is_equal(2 * (plan.grid_width - 1) * (plan.grid_height - 1))
	assert_int(plan.imagery_zoom).is_equal(-1)


func test_grid_covers_bbox() -> void:
	var req := _request(3000.0)
	var plan := GwImportPlan.from_request(req)
	var g := plan.create_geo_reference()
	var sw := g.to_local(req.bbox.south, req.bbox.west)
	var ne := g.to_local(req.bbox.north, req.bbox.east)
	var extent := Vector2(plan.grid_width - 1, plan.grid_height - 1) * plan.cell_size_m
	assert_float(plan.grid_origin.x).is_less_equal(sw.x)
	assert_float(plan.grid_origin.y).is_less_equal(ne.z)
	assert_float(plan.grid_origin.x + extent.x).is_greater_equal(ne.x)
	assert_float(plan.grid_origin.y + extent.y).is_greater_equal(sw.z)


func test_errors() -> void:
	var req := _request()
	req.bbox = null
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_false()

	req = _request()
	req.import_name = "bad/name"
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_false()

	req = _request()
	req.output_dir = "user://geo"
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_false()

	req = _request(60000.0)
	var plan := GwImportPlan.from_request(req)
	assert_bool(plan.is_valid()).is_false()
	assert_str(plan.errors[0]).contains("limit")


func test_warnings() -> void:
	var plan := GwImportPlan.from_request(_request(25000.0))
	assert_bool(plan.is_valid()).is_true()
	assert_bool(plan.warnings.size() > 0).is_true()
	var high := GwImportPlan.from_request(_request(2000.0, 65.0))
	var warned := Array(high.warnings).any(func(w: String) -> bool: return w.contains("Latitude"))
	assert_bool(warned).is_true()


func test_coverage() -> void:
	var req := _request()
	req.elevation_provider.coverage_bbox = Vector4(0, 0, 10, 10)
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_false()
	req.elevation_provider.coverage_bbox = Vector4(20, 122, 46, 154)
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_true()


func test_api_key_required() -> void:
	var req := _request()
	req.elevation_provider.requires_api_key = true
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_false()
	var keys := {req.elevation_provider.id: "k"}
	assert_bool(GwImportPlan.from_request(req, keys).is_valid()).is_true()


func test_imagery_zoom_and_tiles() -> void:
	var req := _request()
	req.imagery_provider = _provider(GwTileProvider.Kind.IMAGERY, 18)
	req.imagery_zoom_offset = 2
	var plan := GwImportPlan.from_request(req)
	assert_int(plan.imagery_zoom).is_equal(16)
	# 4x the elevation tiles per side, minus the half-pixel border at most.
	assert_int(plan.imagery_tiles.size.x).is_between(
		plan.elevation_tiles.size.x * 4 - 1, plan.elevation_tiles.size.x * 4
	)
	req.imagery_provider.max_zoom = 15
	assert_int(GwImportPlan.from_request(req).imagery_zoom).is_equal(15)


func test_decimation() -> void:
	var req := _request()
	req.mesh_decimation = 2
	var plan := GwImportPlan.from_request(req)
	assert_int(plan.grid_width).is_equal(plan.elevation_tiles.size.x * 128 + 1)
	# The decimated grid reaches at least as far as the full one.
	var extent := (plan.grid_width - 1) * plan.cell_size_m
	var full := (plan.elevation_tiles.size.x * 256 - 1) * plan.cell_size_m / 2.0
	assert_float(extent).is_greater_equal(full)
	assert_float(plan.cell_size_m).is_equal_approx(
		GwTileMath.ground_resolution(35.36, 14) * 2, 0.02
	)


func test_osm_area_limit() -> void:
	var req := _request(6000.0)
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_true()
	req.include_buildings = true
	var plan := GwImportPlan.from_request(req)
	assert_bool(plan.is_valid()).is_false()
	assert_str(plan.errors[0]).contains("km²")
	req.bbox = GwGeoBBox.from_center_size(35.36, 138.73, 4000.0, 4000.0)
	assert_bool(GwImportPlan.from_request(req).is_valid()).is_true()


func test_osm_endpoints_order() -> void:
	var req := _request()
	req.include_roads = true
	var custom := _provider(GwTileProvider.Kind.VECTOR)
	custom.id = "custom_overpass"
	req.osm_provider = custom
	req.osm_use_fallbacks = false
	assert_int(GwImportPlan.from_request(req).osm_endpoints().size()).is_equal(1)
	req.osm_use_fallbacks = true
	var endpoints := GwImportPlan.from_request(req).osm_endpoints()
	assert_str(endpoints[0].id).is_equal("custom_overpass")
	assert_int(endpoints.size()).is_greater(1)
