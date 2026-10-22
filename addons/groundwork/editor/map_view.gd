@tool
extends Control
## Slippy map for picking the import area.
##
## Drag: pan / Wheel or pinch: zoom / Shift+drag: select an area, then drag its
## edges or inside to adjust. Basemap tiles are only displayed here, never baked
## into imports.

signal selection_changed(bbox: GwGeoBBox)
signal view_changed

enum Drag { NONE, PAN, SELECTION }

const BBoxTool := preload("res://addons/groundwork/editor/bbox_tool.gd")
const TILE := 256.0
const MIN_ZOOM := 1.0
const MAX_ZOOM := 20.0
const MAX_TEXTURES := 384
const FALLBACK_LEVELS := 6
## Tiles that failed to download are tried again after this long.
const RETRY_FAILED_MSEC := 30000
const SELECTION_FILL := Color(0.25, 0.55, 1.0, 0.18)
const SELECTION_LINE := Color(0.25, 0.55, 1.0, 0.95)

var basemap: GwTileProvider:
	set = set_basemap
## View centre in normalized Web Mercator (64-bit; Vector2 is too coarse at z18+).
var center_x := 0.5
var center_y := 0.5
var zoom := 2.0
var tool := BBoxTool.new()

var _fetcher: GwTileFetcher
var _textures := {}
var _texture_order: Array[String] = []
var _pending := {}
## key -> time (msec) after which the tile may be requested again.
var _unavailable := {}
var _wanted: Array[Vector3i] = []
var _wanted_keys := {}
var _drag := Drag.NONE
## Button that started the current drag; other buttons do not end it.
var _drag_button := MOUSE_BUTTON_NONE
## Whether the current selection drag creates a new selection (vs. editing one).
var _new_selection := false


func _init() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0, 220)
	tooltip_text = "Drag: pan · Wheel: zoom · Shift+drag: select area"


func _ready() -> void:
	_fetcher = GwTileFetcher.new(self)
	_fetcher.concurrency = 4


func _exit_tree() -> void:
	if _fetcher != null:
		_fetcher.dispose()


func set_basemap(value: GwTileProvider) -> void:
	if value == basemap:
		return
	basemap = value
	if _fetcher != null:
		_fetcher.cancel_all()
	_textures.clear()
	_texture_order.clear()
	_pending.clear()
	_unavailable.clear()
	queue_redraw()


func set_view(lat: float, lon: float, p_zoom: float) -> void:
	center_x = (lon + 180.0) / 360.0
	center_y = GwTileMath.lat_to_tile_y(lat, 0)
	zoom = clampf(p_zoom, MIN_ZOOM, MAX_ZOOM)
	_view_updated()


## Zooms to show [param bbox] with some margin.
func fit_bbox(bbox: GwGeoBBox) -> void:
	var nx0 := (bbox.west + 180.0) / 360.0
	var nx1 := (bbox.east + 180.0) / 360.0
	var ny0 := GwTileMath.lat_to_tile_y(bbox.north, 0)
	var ny1 := GwTileMath.lat_to_tile_y(bbox.south, 0)
	center_x = (nx0 + nx1) / 2.0
	center_y = (ny0 + ny1) / 2.0
	var view := size if size.x > 0 and size.y > 0 else Vector2(400, 300)
	var span := maxf((nx1 - nx0) / view.x, (ny1 - ny0) / view.y) * 1.4
	if span <= 0.0:
		zoom = 15.0
	else:
		zoom = clampf(log(1.0 / (span * TILE)) / log(2.0), MIN_ZOOM, MAX_ZOOM)
	_view_updated()


func get_center_lat() -> float:
	return GwTileMath.tile_y_to_lat(center_y, 0)


func get_center_lon() -> float:
	return center_x * 360.0 - 180.0


func set_selection(bbox: GwGeoBBox) -> void:
	tool.set_bbox(bbox)
	queue_redraw()


func get_selection() -> GwGeoBBox:
	return tool.get_bbox()


func world_size() -> float:
	return TILE * pow(2.0, zoom)


func norm_to_screen(nx: float, ny: float) -> Vector2:
	var w := world_size()
	return Vector2((nx - center_x) * w + size.x / 2.0, (ny - center_y) * w + size.y / 2.0)


func screen_to_norm(p: Vector2) -> PackedFloat64Array:
	var w := world_size()
	return PackedFloat64Array(
		[center_x + (p.x - size.x / 2.0) / w, center_y + (p.y - size.y / 2.0) / w]
	)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.85, 0.86, 0.84))
	_wanted.clear()
	_wanted_keys.clear()
	if basemap != null:
		_draw_tiles()
	_draw_selection()
	_draw_overlay_text()
	if not _wanted.is_empty():
		_request_wanted.call_deferred()


