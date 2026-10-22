extends GdUnitTestSuite
## End-to-end import from synthetic local tiles (no network).

const TILE_ROOT := "user://gw_test_tiles"
const OUTPUT_DIR := "res://.gw_test_output/"
const Z := 12
## 2 x 2 elevation tiles; (X0 + 1, Y0 + 1) is left out to test NoData filling.
const X0 := 3626
const Y0 := 1612
const PEAK := 1000.0
const BASE := 200.0


func before() -> void:
	_write_elevation_tiles()
	var req := _request("probe")
	var plan := GwImportPlan.from_request(req)
	for t in plan.imagery_tile_list():
		var img := Image.create_empty(256, 256, false, Image.FORMAT_RGB8)
		img.fill(Color8((t.x * 40) % 256, (t.y * 70) % 256, 128))
		_save_tile("imagery", t, img)
	_write_overpass_fixture(GwImportPlan.from_request(_osm_request("probe")).create_geo_reference())


func after() -> void:
	_remove_recursive(OUTPUT_DIR)
	_remove_recursive(TILE_ROOT)


static func _bbox() -> GwGeoBBox:
	var nw := GwTileMath.tile_bounds(X0, Y0, Z)
	var se := GwTileMath.tile_bounds(X0 + 1, Y0 + 1, Z)
	# Slightly inside the 2 x 2 tile block.
	var e := 0.0005
	return GwGeoBBox.from_sw_ne(se.x + e, nw.y + e, nw.z - e, se.w - e)


static func _provider(kind: GwTileProvider.Kind, folder: String) -> GwTileProvider:
	var p := GwTileProvider.new()
	p.id = "offline_" + folder
	p.display_name = "Offline " + folder
	p.kind = kind
	p.url_template = TILE_ROOT.path_join(folder + "/{z}/{x}/{y}.png")
	p.min_zoom = 0
	p.max_zoom = 13
	p.decoder = (
		GwTileProvider.Decoder.TERRARIUM
		if kind == GwTileProvider.Kind.ELEVATION
		else GwTileProvider.Decoder.NONE
	)
	p.attribution = "© synthetic " + folder
	p.attribution_short = "synthetic " + folder
	return p


static func _overpass_provider() -> GwTileProvider:
	var p := GwTileProvider.new()
	p.id = "offline_overpass"
	p.kind = GwTileProvider.Kind.VECTOR
	p.url_template = TILE_ROOT.path_join("overpass.json")
	p.attribution = "© OpenStreetMap contributors (ODbL), synthetic test data"
	p.attribution_short = "© OpenStreetMap contributors"
	return p


## Local XZ of the hill's peak (the shared corner of the four tiles).
static func _peak(georef: GwGeoReference) -> Vector2:
	var l := georef.to_local(
		GwTileMath.tile_y_to_lat(Y0 + 1, Z), GwTileMath.tile_x_to_lon(X0 + 1, Z)
	)
	return Vector2(l.x, l.z)


## A 40 m square building 300 m east of the peak, and a road crossing the area.
static func _osm_building_ring(georef: GwGeoReference) -> PackedVector2Array:
	var c := _peak(georef) + Vector2(300, 0)
	return PackedVector2Array(
		[c + Vector2(-20, -20), c + Vector2(20, -20), c + Vector2(20, 20), c + Vector2(-20, 20)]
	)


static func _write_overpass_fixture(georef: GwGeoReference) -> void:
	var to_geom := func(points: PackedVector2Array) -> Array:
		var out := []
		for p in points:
			var ll := georef.to_geo(Vector3(p.x, 0, p.y))
			out.append({"lat": ll[0], "lon": ll[1]})
		return out
	var ring := _osm_building_ring(georef)
	var closed := ring.duplicate()
	closed.append(ring[0])
	var peak := _peak(georef)
	var road := PackedVector2Array([peak + Vector2(-800, -100), peak + Vector2(800, -100)])
	var data := {
		"elements":
		[
			{
				"type": "way",
				"tags": {"building": "yes", "height": "20"},
				"geometry": to_geom.call(closed)
			},
			{"type": "way", "tags": {"highway": "residential"}, "geometry": to_geom.call(road)},
		]
	}
	DirAccess.make_dir_recursive_absolute(TILE_ROOT)
	FileAccess.open(TILE_ROOT.path_join("overpass.json"), FileAccess.WRITE).store_string(
		JSON.stringify(data)
	)


