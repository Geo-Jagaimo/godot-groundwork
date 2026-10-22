@tool
class_name GwElevationDecoder
extends RefCounted
## Base class: turns an elevation tile image into heights in metres.
##
## Output is row-major, one value per pixel, NAN for NoData.
## Implementations must be thread-safe (they run on WorkerThreadPool).


func decode(_image: Image) -> PackedFloat32Array:
	return PackedFloat32Array()


func decode_bytes(bytes: PackedByteArray) -> PackedFloat32Array:
	var image := GwImageUtil.load_image(bytes)
	if image == null:
		return PackedFloat32Array()
	return decode(image)


## RGB8 pixel bytes of [param image], converting a copy if needed.
static func rgb8_bytes(image: Image) -> PackedByteArray:
	if image.get_format() == Image.FORMAT_RGB8:
		return image.get_data()
	var copy := image.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	copy.convert(Image.FORMAT_RGB8)
	return copy.get_data()