func _draw_tiles() -> void:
	var zi := clampi(roundi(zoom), basemap.min_zoom, basemap.max_zoom)
	var n := 1 << zi
	var w := world_size()
	var tile_px := w / n
	var left := center_x - size.x / 2.0 / w
	var top := center_y - size.y / 2.0 / w
	var tx0 := floori(left * n)
	var tx1 := floori((left + size.x / w) * n)
	var ty0 := maxi(floori(top * n), 0)
	var ty1 := mini(floori((top + size.y / w) * n), n - 1)
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			var wx := posmod(tx, n)
			var x := (float(tx) / n - center_x) * w + size.x / 2.0
			var y := (float(ty) / n - center_y) * w + size.y / 2.0
			var rect := Rect2(
				floorf(x), floorf(y), ceilf(x + tile_px) - floorf(x), ceilf(y + tile_px) - floorf(y)
			)
			var key := _key(zi, wx, ty)
			var tex: Texture2D = _textures.get(key)
			if tex != null:
				draw_texture_rect(tex, rect, false)
				continue
			if Time.get_ticks_msec() >= _unavailable.get(key, 0):
				_wanted.append(Vector3i(wx, ty, zi))
				_wanted_keys[key] = true
			_draw_fallback(zi, wx, ty, rect)


## Draws the closest loaded ancestor tile, magnified, while a tile loads.
func _draw_fallback(z: int, x: int, y: int, rect: Rect2) -> void:
	for dz in range(1, FALLBACK_LEVELS + 1):
		var pz := z - dz
		if pz < basemap.min_zoom:
			return
		var tex: Texture2D = _textures.get(_key(pz, x >> dz, y >> dz))
		if tex == null:
			continue
		var s := TILE / (1 << dz)
		var src := Rect2((x - ((x >> dz) << dz)) * s, (y - ((y >> dz) << dz)) * s, s, s)
		draw_texture_rect_region(tex, rect, src)
		return


func _draw_selection() -> void:
	if not tool.has_selection():
		return
	var r := tool.screen_rect(norm_to_screen)
	draw_rect(r, SELECTION_FILL)
	draw_rect(r, SELECTION_LINE, false, 2.0)
	var hs := Vector2(6, 6)
	for p in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		draw_rect(Rect2(p - hs / 2.0, hs), Color.WHITE)
		draw_rect(Rect2(p - hs / 2.0, hs), SELECTION_LINE, false, 1.0)


func _draw_overlay_text() -> void:
	var font := get_theme_default_font()
	var fs := maxi(get_theme_default_font_size() - 3, 9)
	if basemap != null and not basemap.attribution_short.is_empty():
		var text := basemap.attribution_short
		var ts := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var pos := Vector2(size.x - ts.x - 6, size.y - 5)
		draw_rect(Rect2(pos.x - 4, pos.y - ts.y, ts.x + 8, ts.y + 4), Color(1, 1, 1, 0.75))
		draw_string(
			font, pos - Vector2(0, 3), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.1, 0.1, 0.1)
		)
	if not tool.has_selection():
		var hint := "Shift+drag to select an area"
		var hs := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_rect(Rect2(4, 4, hs.x + 10, hs.y + 6), Color(0, 0, 0, 0.55))
		draw_string(
			font, Vector2(9, 4 + hs.y), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE
		)


func _request_wanted() -> void:
	if _fetcher == null or basemap == null:
		return
	var provider := basemap
	var wanted_keys := _wanted_keys.duplicate()
	# Drop queued tiles that scrolled out of view.
	_fetcher.cancel_queued(
		func(p: GwTileProvider, t: Vector3i) -> bool:
			return p == provider and wanted_keys.has(_key(t.z, t.x, t.y))
	)
	for t in _wanted.duplicate():
		var key := _key(t.z, t.x, t.y)
		if _pending.has(key) or _textures.has(key):
			continue
		_pending[key] = true
		_fetcher.request_tile(provider, t, _on_tile.bind(provider))


