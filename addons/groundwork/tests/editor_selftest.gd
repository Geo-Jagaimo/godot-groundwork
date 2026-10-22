@tool
extends Node
## Editor integration self-test (network required). Drives the Geo dock through
## an import that goes through the editor's texture import pipeline.
##
## godot --headless --editor --path . -- --groundwork-selftest [--screenshot=<png path>]

## Set by plugin.gd.
var dock: Node

var _failures := PackedStringArray()


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var tree := get_tree()
	var efs := EditorInterface.get_resource_filesystem()
	for i in 10:
		await tree.process_frame
	while efs.is_scanning():
		await tree.process_frame

	_check(dock != null, "dock exists")
	_check(dock.get("_basemaps").size() >= 2, "basemaps listed")
	_check(dock.panel.all_providers().size() >= 4, "providers listed")

	var bbox := GwGeoBBox.from_center_size(35.3606, 138.7274, 1500, 1500)
	dock.map.set_selection(bbox)
	dock._on_selection_changed(bbox)
	var preset := GwImportRequest.new()
	preset.import_name = "selftest"
	preset.output_dir = "res://geo/"
	preset.bbox = bbox
	preset.elevation_provider = GwProviderRegistry.find("gsi_dem10b")
	preset.imagery_provider = GwProviderRegistry.find("gsi_seamlessphoto")
	preset.imagery_zoom_offset = 1
	dock.panel.apply_request(preset)
	var req: GwImportRequest = dock.panel.build_request()
	_check(req.elevation_provider.id == "gsi_dem10b", "panel keeps elevation provider")
	_check(req.imagery_provider.id == "gsi_seamlessphoto", "panel keeps imagery provider")
	var plan := GwImportPlan.from_request(req)
	print("[selftest] plan: ", plan.describe(), " errors=", plan.errors)
	_check(plan.is_valid(), "plan valid")

	req.overwrite = true
	await dock._start_import(req)
	var result: GwImportResult = dock.get("_last_result")
	_check(
		result != null and result.ok, "import ok: %s" % (result.error_message if result else "null")
	)
	if result != null and result.ok:
		print("[selftest] ", result.scene_path, " ", result.stats)
		for w in result.warnings:
			print("[selftest] warning: ", w)
		var tex := ResourceLoader.load("res://geo/selftest/terrain/chunk_000_000.png")
		_check(tex is CompressedTexture2D, "PNG imported as CompressedTexture2D (%s)" % tex)
		var cfg := ConfigFile.new()
		cfg.load("res://geo/selftest/terrain/chunk_000_000.png.import")
		_check(cfg.get_value("params", "compress/mode", -1) == 2, "VRAM compression")
		_check(cfg.get_value("params", "mipmaps/generate", false) == true, "mipmaps")
		var scene: Node = (ResourceLoader.load(result.scene_path) as PackedScene).instantiate()
		_check(scene is GwSceneRoot, "scene root is GwSceneRoot")
		var chunk := scene.get_node_or_null("Terrain/Chunk_000_000") as MeshInstance3D
		_check(chunk != null and chunk.mesh != null, "chunk mesh")
		if chunk:
			var mat := chunk.get_surface_override_material(0) as StandardMaterial3D
			_check(
				mat != null and mat.albedo_texture is CompressedTexture2D,
				"material uses imported texture"
			)
			_check(chunk.get_node_or_null("StaticBody3D/CollisionShape3D") != null, "collision")
		_check(scene.get_node_or_null("Attribution/Label") != null, "attribution label")
		scene.free()

	var shot := _arg("--screenshot=")
	if not shot.is_empty():
		var tabs := dock.get_parent() as TabContainer
		if tabs:
			tabs.current_tab = dock.get_index()
		dock.map.fit_bbox(bbox)
		dock.panel.show_result(result)
		for i in 30:
			await tree.process_frame
		await RenderingServer.frame_post_draw
		tree.root.get_texture().get_image().save_png(shot)
		print("[selftest] screenshot: ", shot)

	if _failures.is_empty():
		print("[selftest] PASSED")
	else:
		for f in _failures:
			printerr("[selftest] FAILED: ", f)
	tree.quit(0 if _failures.is_empty() else 1)


static func _arg(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.trim_prefix(prefix)
	return ""


func _check(cond: bool, what: String) -> void:
	if cond:
		print("[selftest] ok   ", what)
	else:
		_failures.append(what)
