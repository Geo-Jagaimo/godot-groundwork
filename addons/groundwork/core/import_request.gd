@tool
class_name GwImportRequest
extends Resource
## All parameters of one import. Saved next to the output as
## [code]import_request.tres[/code] so the same area can be imported again.

@export var import_name := "terrain"
@export_dir var output_dir := "res://geo/"
@export var bbox: GwGeoBBox

@export_group("Elevation")
@export var elevation_provider: GwTileProvider
## Desired heightfield spacing; the closest available zoom level is used.
@export_range(0.5, 500.0, 0.5, "suffix:m") var target_resolution_m := 10.0
## Use every Nth sample (1, 2 or 4) to lighten meshes, e.g. for mobile.
@export_range(1, 4) var mesh_decimation := 1
@export_range(16, 512) var chunk_size := 128

@export_group("Imagery")
## Optional. Without imagery the terrain gets an elevation colour gradient.
@export var imagery_provider: GwTileProvider
## Imagery zoom = elevation zoom + offset (clamped to the provider's range).
@export_range(0, 4) var imagery_zoom_offset := 2

@export_group("Output")
@export var generate_collision := true
@export var add_attribution_label := true
@export var overwrite := false

@export_group("OSM (v0.2)")
@export var include_buildings := false
@export var include_roads := false


func get_output_folder() -> String:
	return output_dir.path_join(import_name)


func get_scene_path() -> String:
	return get_output_folder().path_join(import_name + ".tscn")
