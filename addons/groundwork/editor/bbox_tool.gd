@tool
extends RefCounted
## Rectangle selection on the map: create with Shift+drag, then move it or drag
## its edges and corners.
##
## Stored in normalized Web Mercator (x 0..1 west to east, y 0..1 north to
## south) as 64-bit floats.

enum Handle { NONE, MOVE, N, S, E, W, NE, NW, SE, SW }

const HANDLE_RADIUS := 7.0

var x0 := 0.0
var y0 := 0.0
var x1 := 0.0
var y1 := 0.0
var active := false

var _drag_handle := Handle.NONE
var _anchor_x := 0.0
var _anchor_y := 0.0
var _start := PackedFloat64Array()


func has_selection() -> bool:
	return active and x1 > x0 and y1 > y0


func clear() -> void:
	active = false
	_drag_handle = Handle.NONE


func set_bbox(bbox: GwGeoBBox) -> void:
	if bbox == null or not bbox.is_valid():
		clear()
		return
	x0 = (bbox.west + 180.0) / 360.0
	x1 = (bbox.east + 180.0) / 360.0
	y0 = GwTileMath.lat_to_tile_y(bbox.north, 0)
	y1 = GwTileMath.lat_to_tile_y(bbox.south, 0)
	active = true


func get_bbox() -> GwGeoBBox:
	if not has_selection():
		return null
	return GwGeoBBox.from_sw_ne(
		GwTileMath.tile_y_to_lat(y1, 0),
		x0 * 360.0 - 180.0,
		GwTileMath.tile_y_to_lat(y0, 0),
		x1 * 360.0 - 180.0
	)


func is_dragging() -> bool:
	return _drag_handle != Handle.NONE


## Starts a new selection at a normalized point.
func begin_new(nx: float, ny: float) -> void:
	x0 = nx
	x1 = nx
	y0 = ny
	y1 = ny
	active = true
	_drag_handle = Handle.SE
	_anchor_x = nx
	_anchor_y = ny
	_start = PackedFloat64Array()


## Starts dragging [param handle] (from [method hit_test]) at a normalized point.
func begin_drag(handle: Handle, nx: float, ny: float) -> void:
	_drag_handle = handle
	_anchor_x = nx
	_anchor_y = ny
	_start = PackedFloat64Array([x0, y0, x1, y1])


func drag_to(nx: float, ny: float) -> void:
	nx = clampf(nx, 0.0, 1.0)
	ny = clampf(ny, 0.0, 1.0)
	match _drag_handle:
		Handle.NONE:
			return
		Handle.MOVE:
			var dx := clampf(nx - _anchor_x, -_start[0], 1.0 - _start[2])
			var dy := clampf(ny - _anchor_y, -_start[1], 1.0 - _start[3])
			x0 = _start[0] + dx
			x1 = _start[2] + dx
			y0 = _start[1] + dy
			y1 = _start[3] + dy
			return
	if _start.is_empty():
		# New selection: the anchor is the fixed corner.
		x0 = minf(_anchor_x, nx)
		x1 = maxf(_anchor_x, nx)
		y0 = minf(_anchor_y, ny)
		y1 = maxf(_anchor_y, ny)
		return
	var h := _drag_handle
	if h in [Handle.W, Handle.NW, Handle.SW]:
		x0 = minf(nx, x1)
	if h in [Handle.E, Handle.NE, Handle.SE]:
		x1 = maxf(nx, x0)
	if h in [Handle.N, Handle.NW, Handle.NE]:
		y0 = minf(ny, y1)
	if h in [Handle.S, Handle.SW, Handle.SE]:
		y1 = maxf(ny, y0)


## Ends a drag. Returns true when the selection changed.
func end_drag() -> bool:
	var was := _drag_handle != Handle.NONE
	_drag_handle = Handle.NONE
	_start = PackedFloat64Array()
	return was


## [param to_screen] maps normalized (x, y) to a screen Vector2.
func screen_rect(to_screen: Callable) -> Rect2:
	var a: Vector2 = to_screen.call(x0, y0)
	var b: Vector2 = to_screen.call(x1, y1)
	return Rect2(a, b - a)


func hit_test(pos: Vector2, to_screen: Callable) -> Handle:
	if not has_selection():
		return Handle.NONE
	var r := screen_rect(to_screen)
	var near_l := absf(pos.x - r.position.x) <= HANDLE_RADIUS
	var near_r := absf(pos.x - r.end.x) <= HANDLE_RADIUS
	var near_t := absf(pos.y - r.position.y) <= HANDLE_RADIUS
	var near_b := absf(pos.y - r.end.y) <= HANDLE_RADIUS
	var in_x := pos.x >= r.position.x - HANDLE_RADIUS and pos.x <= r.end.x + HANDLE_RADIUS
	var in_y := pos.y >= r.position.y - HANDLE_RADIUS and pos.y <= r.end.y + HANDLE_RADIUS
	if not (in_x and in_y):
		return Handle.NONE
	if near_t and near_l:
		return Handle.NW
	if near_t and near_r:
		return Handle.NE
	if near_b and near_l:
		return Handle.SW
	if near_b and near_r:
		return Handle.SE
	if near_t:
		return Handle.N
	if near_b:
		return Handle.S
	if near_l:
		return Handle.W
	if near_r:
		return Handle.E
	if r.has_point(pos):
		return Handle.MOVE
	return Handle.NONE


static func cursor_for(handle: Handle) -> Control.CursorShape:
	match handle:
		Handle.MOVE:
			return Control.CURSOR_MOVE
		Handle.N, Handle.S:
			return Control.CURSOR_VSIZE
		Handle.E, Handle.W:
			return Control.CURSOR_HSIZE
		Handle.NW, Handle.SE:
			return Control.CURSOR_FDIAGSIZE
		Handle.NE, Handle.SW:
			return Control.CURSOR_BDIAGSIZE
	return Control.CURSOR_ARROW
