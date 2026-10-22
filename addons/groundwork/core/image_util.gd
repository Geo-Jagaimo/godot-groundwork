@tool
class_name GwImageUtil
extends RefCounted
## Image helpers that are safe to call from worker threads.


## Decodes PNG / JPEG / WebP bytes by sniffing the header. Returns null on failure.
static func load_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47:
		err = image.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = image.load_jpg_from_buffer(bytes)
	elif bytes.slice(0, 4).get_string_from_ascii() == "RIFF":
		err = image.load_webp_from_buffer(bytes)
	if err != OK or image.is_empty():
		return null
	return image
