@tool
class_name GwHeightfieldAssembler
extends RefCounted
## Stitches decoded elevation tiles into one heightfield.


## [param tiles] maps Vector2i(tile_x, tile_y) to decoded heights
## (tile_size * tile_size, row-major). Missing or malformed tiles become NAN.
## The result covers the whole tile-aligned [param tile_rect].
static func assemble(
	tile_rect: Rect2i,
	tiles: Dictionary,
	cell_size: float,
	origin: Vector2,
	tile_size: int = GwTileMath.TILE_SIZE
) -> GwHeightfield:
	var w := tile_rect.size.x * tile_size
	var h := tile_rect.size.y * tile_size
	var hf := GwHeightfield.new()
	hf.width = w
	hf.height = h
	hf.cell_size = cell_size
	hf.origin = origin
	var nan_row := PackedFloat32Array()
	nan_row.resize(tile_size)
	nan_row.fill(NAN)
	var out := PackedFloat32Array()
	for ty in range(tile_rect.position.y, tile_rect.end.y):
		var row_tiles: Array[PackedFloat32Array] = []
		for tx in range(tile_rect.position.x, tile_rect.end.x):
			var t: PackedFloat32Array = tiles.get(Vector2i(tx, ty), PackedFloat32Array())
			row_tiles.append(t if t.size() == tile_size * tile_size else PackedFloat32Array())
		for py in tile_size:
			var a := py * tile_size
			for t in row_tiles:
				if t.is_empty():
					out.append_array(nan_row)
				else:
					out.append_array(t.slice(a, a + tile_size))
	hf.data = out
	return hf


## The part of a parent tile ([param levels] zooms lower) that covers one of its
## descendants, enlarged to a full tile. [param sub] is the descendant's position
## inside the parent in descendant tiles. Bilinear where all four neighbours are
## valid, nearest otherwise (so NoData does not spread). Thread-safe.
static func crop_parent(
	parent: PackedFloat32Array, tile_size: int, levels: int, sub: Vector2i
) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(tile_size * tile_size)
	var span := float(tile_size) / (1 << levels)
	var last := tile_size - 1
	for y in tile_size:
		var py := clampf(sub.y * span + (y + 0.5) * span / tile_size - 0.5, 0.0, last)
		var y0 := mini(floori(py), last - 1)
		var fy := py - y0
		for x in tile_size:
			var px := clampf(sub.x * span + (x + 0.5) * span / tile_size - 0.5, 0.0, last)
			var x0 := mini(floori(px), last - 1)
			var fx := px - x0
			var i := y0 * tile_size + x0
			var h00 := parent[i]
			var h10 := parent[i + 1]
			var h01 := parent[i + tile_size]
			var h11 := parent[i + tile_size + 1]
			if is_nan(h00) or is_nan(h10) or is_nan(h01) or is_nan(h11):
				out[y * tile_size + x] = parent[roundi(py) * tile_size + roundi(px)]
			else:
				var top := lerpf(h00, h10, fx)
				var bottom := lerpf(h01, h11, fx)
				out[y * tile_size + x] = lerpf(top, bottom, fy)
	return out
