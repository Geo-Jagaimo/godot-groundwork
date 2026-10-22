@tool
class_name GwGeoBBox
extends Resource
## Geographic bounding box in degrees (WGS84 latitude / longitude).
##
## A Resource (not RefCounted) so that [GwImportRequest] can be saved as a .tres.

@export var south := 0.0
@export var west := 0.0
@export var north := 0.0
@export var east := 0.0

## What is actually saved: "south,west,north,east" at full precision. Godot 4.4
## writes floats in text resources with only 6 significant digits (~50 m here).
@export_storage var bounds_text := "":
	get:
		return format_degrees([south, west, north, east])
	set(value):
		var v := parse_degrees(value, 4)
		if not v.is_empty():
			south = v[0]
			west = v[1]
			north = v[2]
			east = v[3]


static func from_sw_ne(p_south: float, p_west: float, p_north: float, p_east: float) -> GwGeoBBox:
	var b := GwGeoBBox.new()
	b.south = minf(p_south, p_north)
	b.north = maxf(p_south, p_north)
	b.west = minf(p_west, p_east)
	b.east = maxf(p_west, p_east)
	return b


## From Vector4(south, west, north, east).
static func from_vector4(v: Vector4) -> GwGeoBBox:
	return from_sw_ne(v.x, v.y, v.z, v.w)


## A box of roughly [param width_m] x [param height_m] metres around a point.
static func from_center_size(lat: float, lon: float, width_m: float, height_m: float) -> GwGeoBBox:
	var k := cos(deg_to_rad(lat))
	var cx := GwTileMath.mercator_x(lon)
	var cy := GwTileMath.mercator_y(lat)
	var hw := width_m / 2.0 / k
	var hh := height_m / 2.0 / k
	return from_sw_ne(
		GwTileMath.lat_from_mercator_y(cy - hh),
		GwTileMath.lon_from_mercator_x(cx - hw),
		GwTileMath.lat_from_mercator_y(cy + hh),
		GwTileMath.lon_from_mercator_x(cx + hw),
	)


## "a,b,c" with 10 decimals (~0.01 mm).
static func format_degrees(values: Array) -> String:
	var parts := PackedStringArray()
	for v: float in values:
		parts.append("%.10f" % v)
	return ",".join(parts)


## Parses [method format_degrees] output; empty when malformed.
static func parse_degrees(text: String, count: int) -> PackedFloat64Array:
	var parts := text.split(",")
	if parts.size() != count:
		return PackedFloat64Array()
	var out := PackedFloat64Array()
	for p in parts:
		if not p.strip_edges().is_valid_float():
			return PackedFloat64Array()
		out.append(p.to_float())
	return out


func to_vector4() -> Vector4:
	return Vector4(south, west, north, east)


func is_valid() -> bool:
	return (
		north > south
		and east > west
		and south >= -GwTileMath.MAX_LATITUDE
		and north <= GwTileMath.MAX_LATITUDE
		and west >= -180.0
		and east <= 180.0
	)


func center_lat() -> float:
	return (south + north) / 2.0


func center_lon() -> float:
	return (west + east) / 2.0


## Approximate east-west extent in metres (mercator scaled at the centre latitude).
func width_m() -> float:
	var k := cos(deg_to_rad(center_lat()))
	return (GwTileMath.mercator_x(east) - GwTileMath.mercator_x(west)) * k


## Approximate north-south extent in metres.
func height_m() -> float:
	var k := cos(deg_to_rad(center_lat()))
	return (GwTileMath.mercator_y(north) - GwTileMath.mercator_y(south)) * k


func area_km2() -> float:
	return width_m() * height_m() / 1.0e6


func intersects(other: GwGeoBBox) -> bool:
	return south < other.north and north > other.south and west < other.east and east > other.west


func contains_bbox(other: GwGeoBBox) -> bool:
	return (
		other.south >= south and other.north <= north and other.west >= west and other.east <= east
	)


func contains_point(lat: float, lon: float) -> bool:
	return lat >= south and lat <= north and lon >= west and lon <= east


func _validate_property(property: Dictionary) -> void:
	if property.name in ["south", "west", "north", "east"]:
		property.usage &= ~PROPERTY_USAGE_STORAGE


func _to_string() -> String:
	return "%.5f,%.5f - %.5f,%.5f" % [south, west, north, east]
