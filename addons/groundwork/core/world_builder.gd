@tool
class_name GwWorldBuilder
extends RefCounted
## Runs an import: tiles -> heightfield -> chunk meshes, collision and
## textures -> files under res:// -> a scene built from standard nodes.
##
## [codeblock]
## var builder := GwWorldBuilder.new()
## builder.progress.connect(func(stage, done, total): print(stage, done, "/", total))
## var result: GwImportResult = await builder.build(request)
## [/codeblock]
##
## Heavy computation runs on WorkerThreadPool; nodes and resources that touch
## the rendering / physics servers are created on the main thread.

## [param stage] is one of the keys of [constant STAGE_LABELS].
signal progress(stage: String, done: int, total: int)

const STAGE_LABELS := {
	"elevation_tiles": "Downloading elevation tiles",
	"decode": "Decoding elevation",
	"heightfield": "Building heightfield",
	"meshes": "Building meshes",
	"imagery_tiles": "Downloading imagery",
	"textures": "Compositing textures",
	"save": "Saving files",
	"import": "Importing textures",
	"osm_download": "Downloading OpenStreetMap data",
	"osm_parse": "Reading OpenStreetMap data",
	"buildings": "Building meshes (OSM)",
	"roads": "Road meshes (OSM)",
	"water": "Water (OSM)",
	"scene": "Saving scene",
}
## Main-thread work items between yields to keep the editor responsive.
const MAIN_THREAD_BATCH := 4
## Missing elevation tiles are filled from up to this many zoom levels lower.
const PARENT_LEVELS := 4
## Stages that write files. A cancel is no longer honoured once they start, so
## the output folder is never left half-written.
const WRITE_STAGES: Array[String] = ["save", "import", "scene"]


## Generated data, before anything is written to disk.
class BuildData:
	var heightfield: GwHeightfield
	var georef: GwGeoReference
	var attribution := GwAttribution.new()
	var cells: Array[Rect2i] = []
	var names: Array[String] = []
	var meshes: Array[ArrayMesh] = []
	## Per chunk: the coarser LOD meshes (Array[ArrayMesh]), level 1 first.
	var lod_meshes: Array[Array] = []
	var shapes: Array[HeightMapShape3D] = []
	var images: Array[Image] = []
	var uv_scales: Array[Vector2] = []
	var uv_offsets: Array[Vector2] = []
	## Buildings, roads and water; null without OpenStreetMap data.
	var osm: GwOsmLayer


## Set by the editor plugin. Called as [code]await importer.call(paths)[/code]
## after PNG textures are written so the editor imports them. Without it
## (e.g. at runtime) textures are saved as PortableCompressedTexture2D .res files.
static var default_file_importer: Callable

## Overrides [member default_file_importer] for this builder.
var file_importer: Callable
## provider id -> API key.
var api_keys: Dictionary = {}
var concurrency := 6
var cache: GwTileCache
## Node that HTTPRequest children are added to (defaults to the tree root).
var host_node: Node
var token := GwCancellationToken.new()
var logger := GwLog.new()


static func stage_label(stage: String) -> String:
	return STAGE_LABELS.get(stage, stage.capitalize())


## Cancels the running build (or the next one, if none is running), unless it is
## already writing files (see [constant WRITE_STAGES]). The builder can be used
## again afterwards.
func cancel() -> void:
	token.cancel()


## Imports and saves everything under [method GwImportRequest.get_output_folder].
func build(request: GwImportRequest) -> GwImportResult:
	var started := Time.get_ticks_msec()
	logger = GwLog.new()
	var result := GwImportResult.new()
	var plan := GwImportPlan.from_request(request, api_keys)
	result.plan = plan
	result.warnings.append_array(plan.warnings)
	result.output_folder = request.get_output_folder()
	if not plan.is_valid():
		return _finish(
			result.fail(GwImportResult.ErrorCode.INVALID_REQUEST, "\n".join(plan.errors)), started
		)
	if DirAccess.dir_exists_absolute(result.output_folder) and not request.overwrite:
		return _finish(
			result.fail(
				GwImportResult.ErrorCode.OUTPUT_EXISTS, "%s already exists." % result.output_folder
			),
			started
		)
	logger.info("Import '%s' %s" % [request.import_name, str(request.bbox)])
	logger.info(plan.describe())

	var data: BuildData = await _generate(plan, result)
	if data != null and token.is_cancelled():
		result.fail(GwImportResult.ErrorCode.CANCELLED, "Import cancelled.")
	elif data != null:
		await _save(plan, data, result)
	return _finish(result, started)


