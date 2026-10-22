@tool
class_name GwTileCache
extends RefCounted
## Disk cache for raw tile bytes:
## [code]user://groundwork_cache/<provider_id>/<z>/<x>/<y>.<ext>[/code]
##
## Tiles that returned 404 are remembered as empty [code].missing[/code] files
## so that, for example, sea areas of regional providers are not re-requested.

enum Status { MISS, HIT, KNOWN_MISSING }

const DEFAULT_ROOT := "user://groundwork_cache"

var root_dir := DEFAULT_ROOT


func _init(p_root_dir: String = DEFAULT_ROOT) -> void:
	root_dir = p_root_dir


## Returns {"status": Status, "data": PackedByteArray}.
func lookup(provider: GwTileProvider, tile: Vector3i) -> Dictionary:
	if not provider.cacheable:
		return {"status": Status.MISS, "data": PackedByteArray()}
	var path := tile_path(provider, tile)
	if _is_fresh(path, provider):
		return {"status": Status.HIT, "data": FileAccess.get_file_as_bytes(path)}
	var missing_path := path.get_basename() + ".missing"
	if _is_fresh(missing_path, provider):
		return {"status": Status.KNOWN_MISSING, "data": PackedByteArray()}
	return {"status": Status.MISS, "data": PackedByteArray()}


func store(provider: GwTileProvider, tile: Vector3i, data: PackedByteArray) -> void:
	if not provider.cacheable or data.is_empty():
		return
	_write(tile_path(provider, tile), data)


func store_missing(provider: GwTileProvider, tile: Vector3i) -> void:
	if not provider.cacheable:
		return
	_write(tile_path(provider, tile).get_basename() + ".missing", PackedByteArray())


func tile_path(provider: GwTileProvider, tile: Vector3i) -> String:
	return root_dir.path_join(
		(
			"%s/%d/%d/%d.%s"
			% [_safe_id(provider.id), tile.z, tile.x, tile.y, provider.tile_extension()]
		)
	)


## Path for non-tile cached responses (e.g. JSON) keyed by a string.
func blob_path(namespace_id: String, key: String, ext: String) -> String:
	return root_dir.path_join("%s/%s.%s" % [_safe_id(namespace_id), key.sha256_text(), ext])


func get_size_bytes() -> int:
	return _dir_size(root_dir)


func clear() -> void:
	_remove_recursive(root_dir)


func _is_fresh(path: String, provider: GwTileProvider) -> bool:
	if not FileAccess.file_exists(path):
		return false
	if provider.cache_ttl_days <= 0:
		return true
	var age := Time.get_unix_time_from_system() - FileAccess.get_modified_time(path)
	return age < provider.cache_ttl_days * 86400.0


func _write(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(data)
	f.close()


static func _safe_id(id: String) -> String:
	var s := id.strip_edges().validate_filename().replace(" ", "_")
	return s if not s.is_empty() else "unnamed"


static func _dir_size(path: String) -> int:
	var total := 0
	var dir := DirAccess.open(path)
	if dir == null:
		return 0
	for f in dir.get_files():
		var file := FileAccess.open(path.path_join(f), FileAccess.READ)
		if file:
			total += file.get_length()
	for d in dir.get_directories():
		total += _dir_size(path.path_join(d))
	return total


static func _remove_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		_remove_recursive(path.path_join(d))
	DirAccess.remove_absolute(path)
