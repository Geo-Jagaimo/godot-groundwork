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
	"scene": "Saving scene",
}
## Main-thread work items between yields to keep the editor responsive.
const MAIN_THREAD_BATCH := 4


## Generated data, before anything is written to disk.
class BuildData:
	var heightfield: GwHeightfield
	var georef: GwGeoReference
	var attribution := GwAttribution.new()
	var cells: Array[Rect2i] = []
	var names: Array[String] = []
	var meshes: Array[ArrayMesh] = []
	var shapes: Array[HeightMapShape3D] = []
	var images: Array[Image] = []
	var uv_scales: Array[Vector2] = []
	var uv_offsets: Array[Vector2] = []


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
	if data != null:
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
	return data


func _generate_with(
	fetcher: GwTileFetcher, plan: GwImportPlan, result: GwImportResult
) -> BuildData:
	var req := plan.request
	var data := BuildData.new()

	# 1. Elevation tiles.
	var tiles := plan.elevation_tile_list()
	_emit("elevation_tiles", 0, tiles.size())
	var fetched: Dictionary = await fetcher.fetch_tiles(
		req.elevation_provider, tiles, token, _on_fetch_progress.bind("elevation_tiles")
	)
	if fetched["cancelled"] or token.is_cancelled():
		return null
	var tile_data: Dictionary = fetched["data"]
	var missing: int = fetched["missing"].size()
	var failed: int = fetched["failed"].size()
	logger.info(
		"Elevation tiles: %d ok, %d missing, %d failed" % [tile_data.size(), missing, failed]
	)
	if tile_data.is_empty():
		if failed > 0:
			result.fail(
				GwImportResult.ErrorCode.NETWORK,
				"Could not download elevation tiles from %s." % req.elevation_provider.get_label()
			)
		else:
			result.fail(GwImportResult.ErrorCode.NO_DATA, "No elevation data in the selected area.")
		return null
	if missing + failed > 0:
		var msg := (
			"%d of %d elevation tiles were unavailable (%d missing, %d failed)."
			% [missing + failed, tiles.size(), missing, failed]
		)
		result.warnings.append(msg + " Gaps were filled.")

	# 2. Decode on workers.
	var keys: Array = tile_data.keys()
	var decoder := req.elevation_provider.create_decoder()
	var decoded := await _run_parallel(
		"decode",
		keys.size(),
		func(i: int) -> Variant: return decoder.decode_bytes(tile_data[keys[i]])
	)
	if token.is_cancelled():
		return null
	var by_tile := {}
	for i in keys.size():
		var heights: Variant = decoded[i]
		if heights is PackedFloat32Array and not (heights as PackedFloat32Array).is_empty():
			by_tile[Vector2i(keys[i].x, keys[i].y)] = heights
		else:
			result.warnings.append("Elevation tile %s could not be decoded." % str(keys[i]))

	# 3. Heightfield: stitch, fill NoData, decimate.
	var raw_cell := plan.cell_size_m / plan.decimation
	var step := plan.decimation
	var hf_results := await _run_parallel(
		"heightfield",
		1,
		func(_i: int) -> Variant:
			var hf := GwHeightfieldAssembler.assemble(
				plan.elevation_tiles, by_tile, raw_cell, plan.grid_origin
			)
			var nodata := hf.count_nodata()
			var fallback := hf.fill_nodata()
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
			msg += " %d far from valid data were set to the minimum height." % hf_info["fallback"]
		result.warnings.append(msg)
	logger.info(
		(
			"Heightfield %dx%d, cell %.2f m, %.1f..%.1f m"
			% [hf.width, hf.height, hf.cell_size, hf.min_height, hf.max_height]
		)
	)

	# 4. Chunk meshes and collision heights.
	var grid := GwTerrainChunkBuilder.chunk_grid(hf, req.chunk_size)
	for cz in grid.y:
		for cx in grid.x:
			data.cells.append(GwTerrainChunkBuilder.chunk_cells(hf, req.chunk_size, cx, cz))
			data.names.append("chunk_%03d_%03d" % [cx, cz])
	var cells := data.cells
	var colors := req.imagery_provider == null
	var collision := req.generate_collision
	var built := await _run_parallel(
		"meshes",
		cells.size(),
		func(i: int) -> Variant:
			return [
				GwTerrainChunkBuilder.build_arrays(hf, cells[i], colors),
				(
					GwTerrainChunkBuilder.build_collision_heights(hf, cells[i])
					if collision
					else PackedFloat32Array()
				),
			]
	)
	if token.is_cancelled():
		return null
	var tree := _tree()
	for i in cells.size():
		data.meshes.append(GwTerrainChunkBuilder.create_mesh(built[i][0]))
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

	# 5. Imagery.
	if req.imagery_provider != null:
		var img_tiles := plan.imagery_tile_list()
		_emit("imagery_tiles", 0, img_tiles.size())
		var img_fetched: Dictionary = await fetcher.fetch_tiles(
			req.imagery_provider, img_tiles, token, _on_fetch_progress.bind("imagery_tiles")
		)
		if img_fetched["cancelled"] or token.is_cancelled():
			return null
		var bytes_by_tile := {}
		for t: Vector3i in img_fetched["data"]:
			bytes_by_tile[Vector2i(t.x, t.y)] = img_fetched["data"][t]
		var img_missing: int = img_fetched["missing"].size() + img_fetched["failed"].size()
		if bytes_by_tile.is_empty():
			result.warnings.append(
				(
					"No imagery available from %s; the terrain is untextured."
					% req.imagery_provider.get_label()
				)
			)
		elif img_missing > 0:
			result.warnings.append(
				"%d of %d imagery tiles were unavailable." % [img_missing, img_tiles.size()]
			)
		var compositor := plan.create_compositor()
		var composed := await _run_parallel(
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

	data.georef = plan.create_geo_reference()
	data.georef.heightfield = hf
	result.stats = {
		"elevation_zoom": plan.elevation_zoom,
		"elevation_tiles": tiles.size(),
		"imagery_zoom": plan.imagery_zoom,
		"imagery_tiles": plan.imagery_tiles.get_area() if req.imagery_provider else 0,
		"grid": Vector2i(hf.width, hf.height),
		"cell_size_m": hf.cell_size,
		"chunks": cells.size(),
		"triangles": 2 * (hf.width - 1) * (hf.height - 1),
	}
	return data


func _save(plan: GwImportPlan, data: BuildData, result: GwImportResult) -> void:
	var req := plan.request
	var folder := req.get_output_folder()
	var terrain_dir := folder.path_join("terrain")
	var total := data.meshes.size() * 2 + 4
	var done := 0
	_emit("save", done, total)
	DirAccess.make_dir_recursive_absolute(terrain_dir)
	_remove_old_chunks(terrain_dir)

	data.georef.attribution = data.attribution.to_text()
	if not _save_resource(data.heightfield, folder.path_join("heightfield.res"), result):
		return
	if not _save_resource(data.georef, folder.path_join("georef.tres"), result):
		return
	if not _save_resource(req.duplicate(), folder.path_join("import_request.tres"), result, false):
		return
	var md := FileAccess.open(folder.path_join("ATTRIBUTION.md"), FileAccess.WRITE)
	if md:
		md.store_string(data.attribution.to_markdown(req.import_name, req.bbox))
		md.close()
		result.files.append(folder.path_join("ATTRIBUTION.md"))
	done += 4
	_emit("save", done, total)

	var tree := _tree()
	for i in data.meshes.size():
		var base := terrain_dir.path_join(data.names[i])
		if not _save_resource(data.meshes[i], base + ".mesh", result):
			return
		if data.shapes[i] != null:
			if not _save_resource(data.shapes[i], base + "_collision.res", result):
				return
		done += 1
		if i % MAIN_THREAD_BATCH == MAIN_THREAD_BATCH - 1:
			_emit("save", done, total)
			await tree.process_frame

	var textures: Array[Texture2D] = []
	if not data.images.is_empty():
		textures = await _save_textures(terrain_dir, data, result)
		if textures.is_empty():
			return

	_emit("scene", 0, 1)
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
	if not _save_resource(packed, scene_path, result):
		return
	_emit("scene", 1, 1)
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
		var pngs := PackedStringArray()
		for i in data.images.size():
			var path := terrain_dir.path_join(data.names[i] + ".png")
			if data.images[i].save_png(path) != OK:
				result.fail(GwImportResult.ErrorCode.SAVE_FAILED, "Could not write %s." % path)
				return []
			pngs.append(path)
			if i % MAIN_THREAD_BATCH == MAIN_THREAD_BATCH - 1:
				_emit("save", i, data.images.size())
				await tree.process_frame
		_emit("import", 0, 1)
		await importer.call(pngs)
		_emit("import", 1, 1)
		for i in pngs.size():
			var tex := ResourceLoader.load(pngs[i], "Texture2D", ResourceLoader.CACHE_MODE_REPLACE)
			if tex is Texture2D:
				textures[i] = tex
				result.files.append(pngs[i])
			else:
				logger.warn("Texture %s was not imported; saving it as .res instead." % pngs[i])
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
		if not _save_resource(tex, terrain_dir.path_join(data.names[i] + ".res"), result):
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

	for i in data.meshes.size():
		var cells := data.cells[i]
		var mi := MeshInstance3D.new()
		mi.name = data.names[i].capitalize().replace(" ", "_")
		mi.mesh = data.meshes[i]
		if textures.is_empty():
			mi.set_surface_override_material(0, plain_material)
		else:
			mi.set_surface_override_material(
				0, _imagery_material(textures[i], data.uv_scales[i], data.uv_offsets[i])
			)
		terrain.add_child(mi)
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

	if req.add_attribution_label and not data.attribution.is_empty():
		root.add_child(_attribution_overlay(data.attribution.to_short_text()))
	_set_owner_recursive(root, root)
	return root


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
## processing frames. Returns the results in order (null where skipped).
func _run_parallel(stage: String, count: int, fn: Callable) -> Array:
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
		_emit(stage, done, count)
		await tree.process_frame
	WorkerThreadPool.wait_for_group_task_completion(id)
	_emit(stage, count, count)
	logger.debug("%s: %d items in %d ms" % [stage, count, Time.get_ticks_msec() - started])
	return results


func _save_resource(
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


## Removes chunk files of a previous import so a smaller re-import leaves no strays.
static func _remove_old_chunks(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.begins_with("chunk_"):
			dir.remove(f)


static func _set_owner_recursive(node: Node, owner: Node) -> void:
	for child in node.get_children():
		child.owner = owner
		_set_owner_recursive(child, owner)


func _on_fetch_progress(done: int, total: int, stage: String) -> void:
	_emit(stage, done, total)


func _emit(stage: String, done: int, total: int) -> void:
	progress.emit(stage, done, total)


func _finish(result: GwImportResult, started_msec: int) -> GwImportResult:
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