## Generates the scene in memory without saving anything (textures become
## ImageTextures). The caller owns the returned node. Returns null on failure;
## [param result] receives the details when given.
func build_nodes(request: GwImportRequest, result: GwImportResult = null) -> GwSceneRoot:
	var started := Time.get_ticks_msec()
	logger = GwLog.new()
	if result == null:
		result = GwImportResult.new()
	var plan := GwImportPlan.from_request(request, api_keys)
	result.plan = plan
	result.warnings.append_array(plan.warnings)
	if not plan.is_valid():
		_finish(
			result.fail(GwImportResult.ErrorCode.INVALID_REQUEST, "\n".join(plan.errors)), started
		)
		return null
	var data: BuildData = await _generate(plan, result)
	if data == null:
		_finish(result, started)
		return null
	var textures: Array[Texture2D] = []
	for image in data.images:
		image.generate_mipmaps()
		textures.append(ImageTexture.create_from_image(image))
	var root := _assemble_scene(plan, data, textures)
	result.ok = true
	_finish(result, started)
	return root


func _generate(plan: GwImportPlan, result: GwImportResult) -> BuildData:
	var req := plan.request
	var fetcher := GwTileFetcher.new(host_node, cache)
	fetcher.concurrency = concurrency
	fetcher.api_keys = api_keys
	var data := await _generate_with(fetcher, plan, result)
	fetcher.dispose()
	if data == null and result.error_code == GwImportResult.ErrorCode.NONE:
		result.fail(GwImportResult.ErrorCode.CANCELLED, "Import cancelled.")
	if data != null:
		data.attribution.add_provider(req.elevation_provider)
		data.attribution.add_provider(req.imagery_provider)
		data.attribution.add_provider(data.osm.provider if data.osm else null)
		data.georef.attribution = data.attribution.to_text()
	return data


func _generate_with(
	fetcher: GwTileFetcher, plan: GwImportPlan, result: GwImportResult
) -> BuildData:
	var req := plan.request
	var data := BuildData.new()

	# 1. Elevation tiles. Missing ones are filled from lower zoom levels where the
	# provider has them: many providers stop at different zooms in different places.
	var ep := req.elevation_provider
	var ts := plan.elevation_tile_size
	var tiles := plan.elevation_tile_list()
	emit_progress("elevation_tiles", 0, tiles.size())
	var fetched: Dictionary = await fetcher.fetch_tiles(
		ep, tiles, token, _on_fetch_progress.bind("elevation_tiles")
	)
	if fetched["cancelled"] or token.is_cancelled():
		return null
	var tile_data: Dictionary = fetched["data"]
	var unavailable: Array[Vector3i] = []
	unavailable.append_array(fetched["missing"])
	unavailable.append_array(fetched["failed"])
	var parent_data := {}
	if not unavailable.is_empty():
		var parents := {}
		for t in unavailable:
			for dz in range(1, PARENT_LEVELS + 1):
				if t.z - dz >= ep.min_zoom:
					parents[Vector3i(t.x >> dz, t.y >> dz, t.z - dz)] = true
		var parent_list: Array[Vector3i] = []
		parent_list.assign(parents.keys())
		var parent_fetched: Dictionary = await fetcher.fetch_tiles(
			ep, parent_list, token, _on_fetch_progress.bind("elevation_tiles")
		)
		if parent_fetched["cancelled"] or token.is_cancelled():
			return null
		parent_data = parent_fetched["data"]
	logger.info(
		(
			"Elevation tiles: %d ok, %d unavailable, %d lower-zoom tiles fetched"
			% [tile_data.size(), unavailable.size(), parent_data.size()]
		)
	)
	if tile_data.is_empty() and parent_data.is_empty():
		if not fetched["failed"].is_empty():
			result.fail(
				GwImportResult.ErrorCode.NETWORK,
				"Could not download elevation tiles from %s." % ep.get_label()
			)
		else:
			result.fail(GwImportResult.ErrorCode.NO_DATA, "No elevation data in the selected area.")
		return null

	# 2. Decode on workers; unavailable tiles are cut from their closest parent.
	var jobs: Array[Dictionary] = []
	for t: Vector3i in tile_data:
		jobs.append({"tile": t, "bytes": tile_data[t], "levels": 0})
	var from_parents := 0
	for t in unavailable:
		for dz in range(1, PARENT_LEVELS + 1):
			var parent := Vector3i(t.x >> dz, t.y >> dz, t.z - dz)
			if parent_data.has(parent):
				var sub_tile := Vector2i(t.x - (parent.x << dz), t.y - (parent.y << dz))
				jobs.append(
					{"tile": t, "bytes": parent_data[parent], "levels": dz, "sub": sub_tile}
				)
				from_parents += 1
				break
	var decoder := ep.create_decoder()
	var decoded := await run_parallel(
		"decode",
		jobs.size(),
		func(i: int) -> Variant:
			var job: Dictionary = jobs[i]
			var heights := decoder.decode_bytes(job["bytes"], ts)
			if job["levels"] == 0 or heights.is_empty():
				return heights
			return GwHeightfieldAssembler.crop_parent(heights, ts, job["levels"], job["sub"])
	)
	if token.is_cancelled():
		return null
	var by_tile := {}
	for i in jobs.size():
		var t: Vector3i = jobs[i]["tile"]
		var heights: Variant = decoded[i]
		if heights is PackedFloat32Array and not (heights as PackedFloat32Array).is_empty():
			by_tile[Vector2i(t.x, t.y)] = heights
		else:
			result.warnings.append("Elevation tile %s could not be decoded." % str(t))
	if not unavailable.is_empty():
		var msg := "%d of %d elevation tiles were unavailable" % [unavailable.size(), tiles.size()]
		if from_parents > 0:
			msg += "; %d were filled from lower zoom levels" % from_parents
		result.warnings.append(msg + ". Remaining gaps were interpolated.")

	# 3. Heightfield: stitch, fill NoData, decimate.
	var raw_cell := plan.cell_size_m / plan.decimation
	var step := plan.decimation
	var bbox_samples := plan.bbox_samples()
	var hf_results := await run_parallel(
		"heightfield",
		1,
		func(_i: int) -> Variant:
			var hf := GwHeightfieldAssembler.assemble(
				plan.elevation_tiles, by_tile, raw_cell, plan.grid_origin, ts
			)
			var nodata := hf.count_nodata()
			var fallback := hf.fill_nodata(32, bbox_samples)
			hf = hf.decimated(step)
			hf.compute_min_max()
			return {"heightfield": hf, "nodata": nodata, "fallback": fallback}
	)
	if token.is_cancelled():
		return null
	var hf_info: Dictionary = hf_results[0]
	if hf_info["fallback"] < 0:
		result.fail(GwImportResult.ErrorCode.NO_DATA, "No elevation data in the selected area.")
		return null
	var hf: GwHeightfield = hf_info["heightfield"]
	data.heightfield = hf
	if hf_info["nodata"] > 0:
		var msg := "%d NoData samples were interpolated." % hf_info["nodata"]
		if hf_info["fallback"] > 0:
			msg += (
				" %d far from valid data were set to the lowest height in the area."
				% hf_info["fallback"]
			)
		result.warnings.append(msg)
	logger.info(
		(
			"Heightfield %dx%d, cell %.2f m, %.1f..%.1f m"
			% [hf.width, hf.height, hf.cell_size, hf.min_height, hf.max_height]
		)
	)

	# 4. Imagery tiles, before the meshes: without any imagery the terrain gets
	# elevation colours instead.
	var bytes_by_tile := {}
	if req.imagery_provider != null:
		var img_tiles := plan.imagery_tile_list()
		emit_progress("imagery_tiles", 0, img_tiles.size())
		var img_fetched: Dictionary = await fetcher.fetch_tiles(
			req.imagery_provider, img_tiles, token, _on_fetch_progress.bind("imagery_tiles")
		)
		if img_fetched["cancelled"] or token.is_cancelled():
			return null
		for t: Vector3i in img_fetched["data"]:
			bytes_by_tile[Vector2i(t.x, t.y)] = img_fetched["data"][t]
		var img_missing: int = img_fetched["missing"].size() + img_fetched["failed"].size()
		if bytes_by_tile.is_empty():
			result.warnings.append(
				(
					"No imagery available from %s; the terrain uses elevation colours instead."
					% req.imagery_provider.get_label()
				)
			)
		elif img_missing > 0:
			result.warnings.append(
				"%d of %d imagery tiles were unavailable." % [img_missing, img_tiles.size()]
			)

	# 5. Chunk meshes and collision heights.
	var grid := GwTerrainChunkBuilder.chunk_grid(hf, req.chunk_size)
	for cz in grid.y:
		for cx in grid.x:
			data.cells.append(GwTerrainChunkBuilder.chunk_cells(hf, req.chunk_size, cx, cz))
			data.names.append("chunk_%03d_%03d" % [cx, cz])
	var cells := data.cells
	var colors := bytes_by_tile.is_empty()
	var collision := req.generate_collision
	var lod_levels := clampi(req.lod_levels, 0, 3)
	var built := await run_parallel(
		"meshes",
		cells.size(),
		func(i: int) -> Variant:
			var lods := []
			for level in range(1, lod_levels + 1):
				var lod_step := 1 << level
				# Deep enough to cover the error of the coarser level.
				var skirt := hf.cell_size * lod_step * 2.0
				lods.append(
					GwTerrainChunkBuilder.build_lod_arrays(hf, cells[i], lod_step, colors, skirt)
				)
			return [
				GwTerrainChunkBuilder.build_arrays(hf, cells[i], colors),
				(
					GwTerrainChunkBuilder.build_collision_heights(hf, cells[i])
					if collision
					else PackedFloat32Array()
				),
				lods,
			]
	)
	if token.is_cancelled():
		return null
	var tree := _tree()
	for i in cells.size():
		data.meshes.append(GwTerrainChunkBuilder.create_mesh(built[i][0]))
		var lods: Array[ArrayMesh] = []
		for arrays: Array in built[i][2]:
			lods.append(GwTerrainChunkBuilder.create_mesh(arrays))
		data.lod_meshes.append(lods)
		data.shapes.append(
			(
				GwTerrainChunkBuilder.create_collision_shape(cells[i], built[i][1])
				if collision
				else null
			)
		)
		built[i] = null
		if i % MAIN_THREAD_BATCH == MAIN_THREAD_BATCH - 1:
			await tree.process_frame

	# 6. Chunk textures.
	if not bytes_by_tile.is_empty():
		var compositor := plan.create_compositor()
		var composed := await run_parallel(
			"textures",
			cells.size(),
			func(i: int) -> Variant: return compositor.compose(cells[i], bytes_by_tile)
		)
		if token.is_cancelled():
			return null
		for c: Dictionary in composed:
			data.images.append(c["image"])
			data.uv_scales.append(c["uv_scale"])
			data.uv_offsets.append(c["uv_offset"])

	# 7. OpenStreetMap buildings and roads (failures only produce warnings).
	data.georef = plan.create_geo_reference()
	data.georef.heightfield = hf
	if req.includes_osm():
		data.osm = GwOsmLayer.new()
		await data.osm.generate(self, plan, hf, data.georef, result)
		if token.is_cancelled():
			return null

	var stats := result.stats
	stats["elevation_zoom"] = plan.elevation_zoom
	stats["elevation_tiles"] = tiles.size()
	stats["imagery_zoom"] = plan.imagery_zoom
	stats["imagery_tiles"] = plan.imagery_tiles.get_area() if req.imagery_provider else 0
	stats["grid"] = Vector2i(hf.width, hf.height)
	stats["cell_size_m"] = hf.cell_size
	stats["chunks"] = cells.size()
	stats["triangles"] = 2 * (hf.width - 1) * (hf.height - 1)
	return data


