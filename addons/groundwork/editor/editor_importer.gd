@tool
extends RefCounted
## Makes the editor import the PNG textures written by GwWorldBuilder.
## plugin.gd registers [method import_files] as
## [member GwWorldBuilder.default_file_importer].
##
## Uses an incremental source scan rather than update_file() + reimport_files():
## in Godot 4.4 update_file() cannot register files in folders the editor has
## not scanned yet, which is always the case for a new import.

## Import settings for new chunk textures: VRAM compressed with mipmaps.
const TEXTURE_IMPORT := """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
mipmaps/generate=true
detect_3d/compress_to=0
"""
const TEXTURE_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp"]
const TIMEOUT_MSEC := 120000


func import_files(paths: PackedStringArray) -> void:
	var efs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	for path in paths:
		# Keep existing settings when re-importing over a previous import.
		if (
			path.get_extension().to_lower() in TEXTURE_EXTENSIONS
			and not FileAccess.file_exists(path + ".import")
		):
			var f := FileAccess.open(path + ".import", FileAccess.WRITE)
			if f:
				f.store_string(TEXTURE_IMPORT)
				f.close()
	await _wait_idle(efs, tree)
	# sources_changed is emitted after the scan has imported new or changed files.
	var state := {"done": false}
	var on_done := func(_exist: bool) -> void: state["done"] = true
	efs.sources_changed.connect(on_done, CONNECT_ONE_SHOT)
	efs.scan_sources()
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while not state["done"] and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	if efs.sources_changed.is_connected(on_done):
		efs.sources_changed.disconnect(on_done)
	await _wait_idle(efs, tree)


static func _wait_idle(efs: EditorFileSystem, tree: SceneTree) -> void:
	await tree.process_frame
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while efs.is_scanning() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