## 4 km around the peak: within the OSM area limit, still on all four tiles.
static func _osm_request(name: String) -> GwImportRequest:
	var req := _request(name)
	req.bbox = GwGeoBBox.from_center_size(
		GwTileMath.tile_y_to_lat(Y0 + 1, Z), GwTileMath.tile_x_to_lon(X0 + 1, Z), 4000, 4000
	)
	req.osm_provider = _overpass_provider()
	req.osm_use_fallbacks = false
	return req


static func _request(name: String) -> GwImportRequest:
	var req := GwImportRequest.new()
	req.import_name = name
	req.output_dir = OUTPUT_DIR
	req.bbox = _bbox()
	req.elevation_provider = _provider(GwTileProvider.Kind.ELEVATION, "terrarium")
	req.imagery_provider = _provider(GwTileProvider.Kind.IMAGERY, "imagery")
	req.imagery_zoom_offset = 1
	req.target_resolution_m = GwTileMath.ground_resolution(_bbox().center_lat(), Z)
	req.chunk_size = 128
	return req


## Gaussian hill centred on the shared corner of the four tiles.
static func _height_at_px(px: float, py: float) -> float:
	var cx := (X0 + 1) * 256.0
	var cy := (Y0 + 1) * 256.0
	var d2 := (px - cx) * (px - cx) + (py - cy) * (py - cy)
	return BASE + (PEAK - BASE) * exp(-d2 / (2.0 * 120.0 * 120.0))


static func _write_elevation_tiles() -> void:
	for ty: int in [Y0, Y0 + 1]:
		for tx: int in [X0, X0 + 1]:
			if tx == X0 + 1 and ty == Y0 + 1:
				continue
			var img := Image.create_empty(256, 256, false, Image.FORMAT_RGB8)
			for y in 256:
				for x in 256:
					var v := _height_at_px(tx * 256 + x + 0.5, ty * 256 + y + 0.5) + 32768.0
					var r := floori(v / 256.0)
					var g := floori(v) % 256
					var b := floori((v - floorf(v)) * 256.0)
					img.set_pixel(x, y, Color8(r, g, b))
			_save_tile("terrarium", Vector3i(tx, ty, Z), img)


static func _save_tile(folder: String, t: Vector3i, img: Image) -> void:
	var path := TILE_ROOT.path_join("%s/%d/%d/%d.png" % [folder, t.z, t.x, t.y])
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)


static func _remove_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		_remove_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)