func _save(plan: GwImportPlan, data: BuildData, result: GwImportResult) -> void:
	var req := plan.request
	var folder := req.get_output_folder()
	var terrain_dir := folder.path_join("terrain")
	var total := data.meshes.size() * 2 + 4
	var done := 0
	emit_progress("save", done, total)
	DirAccess.make_dir_recursive_absolute(terrain_dir)

	if not save_resource(data.heightfield, folder.path_join("heightfield.res"), result):
		return
	if not save_resource(data.georef, folder.path_join("georef.tres"), result):
		return
	if not save_resource(req.duplicate(), folder.path_join("import_request.tres"), result, false):
		return
	var md_path := folder.path_join("ATTRIBUTION.md")
	var md := FileAccess.open(md_path, FileAccess.WRITE)
	if md == null:
		# Attribution is a licence requirement: do not produce a scene without it.
		result.fail(
			GwImportResult.ErrorCode.SAVE_FAILED,
			"Could not write %s (%s)." % [md_path, error_string(FileAccess.get_open_error())]
		)
		return
	md.store_string(data.attribution.to_markdown(req.import_name, req.bbox))
	md.close()
	result.files.append(md_path)
	done += 4
	emit_progress("save", done, total)

	var tree := _tree()
	for i in data.meshes.size():
		var base := terrain_dir.path_join(data.names[i])
		if not save_resource(data.meshes[i], base + ".mesh", result):
			return
		for level in data.lod_meshes[i].size():
			var lod_path := base + "_lod%d.mesh" % (level + 1)
			if not save_resource(data.lod_meshes[i][level], lod_path, result):
				return
		if data.shapes[i] != null:
			if not save_resource(data.shapes[i], base + "_collision.res", result):
				return
		done += 1
		if i % MAIN_THREAD_BATCH == MAIN_THREAD_BATCH - 1:
			emit_progress("save", done, total)
			await tree.process_frame

	var textures: Array[Texture2D] = []
	if not data.images.is_empty():
		textures = await _save_textures(terrain_dir, data, result)
		if textures.is_empty():
			return
	if data.osm != null and not await data.osm.save(self, folder, result):
		return
	# Only now drop what a previous import left behind. Files written above keep
	# their .import, so the user's texture import settings survive a re-import.
	_remove_stale_files(terrain_dir, result.files, "chunk_")
	_remove_stale_files(folder.path_join("buildings"), result.files, "chunk_")
	_remove_stale_files(folder.path_join("roads"), result.files, "", ".mesh")
	_remove_stale_files(folder.path_join("water"), result.files, "", ".mesh")

	emit_progress("scene", 0, 1)
	var root := _assemble_scene(plan, data, textures)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	root.free()
	if err != OK:
		result.fail(
			GwImportResult.ErrorCode.SAVE_FAILED,
			"Could not pack the scene (%s)." % error_string(err)
		)
		return
	var scene_path := req.get_scene_path()
	if not save_resource(packed, scene_path, result):
		return
	emit_progress("scene", 1, 1)
	result.scene_path = scene_path
	result.ok = true


