@tool
class_name GwTileFetcher
extends RefCounted
## Downloads tiles through a pool of HTTPRequest nodes.
##
## Handles the disk cache, retries with exponential backoff, and merges
## duplicate requests for the same URL. Results are raw bytes; decoding is up to
## the caller (usually on a worker thread). Must be used from the main thread.

enum Status { OK, MISSING, FAILED, CANCELLED }

## OSM tile and Nominatim policies require a distinct, identifying User-Agent.
const PROJECT_URL := "https://github.com/Geo-Jagaimo/godot-groundwork"
const DEFAULT_USER_AGENT := "GodotGroundwork/0.2.0 (+" + PROJECT_URL + ")"
const RETRY_DELAYS: Array[float] = [0.5, 1.0, 2.0]
const RATE_LIMITED_RETRY_DELAYS: Array[float] = [2.0, 5.0, 10.0]


class Job:
	var url := ""
	var provider: GwTileProvider
	var tile := Vector3i.ZERO
	var callbacks: Array[Callable] = []
	var attempt := 0
	var request: HTTPRequest
	var handler: Callable


var concurrency := 6
var timeout_sec := 30.0
var user_agent := DEFAULT_USER_AGENT
var cache: GwTileCache
## provider id -> API key, substituted for {key} in URL templates.
var api_keys: Dictionary = {}

var _host: Node
var _pool: Node
var _idle: Array[HTTPRequest] = []
var _queue: Array[Job] = []
var _jobs: Dictionary = {}
var _running := 0


## [param host] is the node HTTPRequest children are added to (defaults to the
## scene tree root).
func _init(host: Node = null, p_cache: GwTileCache = null) -> void:
	_host = host
	cache = p_cache if p_cache != null else GwTileCache.new()


## Requests one tile. [param callback] is called as
## [code]callback(tile: Vector3i, status: Status, data: PackedByteArray)[/code],
## immediately for cache hits.
func request_tile(provider: GwTileProvider, tile: Vector3i, callback: Callable) -> void:
	if not provider.is_local():
		var hit := cache.lookup(provider, tile)
		if hit.status == GwTileCache.Status.HIT:
			callback.call(tile, Status.OK, hit.data)
			return
		if hit.status == GwTileCache.Status.KNOWN_MISSING:
			callback.call(tile, Status.MISSING, PackedByteArray())
			return
	var url := provider.tile_url(tile, api_keys.get(provider.id, ""))
	if _jobs.has(url):
		(_jobs[url] as Job).callbacks.append(callback)
		return
	var job := Job.new()
	job.url = url
	job.provider = provider
	job.tile = tile
	job.callbacks.append(callback)
	_jobs[url] = job
	_queue.append(job)
	_pump()


## Fetches many tiles and waits for all of them.
## Returns [code]{"data": {Vector3i: PackedByteArray}, "missing": Array[Vector3i],
## "failed": Array[Vector3i], "cancelled": bool}[/code].
## [param on_progress] is called as [code]on_progress(done: int, total: int)[/code].
func fetch_tiles(
	provider: GwTileProvider,
	tiles: Array[Vector3i],
	token: GwCancellationToken = null,
	on_progress: Callable = Callable()
) -> Dictionary:
	var missing: Array[Vector3i] = []
	var failed: Array[Vector3i] = []
	var state := {"data": {}, "missing": missing, "failed": failed, "done": 0, "cancelled": false}
	var total := tiles.size()
	var on_tile := func(tile: Vector3i, status: int, data: PackedByteArray) -> void:
		match status:
			Status.OK:
				state["data"][tile] = data
			Status.MISSING:
				state["missing"].append(tile)
			Status.FAILED:
				state["failed"].append(tile)
		state["done"] += 1

	for t in tiles:
		if token != null and token.is_cancelled():
			break
		request_tile(provider, t, on_tile)

	var tree := _tree()
	var reported := -1
	while state["done"] < total:
		if token != null and token.is_cancelled():
			cancel_all()
			state["cancelled"] = true
			break
		if on_progress.is_valid() and state["done"] != reported:
			reported = state["done"]
			on_progress.call(reported, total)
		await tree.process_frame
	if on_progress.is_valid():
		on_progress.call(state["done"], total)
	return state


## Drops queued (not yet started) requests for which
## [code]keep.call(provider, tile)[/code] returns false.
func cancel_queued(keep: Callable) -> void:
	var kept: Array[Job] = []
	var dropped: Array[Job] = []
	for job in _queue:
		if keep.call(job.provider, job.tile):
			kept.append(job)
		else:
			dropped.append(job)
	_queue = kept
	for job in dropped:
		_complete(job, Status.CANCELLED, PackedByteArray())


