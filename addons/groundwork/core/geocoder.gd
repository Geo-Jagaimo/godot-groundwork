@tool
class_name GwGeocoder
extends RefCounted
## Turns a search string into a location.
##
## Accepts "lat, lon", "z/x/y" tile coordinates, or a place name looked up with
## Nominatim. Nominatim usage policy: at most one request per second, only on
## explicit user action (no autocomplete), a distinct User-Agent, results cached,
## and "© OpenStreetMap contributors" shown.

const NOMINATIM_URL := "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q="
const ATTRIBUTION := "Search: Nominatim, © OpenStreetMap contributors"
const MIN_INTERVAL_MSEC := 1100

static var _last_request_msec := -100000
static var _cache := {}

var user_agent := GwTileFetcher.DEFAULT_USER_AGENT
var _host: Node


func _init(host: Node = null) -> void:
	_host = host


## Parses coordinates without any network access. Returns
## {"lat", "lon", "zoom"} or an empty Dictionary.
static func parse_coordinates(text: String) -> Dictionary:
	var s := text.strip_edges()
	var tile := RegEx.create_from_string("^(\\d{1,2})\\s*/\\s*(\\d+)\\s*/\\s*(\\d+)$").search(s)
	if tile:
		var z := tile.get_string(1).to_int()
		var x := tile.get_string(2).to_int()
		var y := tile.get_string(3).to_int()
		if z > 24 or x >= (1 << z) or y >= (1 << z):
			return {}
		return {
			"lat": GwTileMath.tile_y_to_lat(y + 0.5, z),
			"lon": GwTileMath.tile_x_to_lon(x + 0.5, z),
			"zoom": float(z),
		}
	var num := "([-+]?\\d+(?:\\.\\d+)?)"
	var point := RegEx.create_from_string("^" + num + "\\s*[, ]\\s*" + num + "$").search(s)
	if point:
		var lat := point.get_string(1).to_float()
		var lon := point.get_string(2).to_float()
		if absf(lat) > 90.0 or absf(lon) > 180.0:
			return {}
		return {"lat": lat, "lon": lon, "zoom": 15.0}
	return {}


## Resolves [param text]. Returns {"lat", "lon", "zoom", "name"} and, for
## place names, "bbox" (GwGeoBBox); an empty Dictionary when nothing was found.
func search(text: String) -> Dictionary:
	var parsed := parse_coordinates(text)
	if not parsed.is_empty():
		return parsed
	var q := text.strip_edges()
	if q.is_empty():
		return {}
	if _cache.has(q):
		return _cache[q]
	var tree := Engine.get_main_loop() as SceneTree
	# Reserve the next free slot before waiting, so overlapping searches queue
	# up one second apart instead of firing together.
	var now := Time.get_ticks_msec()
	var slot := maxi(now, _last_request_msec + MIN_INTERVAL_MSEC)
	_last_request_msec = slot
	if slot > now:
		await tree.create_timer((slot - now) / 1000.0).timeout
		if _cache.has(q):
			return _cache[q]

	var req := HTTPRequest.new()
	req.timeout = 15.0
	(_host if is_instance_valid(_host) else tree.root).add_child(req)
	var err := req.request(
		NOMINATIM_URL + q.uri_encode(), PackedStringArray(["User-Agent: " + user_agent])
	)
	if err != OK:
		req.queue_free()
		return {}
	var response: Array = await req.request_completed
	req.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		return {}
	var json: Variant = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	var out := {}
	if json is Array and not (json as Array).is_empty():
		var hit: Dictionary = json[0]
		out = {
			"lat": str(hit.get("lat", "0")).to_float(),
			"lon": str(hit.get("lon", "0")).to_float(),
			"zoom": 14.0,
			"name": str(hit.get("display_name", "")),
		}
		var bb: Variant = hit.get("boundingbox")
		if bb is Array and (bb as Array).size() == 4:
			# Nominatim order: [south, north, west, east].
			out["bbox"] = GwGeoBBox.from_sw_ne(
				str(bb[0]).to_float(),
				str(bb[2]).to_float(),
				str(bb[1]).to_float(),
				str(bb[3]).to_float()
			)
	_cache[q] = out
	return out
