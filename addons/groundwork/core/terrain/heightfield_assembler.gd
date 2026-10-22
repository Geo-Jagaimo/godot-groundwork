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
