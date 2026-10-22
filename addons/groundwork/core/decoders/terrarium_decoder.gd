@tool
class_name GwTerrariumDecoder
extends GwElevationDecoder
## Mapzen Terrarium: h = (R * 256 + G + B / 256) - 32768


func decode(image: Image) -> PackedFloat32Array:
	var src := rgb8_bytes(image)
	var count := image.get_width() * image.get_height()
	var out := PackedFloat32Array()
	out.resize(count)
	var j := 0
	for i in count:
		out[i] = src[j] * 256.0 + src[j + 1] + src[j + 2] / 256.0 - 32768.0
		j += 3
	return out


static func decode_pixel(r: int, g: int, b: int) -> float:
	return r * 256.0 + g + b / 256.0 - 32768.0
