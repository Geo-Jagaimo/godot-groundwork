@tool
class_name GwGsiDemDecoder
extends GwElevationDecoder
## GSI elevation PNG tiles (地理院標高タイル).
##
## x = R * 65536 + G * 256 + B; x == 2^23 is NoData;
## h = x * 0.01 when x < 2^23, otherwise (x - 2^24) * 0.01.

const NODATA := 8388608
const WRAP := 16777216
const UNIT := 0.01


func decode(image: Image) -> PackedFloat32Array:
	var src := rgb8_bytes(image)
	var count := image.get_width() * image.get_height()
	var out := PackedFloat32Array()
	out.resize(count)
	var j := 0
	for i in count:
		var x: int = (src[j] << 16) | (src[j + 1] << 8) | src[j + 2]
		if x == NODATA:
			out[i] = NAN
		elif x < NODATA:
			out[i] = x * UNIT
		else:
			out[i] = (x - WRAP) * UNIT
		j += 3
	return out


static func decode_pixel(r: int, g: int, b: int) -> float:
	var x := (r << 16) | (g << 8) | b
	if x == NODATA:
		return NAN
	if x < NODATA:
		return x * UNIT
	return (x - WRAP) * UNIT
