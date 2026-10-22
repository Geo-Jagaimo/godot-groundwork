@tool
class_name GwOverpassClient
extends RefCounted
## Downloads OpenStreetMap buildings and roads from an Overpass API endpoint.
##
## One query per import, cached on disk (TTL from the endpoint preset). When an
## endpoint fails or is busy the next one is tried; if one answered "rate
## limited" (429 / 406) it waits 30 s once, as the overpass-api.de policy asks,
## and tries the round again. Endpoints with a local url_template (res://, user://)
## are read as files, which is how offline tests run.

const CACHE_NAMESPACE := "overpass"
## The overpass-api.de policy asks for a 30 s pause after 429 / 406.
const BUSY_RETRY_DELAY_SEC := 30.0
## Per endpoint; public servers that are overloaded often never answer.
const HTTP_TIMEOUT_SEC := 100.0

var user_agent := GwTileFetcher.DEFAULT_USER_AGENT
var cache := GwTileCache.new()
## Server-side time limit put into the query.
var query_timeout_sec := 60
## Bytes received so far by the running request (for progress display).
var downloaded_bytes := 0


## Overpass QL for the requested feature types inside [param bbox].
static func build_query(
	bbox: GwGeoBBox, buildings: bool, roads: bool, timeout_sec: int = 60, water: bool = false
) -> String:
	var parts := PackedStringArray()
	if buildings:
		parts.append('way["building"];relation["building"]["type"="multipolygon"];')
	if roads:
		parts.append('way["highway"];')
	if water:
		parts.append(
			(
				'way["natural"="water"];relation["natural"="water"]["type"="multipolygon"];'
				+ 'way["waterway"="riverbank"];relation["waterway"="riverbank"];'
				+ 'way["landuse"~"^(reservoir|basin)$"];'
				+ 'way["waterway"~"^(river|stream|canal|drain|ditch)$"];'
			)
		)
	return (
		"[out:json][timeout:%d][bbox:%.7f,%.7f,%.7f,%.7f];(%s);out geom;"
		% [timeout_sec, bbox.south, bbox.west, bbox.north, bbox.east, "".join(parts)]
	)


## Fetches the data. Returns {"ok": bool, "text": String (JSON), "endpoint": String,
## "from_cache": bool, "error": String}.
func fetch(
	query: String,
	endpoints: Array[GwTileProvider],
	token: GwCancellationToken = null,
	host: Node = null
) -> Dictionary:
	if endpoints.is_empty():
		return _failure("No Overpass endpoint configured.")
	var cache_path := cache.blob_path(CACHE_NAMESPACE, query, "json")
	if _is_fresh(cache_path, endpoints[0].cache_ttl_days):
		return {
			"ok": true,
			"text": FileAccess.get_file_as_string(cache_path),
			"endpoint": "cache",
			"from_cache": true,
			"error": "",
		}

	var errors := PackedStringArray()
	for round_index in 2:
		var rate_limited := false
		for ep in endpoints:
			if token != null and token.is_cancelled():
				return _failure("Cancelled.")
			var r: Dictionary = await _fetch_one(ep, query, token, host)
			if r["ok"]:
				if ep.cacheable and not ep.is_local():
					DirAccess.make_dir_recursive_absolute(cache_path.get_base_dir())
					var f := FileAccess.open(cache_path, FileAccess.WRITE)
					if f:
						f.store_string(r["text"])
				r["endpoint"] = ep.get_label()
				r["from_cache"] = false
				return r
			rate_limited = rate_limited or r.get("rate_limited", false)
			errors.append("%s: %s" % [ep.get_label(), r["error"]])
		if not rate_limited or round_index == 1:
			break
		await (Engine.get_main_loop() as SceneTree).create_timer(BUSY_RETRY_DELAY_SEC).timeout
	return _failure("; ".join(errors))


func _fetch_one(
	ep: GwTileProvider, query: String, token: GwCancellationToken, host: Node
) -> Dictionary:
	downloaded_bytes = 0
	if ep.is_local():
		if not FileAccess.file_exists(ep.url_template):
			return {"ok": false, "error": "file not found"}
		return _check_body(FileAccess.get_file_as_string(ep.url_template))

	var tree := Engine.get_main_loop() as SceneTree
	var req := HTTPRequest.new()
	req.timeout = HTTP_TIMEOUT_SEC
	req.use_threads = true
	req.accept_gzip = true
	(host if is_instance_valid(host) else tree.root).add_child(req)
	var headers := PackedStringArray(
		["User-Agent: " + user_agent, "Content-Type: application/x-www-form-urlencoded"]
	)
	var err := req.request(
		ep.url_template, headers, HTTPClient.METHOD_POST, "data=" + query.uri_encode()
	)
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": error_string(err)}
	var state := {"done": false, "response": []}
	req.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			state["response"] = [result, code, body]
			state["done"] = true
	)
	while not state["done"]:
		if token != null and token.is_cancelled():
			req.cancel_request()
			req.queue_free()
			return {"ok": false, "error": "cancelled"}
		downloaded_bytes = req.get_downloaded_bytes()
		await tree.process_frame
	req.queue_free()
	var result: int = state["response"][0]
	var code: int = state["response"][1]
	if result == HTTPRequest.RESULT_TIMEOUT:
		return {"ok": false, "error": "no answer within %d s" % HTTP_TIMEOUT_SEC}
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "network error %d" % result}
	if code in [429, 406]:
		return {"ok": false, "rate_limited": true, "error": "HTTP %d (rate limited)" % code}
	if code in [503, 504]:
		return {"ok": false, "error": "HTTP %d (server busy)" % code}
	if code != 200:
		return {"ok": false, "error": "HTTP %d" % code}
	return _check_body((state["response"][2] as PackedByteArray).get_string_from_utf8())


## Overpass reports timeouts and memory errors in a "remark" with HTTP 200.
static func _check_body(text: String) -> Dictionary:
	if not text.strip_edges().begins_with("{"):
		return {"ok": false, "error": "not a JSON response"}
	var head := text.substr(0, 4096) + text.substr(maxi(text.length() - 4096, 0))
	if head.contains('"remark"') and head.contains("runtime error"):
		return {"ok": false, "error": "server-side runtime error (query too large?)"}
	return {"ok": true, "text": text, "error": ""}


static func _is_fresh(path: String, ttl_days: int) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var age := Time.get_unix_time_from_system() - FileAccess.get_modified_time(path)
	return ttl_days <= 0 or age < ttl_days * 86400.0


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "text": "", "endpoint": "", "from_cache": false, "error": message}
