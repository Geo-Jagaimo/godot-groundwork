@tool
class_name GwTileMath
extends RefCounted
## Web Mercator (EPSG:3857) and slippy-map tile math.
##
## All geographic and mercator values are GDScript floats (64-bit). Do not put
## them in Vector2/Vector3, which are 32-bit and lose metre-level precision.

const EARTH_RADIUS := 6378137.0
const TILE_SIZE := 256
## Latitude limit of the square Web Mercator world.
const MAX_LATITUDE := 85.0511287798066
## Ground resolution at the equator for zoom 0 [m/px] (2 * PI * R / 256).
const EQUATOR_RESOLUTION := 156543.03392804097


static func mercator_x(lon: float) -> float:
	return EARTH_RADIUS * deg_to_rad(lon)


static func mercator_y(lat: float) -> float:
	var phi := deg_to_rad(clampf(lat, -MAX_LATITUDE, MAX_LATITUDE))
	return EARTH_RADIUS * log(tan(PI / 4.0 + phi / 2.0))


static func lon_from_mercator_x(x: float) -> float:
	return rad_to_deg(x / EARTH_RADIUS)


static func lat_from_mercator_y(y: float) -> float:
	return rad_to_deg(2.0 * atan(exp(y / EARTH_RADIUS)) - PI / 2.0)


## Fractional tile X at zoom [param z].
static func lon_to_tile_x(lon: float, z: int) -> float:
	return (lon + 180.0) / 360.0 * float(1 << z)


## Fractional tile Y at zoom [param z].
static func lat_to_tile_y(lat: float, z: int) -> float:
	var phi := deg_to_rad(clampf(lat, -MAX_LATITUDE, MAX_LATITUDE))
	return (1.0 - log(tan(phi) + 1.0 / cos(phi)) / PI) / 2.0 * float(1 << z)


static func tile_x_to_lon(x: float, z: int) -> float:
	return x / float(1 << z) * 360.0 - 180.0


static func tile_y_to_lat(y: float, z: int) -> float:
	return rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * y / float(1 << z)))))


## Integer tile containing the point. Returns (x, y).
static func lat_lon_to_tile(lat: float, lon: float, z: int) -> Vector2i:
	var n := 1 << z
	var x := clampi(floori(lon_to_tile_x(lon, z)), 0, n - 1)
	var y := clampi(floori(lat_to_tile_y(lat, z)), 0, n - 1)
	return Vector2i(x, y)


## Geographic bounds of a tile as (south, west, north, east).
static func tile_bounds(x: int, y: int, z: int) -> Vector4:
	return Vector4(
		tile_y_to_lat(y + 1, z), tile_x_to_lon(x, z), tile_y_to_lat(y, z), tile_x_to_lon(x + 1, z)
	)


## Ground resolution [m/px] at [param lat] for tiles of [param tile_size] px.
static func ground_resolution(lat: float, z: int, tile_size: int = TILE_SIZE) -> float:
	return EQUATOR_RESOLUTION * cos(deg_to_rad(lat)) / float(1 << z) * TILE_SIZE / tile_size


## Size of one tile pixel at zoom [param z] in mercator metres (not scaled by latitude).
static func mercator_pixel_size(z: int, tile_size: int = TILE_SIZE) -> float:
	return EQUATOR_RESOLUTION / float(1 << z) * TILE_SIZE / tile_size


## Zoom whose ground resolution at [param lat] is closest to [param target_m]
## (compared on a log scale), clamped to [min_zoom, max_zoom].
static func resolution_to_zoom(
	target_m: float, lat: float, min_zoom: int = 0, max_zoom: int = 22, tile_size: int = TILE_SIZE
) -> int:
	if target_m <= 0.0:
		return max_zoom
	var best := min_zoom
	var best_score := INF
	for z in range(min_zoom, max_zoom + 1):
		var score := absf(log(ground_resolution(lat, z, tile_size) / target_m))
		if score < best_score:
			best_score = score
			best = z
	return best


## Tiles covering the bbox at zoom [param z], as Rect2i(x_min, y_min, cols, rows).
static func tile_range(bbox: GwGeoBBox, z: int) -> Rect2i:
	var n := 1 << z
	# Edges within 1e-6 tile of a boundary are snapped to it, whichever side the
	# floating-point error put them on: the west / north edge then starts at that
	# tile and the east / south edge (exclusive) stops before it.
	var x0 := clampi(floori(lon_to_tile_x(bbox.west, z) + 1e-6), 0, n - 1)
	var y0 := clampi(floori(lat_to_tile_y(bbox.north, z) + 1e-6), 0, n - 1)
	var x1 := clampi(ceili(lon_to_tile_x(bbox.east, z) - 1e-6) - 1, x0, n - 1)
	var y1 := clampi(ceili(lat_to_tile_y(bbox.south, z) - 1e-6) - 1, y0, n - 1)
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)


## All tiles of a range as Vector3i(x, y, z), row by row.
static func tiles_in_range(rect: Rect2i, z: int) -> Array[Vector3i]:
	var tiles: Array[Vector3i] = []
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			tiles.append(Vector3i(x, y, z))
	return tiles