func _on_tile(tile: Vector3i, status: int, data: PackedByteArray, provider: GwTileProvider) -> void:
	if provider != basemap:
		return
	var key := _key(tile.z, tile.x, tile.y)
	_pending.erase(key)
	match status:
		GwTileFetcher.Status.OK:
			var image := GwImageUtil.load_image(data)
			if image == null:
				_unavailable[key] = Time.get_ticks_msec() + RETRY_FAILED_MSEC
				return
			_store_texture(key, ImageTexture.create_from_image(image))
			queue_redraw()
		GwTileFetcher.Status.MISSING:
			_unavailable[key] = 1 << 62
		GwTileFetcher.Status.FAILED:
			# Maybe offline for a moment: try again later instead of never.
			_unavailable[key] = Time.get_ticks_msec() + RETRY_FAILED_MSEC
			queue_redraw.call_deferred()


func _store_texture(key: String, tex: Texture2D) -> void:
	_textures[key] = tex
	_texture_order.append(key)
	var i := 0
	while _textures.size() > MAX_TEXTURES and i < _texture_order.size():
		var old := _texture_order[i]
		if _wanted_keys.has(old):
			i += 1
			continue
		_textures.erase(old)
		_texture_order.remove_at(i)


func _key(z: int, x: int, y: int) -> String:
	return "%d/%d/%d" % [z, x, y]


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventPanGesture:
		var pg := event as InputEventPanGesture
		if pg.ctrl_pressed or pg.meta_pressed:
			_zoom_at(pg.position, -pg.delta.y * 0.25)
		else:
			_pan_by(pg.delta * 30.0)
		accept_event()
	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		_zoom_at(mg.position, log(mg.factor) / log(2.0))
		accept_event()


func _on_mouse_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				var step := 0.25 * (mb.factor if mb.factor > 0.0 else 1.0)
				_zoom_at(mb.position, step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -step)
			accept_event()
		MOUSE_BUTTON_LEFT:
			if mb.pressed and _drag == Drag.NONE:
				if mb.double_click and not mb.shift_pressed:
					_zoom_at(mb.position, 1.0)
				elif mb.shift_pressed:
					var p := screen_to_norm(mb.position)
					tool.begin_new(p[0], p[1])
					_start_drag(Drag.SELECTION, mb.button_index, true)
				else:
					var handle := tool.hit_test(mb.position, norm_to_screen)
					if handle != BBoxTool.Handle.NONE:
						var p := screen_to_norm(mb.position)
						tool.begin_drag(handle, p[0], p[1])
						_start_drag(Drag.SELECTION, mb.button_index, false)
					else:
						_start_drag(Drag.PAN, mb.button_index, false)
			elif not mb.pressed and mb.button_index == _drag_button:
				_end_drag()
			accept_event()
		MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
			if mb.pressed and _drag == Drag.NONE:
				_start_drag(Drag.PAN, mb.button_index, false)
			elif not mb.pressed and mb.button_index == _drag_button:
				_end_drag()
			accept_event()


func _on_mouse_motion(mm: InputEventMouseMotion) -> void:
	match _drag:
		Drag.PAN:
			_pan_by(-mm.relative)
		Drag.SELECTION:
			var p := screen_to_norm(mm.position)
			tool.drag_to(p[0], p[1])
			queue_redraw()
		_:
			mouse_default_cursor_shape = BBoxTool.cursor_for(
				tool.hit_test(mm.position, norm_to_screen)
			)


func _start_drag(kind: Drag, button: MouseButton, new_selection: bool) -> void:
	_drag = kind
	_drag_button = button
	_new_selection = new_selection


func _end_drag() -> void:
	if _drag == Drag.SELECTION and tool.end_drag():
		# A Shift+click without a real drag clears the selection; edits never do.
		var r := tool.screen_rect(norm_to_screen)
		if _new_selection and (r.size.x < 4.0 or r.size.y < 4.0):
			tool.clear()
		selection_changed.emit(tool.get_bbox())
		queue_redraw()
	_drag = Drag.NONE
	_drag_button = MOUSE_BUTTON_NONE


func _pan_by(screen_delta: Vector2) -> void:
	var w := world_size()
	center_x = clampf(center_x + screen_delta.x / w, 0.0, 1.0)
	center_y = clampf(center_y + screen_delta.y / w, 0.0, 1.0)
	_view_updated()


func _zoom_at(screen_pos: Vector2, dz: float) -> void:
	var before := screen_to_norm(screen_pos)
	zoom = clampf(zoom + dz, MIN_ZOOM, MAX_ZOOM)
	var after := screen_to_norm(screen_pos)
	center_x = clampf(center_x + before[0] - after[0], 0.0, 1.0)
	center_y = clampf(center_y + before[1] - after[1], 0.0, 1.0)
	_view_updated()


func _view_updated() -> void:
	queue_redraw()
	view_changed.emit()
