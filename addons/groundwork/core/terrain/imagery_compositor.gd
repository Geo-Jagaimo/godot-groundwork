@tool
class_name GwImageryCompositor
extends RefCounted
## Composes imagery tiles into one texture per terrain chunk.
##
## Positions are in imagery "world pixels" (tile * 256 + pixel at
## [member imagery_zoom]). Those reach ~6.7e7 at zoom 18, so they are kept in
## 64-bit floats, never in Vector2.

## Imagery world pixel of heightfield sample (0, 0), at the pixel centre.
var origin_px_x := 0.0
var origin_px_y := 0.0
## Imagery pixels per heightfield cell.
var px_per_cell := 1.0
## Larger chunk textures are downscaled to this size.
var max_texture_size := 4096
var background := Color(0.45, 0.45, 0.42)


## [param origin_tile] is the first elevation tile (x, y) of the heightfield;
## [param zoom_scale] is 2^(imagery_zoom - elevation_zoom);
## [param step] is the heightfield decimation.
static func create(origin_tile: Vector2i, zoom_scale: float, step: int) -> GwImageryCompositor:
	var c := GwImageryCompositor.new()
	var size := GwTileMath.TILE_SIZE
	c.origin_px_x = (origin_tile.x * size + 0.5) * zoom_scale
	c.origin_px_y = (origin_tile.y * size + 0.5) * zoom_scale
	c.px_per_cell = zoom_scale * step
	return c


## Imagery-pixel extent of the chunk's vertices: [x0, y0, x1, y1].
func chunk_extent(cells: Rect2i) -> PackedFloat64Array:
	return PackedFloat64Array(
		[
			origin_px_x + cells.position.x * px_per_cell,
			origin_px_y + cells.position.y * px_per_cell,
			origin_px_x + cells.end.x * px_per_cell,
			origin_px_y + cells.end.y * px_per_cell,
		]
	)


## Imagery tiles needed for [param cells] as Rect2i(x_min, y_min, cols, rows).
func tile_range(cells: Rect2i) -> Rect2i:
	var e := chunk_extent(cells)
	var size := float(GwTileMath.TILE_SIZE)
	var tx0 := floori(floorf(e[0]) / size)
	var ty0 := floori(floorf(e[1]) / size)
	var tx1 := floori((ceilf(e[2]) - 1.0) / size)
	var ty1 := floori((ceilf(e[3]) - 1.0) / size)
	return Rect2i(tx0, ty0, maxi(tx1 - tx0 + 1, 1), maxi(ty1 - ty0 + 1, 1))


## Builds the chunk texture from raw tile bytes keyed by Vector2i(x, y).
## Returns {"image": Image, "uv_scale": Vector2, "uv_offset": Vector2,
## "missing": int}. Thread-safe.
func compose(cells: Rect2i, tile_bytes: Dictionary) -> Dictionary:
	var size := GwTileMath.TILE_SIZE
	var e := chunk_extent(cells)
	var x0 := floori(e[0])
	var y0 := floori(e[1])
	var w := maxi(ceili(e[2]) - x0, 1)
	var h := maxi(ceili(e[3]) - y0, 1)
	var image := Image.create_empty(w, h, false, Image.FORMAT_RGB8)
	image.fill(background)
	var missing := 0
	var tiles := tile_range(cells)
	for ty in range(tiles.position.y, tiles.end.y):
		for tx in range(tiles.position.x, tiles.end.x):
			var bytes: PackedByteArray = tile_bytes.get(Vector2i(tx, ty), PackedByteArray())
			var tile := GwImageUtil.load_image(bytes) if not bytes.is_empty() else null
			if tile == null:
				missing += 1
				continue
			if tile.get_format() != Image.FORMAT_RGB8:
				tile.convert(Image.FORMAT_RGB8)
			if tile.get_width() != size or tile.get_height() != size:
				tile.resize(size, size, Image.INTERPOLATE_BILINEAR)
			image.blit_rect(
				tile, Rect2i(0, 0, size, size), Vector2i(tx * size - x0, ty * size - y0)
			)
	var uv_scale := Vector2((e[2] - e[0]) / w, (e[3] - e[1]) / h)
	var uv_offset := Vector2((e[0] - x0) / w, (e[1] - y0) / h)
	if maxi(w, h) > max_texture_size:
		var f := float(max_texture_size) / maxi(w, h)
		image.resize(maxi(roundi(w * f), 1), maxi(roundi(h * f), 1), Image.INTERPOLATE_LANCZOS)
	return {"image": image, "uv_scale": uv_scale, "uv_offset": uv_offset, "missing": missing}