func _save_textures(
	terrain_dir: String, data: BuildData, result: GwImportResult
) -> Array[Texture2D]:
	var textures: Array[Texture2D] = []
	textures.resize(data.images.size())
	var importer := file_importer if file_importer.is_valid() else default_file_importer
	var tree := _tree()
	if importer.is_valid():
		var not_imported := 0
		var pngs := PackedStringArray()
		for i in data.images.size():
			var path := terrain_dir.path_join(data.names[i] + ".png")
			if data.images[i].save_png(path) != OK:
				result.fail(GwImportResult.ErrorCode.SAVE_FAILED, "Could not write %s." % path)
				return []
			pngs.append(path)
			if i % MAIN_THREAD_BATCH == MAIN_THREAD_BATCH - 1:
				emit_progress("save", i, data.images.size())
				await tree.process_frame
		emit_progress("import", 0, 1)
		await importer.call(pngs)
		emit_progress("import", 1, 1)
		for i in pngs.size():
			var tex := ResourceLoader.load(pngs[i], "Texture2D", ResourceLoader.CACHE_MODE_REPLACE)
			if tex is Texture2D:
				textures[i] = tex
				result.files.append(pngs[i])
			else:
				not_imported += 1
		if not_imported > 0:
			(
				result
				. warnings
				. append(
					(
						"%d textures were not imported by the editor and were saved as .res files instead."
						% not_imported
					)
				)
			)
	for i in data.images.size():
		if textures[i] != null:
			continue
		var image := data.images[i]
		image.generate_mipmaps()
		var tex := PortableCompressedTexture2D.new()
		# Outside the editor the compressed data is dropped after upload unless
		# kept, and the saved .res would be empty.
		tex.keep_compressed_buffer = true
		tex.create_from_image(image, PortableCompressedTexture2D.COMPRESSION_MODE_LOSSLESS)
		if not save_resource(tex, terrain_dir.path_join(data.names[i] + ".res"), result):
			return []
		textures[i] = tex
		if i % MAIN_THREAD_BATCH == MAIN_THREAD_BATCH - 1:
			await tree.process_frame
	return textures


