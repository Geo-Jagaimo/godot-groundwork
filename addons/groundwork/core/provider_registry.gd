@tool
class_name GwProviderRegistry
extends RefCounted
## Finds provider resources: built-in presets plus the project's own.

const BUILTIN_DIR := "res://addons/groundwork/providers"
const USER_DIR := "res://groundwork_providers"


## Providers of [param kind] ([enum GwTileProvider.Kind]), or all when -1.
## Project providers come after the presets; a project provider with the same
## id replaces the preset.
static func list_providers(kind: int = -1) -> Array[GwTileProvider]:
	var by_id := {}
	var order: Array[String] = []
	for dir in [BUILTIN_DIR, USER_DIR]:
		for p in _load_dir(dir):
			if kind >= 0 and p.kind != kind:
				continue
			if not by_id.has(p.id):
				order.append(p.id)
			by_id[p.id] = p
	var out: Array[GwTileProvider] = []
	for id in order:
		out.append(by_id[id])
	return out


static func find(id: String) -> GwTileProvider:
	for p in list_providers():
		if p.id == id:
			return p
	return null


static func _load_dir(dir: String) -> Array[GwTileProvider]:
	var out: Array[GwTileProvider] = []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for f in files:
		# Exported projects list text resources as *.tres.remap.
		var file := f.trim_suffix(".remap")
		if file.get_extension() not in ["tres", "res"]:
			continue
		var res := ResourceLoader.load(dir.path_join(file))
		if res is GwTileProvider and not (res as GwTileProvider).id.is_empty():
			out.append(res)
	return out
