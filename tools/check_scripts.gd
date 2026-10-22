extends SceneTree
## Loads every GDScript under addons/groundwork and reports parse errors.
## godot --headless --path . -s res://tools/check_scripts.gd


func _init() -> void:
	var failed := 0
	var paths := _collect("res://addons/groundwork")
	for path in paths:
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			failed += 1
			printerr("FAILED: ", path)
	print("checked %d scripts, %d failed" % [paths.size(), failed])
	quit(1 if failed > 0 else 0)


func _collect(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "gd":
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if FileAccess.file_exists(dir.path_join(d).path_join(".gdignore")):
			continue
		out.append_array(_collect(dir.path_join(d)))
	return out