## Cancels everything, including running requests.
func cancel_all() -> void:
	_queue.clear()
	var jobs := _jobs.values()
	_jobs.clear()
	for job: Job in jobs:
		if job.request != null:
			if job.request.request_completed.is_connected(job.handler):
				job.request.request_completed.disconnect(job.handler)
			job.request.cancel_request()
			_release(job.request)
			job.request = null
			_running -= 1
		for cb in job.callbacks:
			if cb.is_valid():
				cb.call(job.tile, Status.CANCELLED, PackedByteArray())
	_running = maxi(_running, 0)


func pending_count() -> int:
	return _jobs.size()


## Cancels everything and frees the HTTPRequest pool.
func dispose() -> void:
	cancel_all()
	if is_instance_valid(_pool):
		_pool.queue_free()
	_pool = null
	_idle.clear()


func _pump() -> void:
	while _running < concurrency and not _queue.is_empty():
		_start(_queue.pop_front())


func _start(job: Job) -> void:
	_running += 1
	if job.provider.is_local():
		_finish_local.call_deferred(job)
		return
	var req := _acquire()
	job.request = req
	job.handler = _on_request_completed.bind(job)
	req.request_completed.connect(job.handler, CONNECT_ONE_SHOT)
	var err := req.request(job.url, PackedStringArray(["User-Agent: " + user_agent]))
	if err != OK:
		req.request_completed.disconnect(job.handler)
		job.request = null
		_release(req)
		_running -= 1
		_complete(job, Status.FAILED, PackedByteArray())


func _finish_local(job: Job) -> void:
	_running -= 1
	if _jobs.get(job.url) != job:
		return
	if FileAccess.file_exists(job.url):
		_complete(job, Status.OK, FileAccess.get_file_as_bytes(job.url))
	else:
		_complete(job, Status.MISSING, PackedByteArray())
	_pump()


func _on_request_completed(
	result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, job: Job
) -> void:
	if job.request != null:
		_release(job.request)
		job.request = null
	_running -= 1
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and not body.is_empty():
		if _expects_image(job.provider) and not GwImageUtil.looks_like_image(body):
			# e.g. a captive portal answering with HTML: do not cache it as a tile.
			_complete(job, Status.FAILED, PackedByteArray())
		else:
			cache.store(job.provider, job.tile, body)
			_complete(job, Status.OK, body)
	elif result == HTTPRequest.RESULT_SUCCESS and code in [204, 404, 410]:
		cache.store_missing(job.provider, job.tile)
		_complete(job, Status.MISSING, PackedByteArray())
	elif _is_retryable(result, code) and job.attempt < RETRY_DELAYS.size():
		var delays := RATE_LIMITED_RETRY_DELAYS if code == 429 else RETRY_DELAYS
		var delay := delays[job.attempt]
		job.attempt += 1
		_retry_later(job, delay)
	else:
		_complete(job, Status.FAILED, PackedByteArray())
	_pump()


func _retry_later(job: Job, delay: float) -> void:
	await _tree().create_timer(delay).timeout
	if _jobs.get(job.url) != job:
		return
	_queue.push_front(job)
	_pump()


func _complete(job: Job, status: Status, data: PackedByteArray) -> void:
	if _jobs.get(job.url) == job:
		_jobs.erase(job.url)
	for cb in job.callbacks:
		if cb.is_valid():
			cb.call(job.tile, status, data)


func _acquire() -> HTTPRequest:
	if not _idle.is_empty():
		return _idle.pop_back()
	if not is_instance_valid(_pool):
		_pool = Node.new()
		_pool.name = "GwTileFetcherPool"
		var host := _host if is_instance_valid(_host) else _tree().root
		host.add_child(_pool, true)
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = timeout_sec
	req.accept_gzip = true
	_pool.add_child(req)
	return req


func _release(req: HTTPRequest) -> void:
	if is_instance_valid(req):
		_idle.append(req)


static func _expects_image(provider: GwTileProvider) -> bool:
	return provider.tile_extension() in ["png", "jpg", "jpeg", "webp"]


static func _is_retryable(result: int, code: int) -> bool:
	if result != HTTPRequest.RESULT_SUCCESS:
		return true
	return code == 429 or code >= 500 or code == 0


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree
