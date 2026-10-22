@tool
class_name GwTerrainLoader
extends Node3D
## Builds a real-world scene while the game runs, without writing any files:
## set [member request] (or use [method request_around]) and call [method build].
## The result becomes a child GwSceneRoot ([member scene_root]).
##
## Tiles are cached in user://groundwork_cache/, so places load faster the
## second time. Remember to show the data attribution
## ([method GwSceneRoot.get_attribution]) in your game.

signal progress(stage: String, done: int, total: int)
signal finished(result: GwImportResult)

## What to build. Output fields (name, folder, overwrite) are ignored.
@export var request: GwImportRequest
## Build as soon as the node is ready (only in the running game, not the editor).
@export var build_on_ready := false

## The last scene built, or null.
var scene_root: GwSceneRoot

var _builder: GwWorldBuilder


## A request for a [param size_m] x [param size_m] area around a point, using
## provider presets by id (see GwProviderRegistry); [param imagery_id] may be "".
static func request_around(
	lat: float,
	lon: float,
	size_m: float,
	elevation_id: String = "terrarium_aws",
	imagery_id: String = ""
) -> GwImportRequest:
	var req := GwImportRequest.new()
	req.import_name = "runtime"
	req.bbox = GwGeoBBox.from_center_size(lat, lon, size_m, size_m)
	req.elevation_provider = GwProviderRegistry.find(elevation_id)
	if not imagery_id.is_empty():
		req.imagery_provider = GwProviderRegistry.find(imagery_id)
	return req


func _ready() -> void:
	if build_on_ready and request != null and not Engine.is_editor_hint():
		build()


## Builds [member request], replacing the previous scene when it succeeds.
## Await it, or listen to [signal finished].
func build() -> GwImportResult:
	cancel()
	var builder := GwWorldBuilder.new()
	builder.host_node = self
	builder.progress.connect(func(s: String, d: int, t: int) -> void: progress.emit(s, d, t))
	_builder = builder
	var result := GwImportResult.new()
	var root := await builder.build_nodes(request, result)
	if _builder != builder:
		# Cancelled or replaced by a newer build meanwhile.
		if root != null:
			root.free()
		if result.error_code == GwImportResult.ErrorCode.NONE:
			result.fail(GwImportResult.ErrorCode.CANCELLED, "Build cancelled.")
		finished.emit(result)
		return result
	_builder = null
	if root != null:
		clear()
		scene_root = root
		add_child(root)
	finished.emit(result)
	return result


func is_building() -> bool:
	return _builder != null


## Stops a running build; the current scene stays.
func cancel() -> void:
	if _builder != null:
		_builder.cancel()
		_builder = null


## Removes the built scene.
func clear() -> void:
	if is_instance_valid(scene_root):
		scene_root.queue_free()
	scene_root = null


func _exit_tree() -> void:
	cancel()