func _assemble_scene(
	plan: GwImportPlan, data: BuildData, textures: Array[Texture2D]
) -> GwSceneRoot:
	var req := plan.request
	var hf := data.heightfield
	var root := GwSceneRoot.new()
	root.name = req.import_name.validate_node_name()
	root.geo_reference = data.georef
	root.heightfield = hf
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	root.add_child(terrain)

	var plain_material: StandardMaterial3D
	if textures.is_empty():
		plain_material = StandardMaterial3D.new()
		plain_material.vertex_color_use_as_albedo = true
		plain_material.roughness = 1.0

	# Distance LOD: chunk i's LOD k is visible from ranges[k - 1] to ranges[k].
	var ranges := PackedFloat32Array([0.0])
	var span := req.chunk_size * hf.cell_size * req.lod_distance
	for level in range(data.lod_meshes[0].size() if not data.lod_meshes.is_empty() else 0):
		ranges.append(span * (1 << level))
	ranges.append(0.0)

	for i in data.meshes.size():
		var cells := data.cells[i]
		var material: Material = plain_material
		if not textures.is_empty():
			material = _imagery_material(textures[i], data.uv_scales[i], data.uv_offsets[i])
		var mi := MeshInstance3D.new()
		mi.name = data.names[i].capitalize().replace(" ", "_")
		mi.mesh = data.meshes[i]
		mi.set_surface_override_material(0, material)
		_set_visibility_range(mi, ranges[0], ranges[1])
		terrain.add_child(mi)
		for level in data.lod_meshes[i].size():
			var lod := MeshInstance3D.new()
			lod.name = "Lod%d" % (level + 1)
			lod.mesh = data.lod_meshes[i][level]
			lod.set_surface_override_material(0, material)
			_set_visibility_range(lod, ranges[level + 1], ranges[level + 2])
			mi.add_child(lod)
		if data.shapes[i] != null:
			# Whole metres on the body and the remainder on the shape: both
			# survive the 6-significant-digit floats of .tscn files exactly.
			var xf := GwTerrainChunkBuilder.collision_transform(hf, cells)
			var whole := xf.origin.floor()
			var body := StaticBody3D.new()
			body.name = "StaticBody3D"
			body.position = whole
			mi.add_child(body)
			var shape := CollisionShape3D.new()
			shape.name = "CollisionShape3D"
			shape.shape = data.shapes[i]
			shape.transform = Transform3D(xf.basis, xf.origin - whole)
			body.add_child(shape)

	if data.osm != null:
		data.osm.add_nodes(root)
	if req.add_attribution_label and not data.attribution.is_empty():
		root.add_child(_attribution_overlay(data.attribution.to_short_text()))
	_set_owner_recursive(root, root)
	return root


