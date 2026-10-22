@tool
class_name GwGeoReference
extends Resource
## Links scene-local coordinates to geographic coordinates.
##
## Local space is Web Mercator relative to the origin, multiplied by
## cos(origin_lat) to give approximate metres:
## [code]+X = east, +Y = up (elevation in metres), -Z = north[/code].

@export var origin_lat := 0.0:
	set(value):
		origin_lat = value
		scale_k = cos(deg_to_rad(value))
		_update_origin_cache()
@export var origin_lon := 0.0:
	set(value):
		origin_lon = value
		_update_origin_cache()
## cos(origin_lat), derived from the origin.
@export var scale_k := 1.0
## Imported area as (south, west, north, east). A 32-bit view of the bounds;
## use [method get_bbox] for full precision.
@export var bbox := Vector4.ZERO:
	get:
		return Vector4(_bounds[0], _bounds[1], _bounds[2], _bounds[3])
	set(value):
		_bounds = PackedFloat64Array([value.x, value.y, value.z, value.w])
@export var elevation_zoom := 0
## Heightfield cell spacing in approximate metres.
@export var cell_size_m := 0.0
@export_multiline var attribution := ""
## Optional. Enables [method sample_elevation].
@export var heightfield: GwHeightfield

## What is actually saved for the origin. Godot 4.4 writes floats in .tres/.tscn
## with only 6 significant digits, which would move the origin by tens of metres.
@export_storage var origin_text := "":
	get:
		return GwGeoBBox.format_degrees([origin_lat, origin_lon])
	set(value):
		var v := GwGeoBBox.parse_degrees(value, 2)
		if not v.is_empty():
			origin_lat = v[0]
			origin_lon = v[1]

## What is actually saved for [member bbox] (see [member origin_text]).
@export_storage var bbox_text := "":
	get:
		return GwGeoBBox.format_degrees(Array(_bounds))
	set(value):
		var v := GwGeoBBox.parse_degrees(value, 4)
		if not v.is_empty():
			_bounds = v

var _bounds := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _origin_mx := 0.0
var _origin_my := 0.0


static func create(lat: float, lon: float) -> GwGeoReference:
	var g := GwGeoReference.new()
	g.origin_lat = lat
	g.origin_lon = lon
	return g


## Local position of a geographic point.
func to_local(lat: float, lon: float, elevation: float = 0.0) -> Vector3:
	var x := (GwTileMath.mercator_x(lon) - _origin_mx) * scale_k
	var z := -(GwTileMath.mercator_y(lat) - _origin_my) * scale_k
	return Vector3(x, elevation, z)


## Geographic position of a local point as [lat, lon].
## Returned as 64-bit floats; a Vector2 would lose about a metre of precision.
func to_geo(local: Vector3) -> PackedFloat64Array:
	var mx := local.x / scale_k + _origin_mx
	var my := -local.z / scale_k + _origin_my
	return PackedFloat64Array(
		[GwTileMath.lat_from_mercator_y(my), GwTileMath.lon_from_mercator_x(mx)]
	)


## Terrain elevation at a local XZ position, or NAN without a heightfield.
func sample_elevation(local_xz: Vector2) -> float:
	if heightfield == null:
		return NAN
	return heightfield.sample(local_xz)


func get_bbox() -> GwGeoBBox:
	return GwGeoBBox.from_sw_ne(_bounds[0], _bounds[1], _bounds[2], _bounds[3])


func set_bbox(value: GwGeoBBox) -> void:
	_bounds = PackedFloat64Array([value.south, value.west, value.north, value.east])


func _validate_property(property: Dictionary) -> void:
	if property.name in ["origin_lat", "origin_lon", "scale_k", "bbox"]:
		property.usage &= ~PROPERTY_USAGE_STORAGE
	if property.name == "scale_k":
		property.usage |= PROPERTY_USAGE_READ_ONLY


func _update_origin_cache() -> void:
	_origin_mx = GwTileMath.mercator_x(origin_lon)
	_origin_my = GwTileMath.mercator_y(origin_lat)