func test_build_saves_scene() -> void:
	var builder := GwWorldBuilder.new()
	var stages := {}
	builder.progress.connect(func(stage: String, _d: int, _t: int) -> void: stages[stage] = true)
	var result: GwImportResult = await builder.build(_request("offline"))
	assert_bool(result.ok).override_failure_message(result.error_message).is_true()
	assert_int(result.stats["elevation_zoom"]).is_equal(Z)
	assert_int(result.stats["chunks"]).is_equal(16)
	assert_bool(stages.has("meshes") and stages.has("textures") and stages.has("scene")).is_true()
	var warned := result.warnings.any(func(w: String) -> bool: return w.contains("elevation tiles"))
	assert_bool(warned).is_true()

	var folder := OUTPUT_DIR.path_join("offline")
	var expected_files: Array[String] = [
		"offline.tscn",
		"georef.tres",
		"heightfield.res",
		"import_request.tres",
		"ATTRIBUTION.md",
		"terrain/chunk_000_000.mesh",
		"terrain/chunk_000_000.res",
		"terrain/chunk_003_003_collision.res",
	]
	for f in expected_files:
		var exists := FileAccess.file_exists(folder.path_join(f))
		assert_bool(exists).override_failure_message(f).is_true()
	var attribution := FileAccess.get_file_as_string(folder.path_join("ATTRIBUTION.md"))
	assert_str(attribution).contains("© synthetic imagery")

	var scene := auto_free((load(result.scene_path) as PackedScene).instantiate()) as GwSceneRoot
	assert_object(scene).is_not_null()
	var hf := scene.heightfield
	assert_int(hf.width).is_equal(512)
	assert_int(hf.count_nodata()).is_equal(0)
	assert_float(hf.max_height).is_equal_approx(PEAK, 2.0)

	# Peak position in geographic coordinates -> local -> terrain height.
	var peak_lat := GwTileMath.tile_y_to_lat(Y0 + 1, Z)
	var peak_lon := GwTileMath.tile_x_to_lon(X0 + 1, Z)
	assert_float(scene.geo_to_local(peak_lat, peak_lon).y).is_equal_approx(PEAK, 2.0)
	var geo := scene.local_to_geo(scene.geo_to_local(peak_lat, peak_lon))
	assert_float(geo[0]).is_equal_approx(peak_lat, 1e-7)

	# Mesh vertices sit on the heightfield.
	var chunk := scene.get_node("Terrain/Chunk_001_002") as MeshInstance3D
	var verts: PackedVector3Array = chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	assert_vector(chunk.position).is_equal(Vector3.ZERO)
	for i: int in [0, 77, verts.size() - 1]:
		var p := verts[i]
		assert_float(hf.sample(Vector2(p.x, p.z))).is_equal_approx(p.y, 1e-2)
	# Collision placement survives the .tscn round trip (whole metres + remainder).
	var shape := chunk.get_node("StaticBody3D/CollisionShape3D") as CollisionShape3D
	var expected := GwTerrainChunkBuilder.collision_transform(hf, Rect2i(128, 256, 128, 128))
	var placed := (shape.get_parent() as Node3D).position + shape.position
	assert_vector(placed).is_equal_approx(expected.origin, Vector3(1e-3, 1e-3, 1e-3))
	var mat := chunk.get_surface_override_material(0) as StandardMaterial3D
	assert_object(mat.albedo_texture).is_not_null()
	assert_str((scene.get_node("Attribution/Label") as Label).text).contains("synthetic terrarium")


func test_collision_matches_terrain() -> void:
	var result: GwImportResult = await GwWorldBuilder.new().build(_request("physics"))
	assert_bool(result.ok).override_failure_message(result.error_message).is_true()
	var scene := (load(result.scene_path) as PackedScene).instantiate() as GwSceneRoot
	add_child(scene)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := scene.get_world_3d().direct_space_state
	var hf := scene.heightfield
	var center := hf.origin + hf.get_extent() / 2.0
	for offset: Vector2 in [Vector2.ZERO, Vector2(301.7, -455.2), Vector2(-1200.0, 900.0)]:
		var xz := center + offset
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(xz.x, 5000, xz.y), Vector3(xz.x, -5000, xz.y)
		)
		var hit := space.intersect_ray(q)
		assert_bool(hit.is_empty()).override_failure_message("no hit at %s" % xz).is_false()
		if not hit.is_empty():
			assert_float(hit.position.y).is_equal_approx(hf.sample(xz), 0.05)
	scene.queue_free()