## Shows [param mi] between [param begin] and [param end] metres (0 = no
## limit). No margins: with fading disabled they act as hysteresis, and
## instances that start inside a margin stay hidden until the camera moves.
static func _set_visibility_range(mi: GeometryInstance3D, begin: float, end: float) -> void:
	mi.visibility_range_begin = begin
	mi.visibility_range_end = end
	mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


static func _imagery_material(
	texture: Texture2D, uv_scale: Vector2, uv_offset: Vector2
) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = texture
	m.roughness = 1.0
	m.texture_repeat = false
	m.uv1_scale = Vector3(uv_scale.x, uv_scale.y, 1.0)
	m.uv1_offset = Vector3(uv_offset.x, uv_offset.y, 0.0)
	return m


static func _attribution_overlay(text: String) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = "Attribution"
	layer.layer = 100
	var label := Label.new()
	label.name = "Label"
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.anchor_left = 1.0
	label.anchor_top = 1.0
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = -8.0
	label.offset_top = -8.0
	label.offset_right = -8.0
	label.offset_bottom = -8.0
	label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(label)
	return layer


## Runs fn(i) for i in [0, count) on WorkerThreadPool while the main thread keeps
## processing frames. Returns the results in order (null where skipped). Also
## used by GwOsmLayer.
func run_parallel(stage: String, count: int, fn: Callable) -> Array:
	var results := []
	results.resize(count)
	if count == 0:
		return results
	var state := {"done": 0}
	var mutex := Mutex.new()
	var cancel_token := token
	var task := func(i: int) -> void:
		var value: Variant = null
		if not cancel_token.is_cancelled():
			value = fn.call(i)
		mutex.lock()
		results[i] = value
		state["done"] += 1
		mutex.unlock()
	var started := Time.get_ticks_msec()
	var id := WorkerThreadPool.add_group_task(task, count, -1, false, "Groundwork: " + stage)
	var tree := _tree()
	while not WorkerThreadPool.is_group_task_completed(id):
		mutex.lock()
		var done: int = state["done"]
		mutex.unlock()
		emit_progress(stage, done, count)
		await tree.process_frame
	WorkerThreadPool.wait_for_group_task_completion(id)
	emit_progress(stage, count, count)
	logger.debug("%s: %d items in %d ms" % [stage, count, Time.get_ticks_msec() - started])
	return results


func save_resource(
	res: Resource, path: String, result: GwImportResult, take_path: bool = true
) -> bool:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		result.fail(
			GwImportResult.ErrorCode.SAVE_FAILED,
			"Could not save %s (%s)." % [path, error_string(err)]
		)
		return false
	if take_path:
		res.take_over_path(path)
	result.files.append(path)
	return true


## Removes files of a previous import that this import did not write, so a
## smaller re-import leaves no strays. Only names with [param prefix] and
## [param suffix] are considered; a file's ".import" goes with it.
static func _remove_stale_files(
	dir_path: String, keep: PackedStringArray, prefix: String = "", suffix: String = ""
) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		var name := f.trim_suffix(".import")
		if name.begins_with(prefix) and name.ends_with(suffix):
			if dir_path.path_join(name) not in keep:
				dir.remove(f)


static func _set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owner_recursive(child, owner)


func _on_fetch_progress(done: int, total: int, stage: String) -> void:
	emit_progress(stage, done, total)


func emit_progress(stage: String, done: int, total: int) -> void:
	progress.emit(stage, done, total)


func _finish(result: GwImportResult, started_msec: int) -> GwImportResult:
	# A cancel only applies to one build.
	token = GwCancellationToken.new()
	result.stats["seconds"] = (Time.get_ticks_msec() - started_msec) / 1000.0
	for w in result.warnings:
		logger.warn(w)
	if result.ok:
		logger.info("Done in %.1f s: %s" % [result.stats["seconds"], result.scene_path])
	else:
		logger.error(result.error_message)
	logger.save()
	return result


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree
