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
## Coarser meshes per chunk, shown with distance (0 = off). Each level halves the
## detail of the one before.
@export_range(0, 3) var lod_levels := 2
## Distance, in chunk widths, at which the first coarser level takes over; each
## further level starts twice as far.
@export_range(0.5, 10.0, 0.1) var lod_distance := 1.5

@export_group("Imagery")
## Optional. Without imagery the terrain gets an elevation colour gradient.
@export var imagery_provider: GwTileProvider
## Imagery zoom = elevation zoom + offset (clamped to the provider's range).
@export_range(0, 4) var imagery_zoom_offset := 2

@export_group("Output")
@export var generate_collision := true
@export var add_attribution_label := true
@export var overwrite := false

@export_group("OpenStreetMap")
## Extruded buildings with collision.
@export var include_buildings := false
## Road ribbons draped over the terrain (no collision of their own).
@export var include_roads := false
## Lakes, ponds and river areas, plus rivers and canals as lines (no collision).
@export var include_water := false
## Overpass endpoint (a VECTOR provider). Null uses the first preset.
@export var osm_provider: GwTileProvider
## Try the other Overpass presets when the endpoint fails.
@export var osm_use_fallbacks := true
## Used when a building has neither height nor building:levels.
@export_range(1.0, 200.0, 0.5, "suffix:m") var building_default_height_m := 6.0
@export_range(1.0, 10.0, 0.1, "suffix:m") var building_level_height_m := 3.0
## highway=* value -> width in metres, overriding GwRoadBuilder.DEFAULT_WIDTHS.
@export var road_widths := {}


func get_output_folder() -> String:
	return output_dir.path_join(import_name)


func includes_osm() -> bool:
	return include_buildings or include_roads or include_water


func get_scene_path() -> String:
	return get_output_folder().path_join(import_name + ".tscn")
