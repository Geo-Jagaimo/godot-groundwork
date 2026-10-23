@tool
class_name GwOsmLayer
extends RefCounted
## The OpenStreetMap part of an import: downloads buildings, roads and water,
## builds their meshes, saves them and adds them to the scene. Driven by
## GwWorldBuilder, whose worker pool, progress signal and save helper it uses.

const BUILDING_COLOR := Color(0.82, 0.8, 0.77)

## Endpoint the data came from (for attribution); null when nothing was downloaded.
var provider: GwTileProvider
var building_names: Array[String] = []
var building_meshes: Array[ArrayMesh] = []
var building_shapes: Array[ConcavePolygonShape3D] = []
var building_material: Material
var road_classes: Array[String] = []
var road_meshes: Array[ArrayMesh] = []
## road class -> Material
var road_materials := {}
var water_mesh: ArrayMesh
var water_material: Material


## Downloads and builds everything. Failures only add warnings to [param result].
func generate(
	builder: GwWorldBuilder,
	plan: GwImportPlan,
	hf: GwHeightfield,
	georef: GwGeoReference,
	result: GwImportResult
) -> void:
	var req := plan.request
	var client := GwOverpassClient.new()
	if builder.cache != null:
		client.cache = builder.cache
	client.user_agent = builder.user_agent
	var query := GwOverpassClient.build_query(
		req.bbox,
		req.include_buildings,
		req.include_roads,
		client.query_timeout_sec,
		req.include_water
	)
	var endpoints := plan.osm_endpoints()
	var state := {"done": false, "response": {}}
	var run := func() -> void:
		state["response"] = await client.fetch(query, endpoints, builder.token, builder.host_node)
		state["done"] = true
	run.call()
	var tree := Engine.get_main_loop() as SceneTree
	while not state["done"]:
		# Total is unknown (0): the panel shows the downloaded size instead.
		builder.emit_progress("osm_download", client.downloaded_bytes, 0)
		await tree.process_frame
	var response: Dictionary = state["response"]
	if builder.token.is_cancelled():
		return
	if not response["ok"]:
		(
			result
			. warnings
			. append(
				(
					"Could not download OpenStreetMap data (%s); buildings, roads and water were skipped."
					% response["error"]
				)
			)
		)
		return
	builder.logger.info(
		"OSM data from %s (%d bytes)" % [response["endpoint"], response["text"].length()]
	)
	provider = endpoints[0]
	result.stats["osm_source"] = response["endpoint"]

	var text: String = response["text"]
	var parsed: Array = await builder.run_parallel(
		"osm_parse", 1, func(_i: int) -> Variant: return GwOsmParser.parse(text, georef)
	)
	var osm: GwOsmParser.Result = parsed[0]
	if osm == null or not osm.error.is_empty():
		result.warnings.append(
			"Could not read OpenStreetMap data: %s" % (osm.error if osm else "?")
		)
		return
	if osm.broken_rings > 0:
		result.warnings.append(
			"%d multipolygon building outlines were incomplete." % osm.broken_rings
		)

	if req.include_buildings:
		var groups := GwBuildingBuilder.group_by_chunk(osm.buildings, hf, req.chunk_size)
		var keys := groups.keys()
		keys.sort()
		var level_h := req.building_level_height_m
		var default_h := req.building_default_height_m
		var built := await builder.run_parallel(
			"buildings",
			keys.size(),
			func(i: int) -> Variant:
				return GwBuildingBuilder.build(groups[keys[i]], hf, level_h, default_h)
		)
		if builder.token.is_cancelled():
			return
		var count := 0
		var failed := 0
		var holes_dropped := 0
		for i in keys.size():
			var b: Dictionary = built[i]
			count += b["built"]
			failed += b["failed"]
			holes_dropped += b["holes_dropped"]
			if b["arrays"] == null:
				continue
			var key: Vector2i = keys[i]
			building_names.append("chunk_%03d_%03d" % [key.x, key.y])
			building_meshes.append(GwTerrainChunkBuilder.create_mesh(b["arrays"]))
			var shape: ConcavePolygonShape3D = null
			if req.generate_collision:
				shape = ConcavePolygonShape3D.new()
				shape.set_faces(b["faces"])
			building_shapes.append(shape)
			if i % GwWorldBuilder.MAIN_THREAD_BATCH == GwWorldBuilder.MAIN_THREAD_BATCH - 1:
				await tree.process_frame
		result.stats["buildings"] = count
		if failed > 0:
			result.warnings.append("%d building outlines could not be triangulated." % failed)
		if holes_dropped > 0:
			result.warnings.append(
				"%d buildings got a closed roof: their courtyards could not be cut." % holes_dropped
			)

	if req.include_roads:
		var groups := GwRoadBuilder.group_by_class(osm.roads)
		var classes: Array[String] = []
		for cls in GwRoadBuilder.class_names():
			if groups.has(cls):
				classes.append(cls)
		var widths := req.road_widths
		var built := await builder.run_parallel(
			"roads",
			classes.size(),
			func(i: int) -> Variant:
				return GwRoadBuilder.build(groups[classes[i]], hf, classes[i], widths)
		)
		if builder.token.is_cancelled():
			return
		var count := 0
		for i in classes.size():
			var r: Dictionary = built[i]
			count += r["built"]
			if r["arrays"] != null:
				road_classes.append(classes[i])
				road_meshes.append(GwTerrainChunkBuilder.create_mesh(r["arrays"]))
		result.stats["roads"] = count

	if req.include_water:
		var areas := osm.water_areas
		var lines := osm.water_lines
		var water: Array = await builder.run_parallel(
			"water", 1, func(_i: int) -> Variant: return GwWaterBuilder.build(areas, lines, hf)
		)
		if builder.token.is_cancelled():
			return
		var w: Dictionary = water[0]
		if w["arrays"] != null:
			water_mesh = GwTerrainChunkBuilder.create_mesh(w["arrays"])
		result.stats["water_areas"] = w["areas"]
		result.stats["water_lines"] = w["lines"]
	(
		builder
		. logger
		. info(
			(
				"OSM: %d buildings, %d roads, %d water areas"
				% [
					result.stats.get("buildings", 0),
					result.stats.get("roads", 0),
					result.stats.get("water_areas", 0),
				]
			)
		)
	)


