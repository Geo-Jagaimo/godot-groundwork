@tool
class_name GwTileProvider
extends Resource
## Where tiles come from and how to use them.
##
## Presets live in [code]res://addons/groundwork/providers/[/code]. Put your own
## in [code]res://groundwork_providers/[/code] and they show up in the Geo dock.
## [member url_template] may also point to local files ([code]res://[/code],
## [code]user://[/code] or an absolute path), which is how offline tests run.

enum Kind { ELEVATION, IMAGERY, VECTOR, BASEMAP }
enum Decoder { NONE, TERRARIUM, GSI_DEM }

@export var id := ""
@export var display_name := ""
@export var kind := Kind.ELEVATION
## e.g. [code]https://example.com/{z}/{x}/{y}.png[/code]. [code]{key}[/code] is
## replaced with the API key from EditorSettings [code]groundwork/api_keys/<id>[/code].
@export var url_template := ""
@export var min_zoom := 0
@export var max_zoom := 15
## Tile width in pixels (256, or 512 for "retina" tiles). Elevation tiles of
## this size are used at full resolution.
@export var tile_size := 256
@export var decoder := Decoder.NONE
@export var requires_api_key := false
## Attribution text that must be shown wherever the data is used.
@export_multiline var attribution := ""
## One-line attribution for overlays (map view, in-game label).
@export var attribution_short := ""
@export var terms_url := ""
@export var cacheable := true
@export var cache_ttl_days := 30
## Coverage as (south, west, north, east). Zero means global.
@export var coverage_bbox := Vector4.ZERO
## Average tile size, only used for download estimates.
@export var avg_tile_kb := 50.0


func tile_url(tile: Vector3i, api_key: String = "") -> String:
	var url := url_template.replace("{z}", str(tile.z)).replace("{x}", str(tile.x))
	return url.replace("{y}", str(tile.y)).replace("{key}", api_key)


func is_local() -> bool:
	return not (url_template.begins_with("http://") or url_template.begins_with("https://"))


## File extension of the tiles, used for the cache.
func tile_extension() -> String:
	var ext := url_template.get_slice("?", 0).get_extension().to_lower()
	return ext if ext in ["png", "jpg", "jpeg", "webp"] else "bin"


func has_coverage_limit() -> bool:
	return coverage_bbox != Vector4.ZERO


func get_coverage() -> GwGeoBBox:
	return GwGeoBBox.from_vector4(coverage_bbox)


func create_decoder() -> GwElevationDecoder:
	match decoder:
		Decoder.TERRARIUM:
			return GwTerrariumDecoder.new()
		Decoder.GSI_DEM:
			return GwGsiDemDecoder.new()
	return null


func get_label() -> String:
	return display_name if not display_name.is_empty() else id
