@tool
class_name GwElevationDecoder
extends RefCounted
## Base class: turns an elevation tile image into heights in metres.
##
## Output is row-major, one value per pixel, NAN for NoData.
## Implementations must be thread-safe (they run on WorkerThreadPool).


func decode(_image: Image) -> PackedFloat32Array:
	return PackedFloat32Array()


## Decodes a tile and returns [param tile_size] x [param tile_size] heights.
## Tiles of another size (e.g. 512 px) are resampled to fit the tile grid.
func decode_bytes(
	bytes: PackedByteArray, tile_size: int = GwTileMath.TILE_SIZE
) -> PackedFloat32Array:
	var image := GwImageUtil.load_image(bytes)
	if image == null:
		return PackedFloat32Array()
	var heights := decode(image)
	if image.get_width() == tile_size and image.get_height() == tile_size:
		return heights
	return resample(heights, image.get_width(), image.get_height(), tile_size)


## Nearest-sample resize (heights can't be blended through RGB, and NAN must stay
## NAN).
static func resample(heights: PackedFloat32Array, w: int, h: int, size: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(size * size)
	for y in size:
		var sy := mini(floori((y + 0.5) * h / size), h - 1)
		for x in size:
			var sx := mini(floori((x + 0.5) * w / size), w - 1)
			out[y * size + x] = heights[sy * w + sx]
	return out


## RGB8 pixel bytes of [param image], converting a copy if needed.
static func rgb8_bytes(image: Image) -> PackedByteArray:
	if image.get_format() == Image.FORMAT_RGB8:
		return image.get_data()
	var copy := image.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.convert(Image.FORMAT_RGB8)
	return copy.get_data()