## Saves building, road and water meshes. Existing materials are reused so that
## edits to them survive a re-import.
func save(builder: GwWorldBuilder, folder: String, result: GwImportResult) -> bool:
	var buildings_dir := folder.path_join("buildings")
	var roads_dir := folder.path_join("roads")
	var tree := Engine.get_main_loop() as SceneTree
	if not building_meshes.is_empty():
		DirAccess.make_dir_recursive_absolute(buildings_dir)
		building_material = _material_file(
			builder, buildings_dir.path_join("building_material.tres"), BUILDING_COLOR, 0.9, result
		)
		for i in building_meshes.size():
			var base := buildings_dir.path_join(building_names[i])
			if not builder.save_resource(building_meshes[i], base + ".mesh", result):
				return false
			var shape := building_shapes[i]
			if shape != null and not builder.save_resource(shape, base + "_collision.res", result):
				return false
			if i % GwWorldBuilder.MAIN_THREAD_BATCH == GwWorldBuilder.MAIN_THREAD_BATCH - 1:
				await tree.process_frame
	if water_mesh != null:
		var water_dir := folder.path_join("water")
		DirAccess.make_dir_recursive_absolute(water_dir)
		water_material = _material_file(
			builder, water_dir.path_join("water_material.tres"), GwWaterBuilder.COLOR, 0.05, result
		)
		if not builder.save_resource(water_mesh, water_dir.path_join("water.mesh"), result):
			return false
	if not road_meshes.is_empty():
		DirAccess.make_dir_recursive_absolute(roads_dir)
		for i in road_meshes.size():
			var cls := road_classes[i]
			road_materials[cls] = _material_file(
				builder,
				roads_dir.path_join(cls + "_material.tres"),
				GwRoadBuilder.CLASS_COLORS.get(cls, Color.GRAY),
				0.95,
				result
			)
			if not builder.save_resource(
				road_meshes[i], roads_dir.path_join(cls + ".mesh"), result
			):
				return false
	return result.error_code == GwImportResult.ErrorCode.NONE


## Loads the material at [param path], or creates and saves a plain one.
static func _material_file(
	builder: GwWorldBuilder, path: String, color: Color, roughness: float, result: GwImportResult
) -> Material:
	if ResourceLoader.exists(path):
		var existing := ResourceLoader.load(path)
		if existing is Material:
			return existing
	var m := _plain_material(color, roughness)
	builder.save_resource(m, path, result)
	return m


static func _plain_material(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m


## Adds Buildings, Roads and Water nodes under [param root].
func add_nodes(root: Node3D) -> void:
	# Meshes are in the root's space, so these nodes keep identity transforms.
	if not building_meshes.is_empty():
		var buildings := Node3D.new()
		buildings.name = "Buildings"
		root.add_child(buildings)
		var mat := building_material
		if mat == null:
			mat = _plain_material(BUILDING_COLOR, 0.9)
		for i in building_meshes.size():
			var mi := MeshInstance3D.new()
			mi.name = building_names[i].capitalize().replace(" ", "_")
			mi.mesh = building_meshes[i]
			mi.set_surface_override_material(0, mat)
			buildings.add_child(mi)
			if building_shapes[i] != null:
				var body := StaticBody3D.new()
				body.name = "StaticBody3D"
				mi.add_child(body)
				var shape := CollisionShape3D.new()
				shape.name = "CollisionShape3D"
				shape.shape = building_shapes[i]
				body.add_child(shape)
	if water_mesh != null:
		var water := MeshInstance3D.new()
		water.name = "Water"
		water.mesh = water_mesh
		var water_mat := water_material
		if water_mat == null:
			water_mat = _plain_material(GwWaterBuilder.COLOR, 0.05)
		water.set_surface_override_material(0, water_mat)
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(water)
	if not road_meshes.is_empty():
		var roads := Node3D.new()
		roads.name = "Roads"
		root.add_child(roads)
		for i in road_meshes.size():
			var cls := road_classes[i]
			var mat: Material = road_materials.get(cls)
			if mat == null:
				mat = _plain_material(GwRoadBuilder.CLASS_COLORS.get(cls, Color.GRAY), 0.95)
			var mi := MeshInstance3D.new()
			mi.name = cls.capitalize()
			mi.mesh = road_meshes[i]
			mi.set_surface_override_material(0, mat)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			roads.add_child(mi)