func test_osm_buildings_and_roads() -> void:
	var req := _osm_request("osm")
	req.include_buildings = true
	req.include_roads = true
	var result: GwImportResult = await GwWorldBuilder.new().build(req)
	assert_bool(result.ok).override_failure_message(result.error_message).is_true()
	assert_int(result.stats.get("buildings", 0)).is_equal(1)
	assert_int(result.stats.get("roads", 0)).is_equal(1)
	var folder := OUTPUT_DIR.path_join("osm")
	for f: String in ["buildings/building_material.tres", "roads/residential.mesh"]:
		var exists := FileAccess.file_exists(folder.path_join(f))
		assert_bool(exists).override_failure_message(f).is_true()
	var attribution := FileAccess.get_file_as_string(folder.path_join("ATTRIBUTION.md"))
	assert_str(attribution).contains("ODbL")

	var scene := (load(result.scene_path) as PackedScene).instantiate() as GwSceneRoot
	assert_int(scene.get_node("Buildings").get_child_count()).is_equal(1)
	assert_object(scene.get_node_or_null("Roads/Residential")).is_not_null()
	var label := scene.get_node("Attribution/Label") as Label
	assert_str(label.text).contains("OpenStreetMap")
	add_child(scene)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := scene.get_world_3d().direct_space_state
	var hf := scene.heightfield
	var ring := _osm_building_ring(scene.geo_reference)
	var ground := INF
	for p in ring:
		ground = minf(ground, hf.sample(p))
	var center := (ring[0] + ring[2]) / 2.0
	var hit := space.intersect_ray(
		PhysicsRayQueryParameters3D.create(
			Vector3(center.x, 5000, center.y), Vector3(center.x, -5000, center.y)
		)
	)
	assert_float(hit.get("position", Vector3.ZERO).y).is_equal_approx(ground + 20.0, 0.05)
	# Roads have no collision: a ray onto the road hits the terrain.
	var on_road := _peak(scene.geo_reference) + Vector2(-400, -100)
	var road_hit := space.intersect_ray(
		PhysicsRayQueryParameters3D.create(
			Vector3(on_road.x, 5000, on_road.y), Vector3(on_road.x, -5000, on_road.y)
		)
	)
	assert_float(road_hit.get("position", Vector3.ZERO).y).is_equal_approx(hf.sample(on_road), 0.05)
	scene.queue_free()


func test_osm_failure_is_not_fatal() -> void:
	var req := _osm_request("osm_missing")
	req.include_buildings = true
	req.osm_provider.url_template = TILE_ROOT.path_join("no_such_file.json")
	var result: GwImportResult = await GwWorldBuilder.new().build(req)
	assert_bool(result.ok).is_true()
	var warned := result.warnings.any(func(w: String) -> bool: return w.contains("OpenStreetMap"))
	assert_bool(warned).is_true()


func test_build_nodes_in_memory() -> void:
	var result := GwImportResult.new()
	var root := await GwWorldBuilder.new().build_nodes(_request("memory"), result)
	assert_bool(result.ok).is_true()
	assert_object(root).is_not_null()
	assert_int(root.get_node("Terrain").get_child_count()).is_equal(16)
	assert_bool(DirAccess.dir_exists_absolute(OUTPUT_DIR.path_join("memory"))).is_false()
	root.free()


func test_existing_output_needs_overwrite() -> void:
	var req := _request("twice")
	var first: GwImportResult = await GwWorldBuilder.new().build(req)
	assert_bool(first.ok).is_true()
	var second: GwImportResult = await GwWorldBuilder.new().build(req)
	assert_int(second.error_code).is_equal(GwImportResult.ErrorCode.OUTPUT_EXISTS)
	req.overwrite = true
	req.chunk_size = 256
	var third: GwImportResult = await GwWorldBuilder.new().build(req)
	assert_bool(third.ok).is_true()
	# The smaller re-import removed the old chunk files.
	var stray := OUTPUT_DIR.path_join("twice/terrain/chunk_003_003.mesh")
	assert_bool(FileAccess.file_exists(stray)).is_false()


func test_cancel() -> void:
	var builder := GwWorldBuilder.new()
	builder.cancel()
	var result: GwImportResult = await builder.build(_request("cancelled"))
	assert_bool(result.ok).is_false()
	assert_int(result.error_code).is_equal(GwImportResult.ErrorCode.CANCELLED)


func test_invalid_request() -> void:
	var req := _request("invalid")
	req.elevation_provider = null
	var result: GwImportResult = await GwWorldBuilder.new().build(req)
	assert_int(result.error_code).is_equal(GwImportResult.ErrorCode.INVALID_REQUEST)


func test_no_data() -> void:
	var req := _request("empty")
	req.elevation_provider.url_template = TILE_ROOT.path_join("does_not_exist/{z}/{x}/{y}.png")
	var result: GwImportResult = await GwWorldBuilder.new().build(req)
	assert_int(result.error_code).is_equal(GwImportResult.ErrorCode.NO_DATA)
