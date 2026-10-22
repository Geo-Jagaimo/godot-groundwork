@tool
class_name GwImportResult
extends RefCounted
## Outcome of [method GwWorldBuilder.build].

enum ErrorCode {
	NONE,
	INVALID_REQUEST,
	OUTPUT_EXISTS,
	NETWORK,
	NO_DATA,
	CANCELLED,
	SAVE_FAILED,
}

var ok := false
var error_code := ErrorCode.NONE
var error_message := ""
## Non-fatal problems (missing tiles, interpolated NoData, ...).
var warnings: Array[String] = []
var scene_path := ""
var output_folder := ""
var files := PackedStringArray()
## Counts and timings, e.g. "elevation_tiles", "chunks", "triangles", "seconds".
var stats := {}
var plan: GwImportPlan


func fail(code: ErrorCode, message: String) -> GwImportResult:
	ok = false
	error_code = code
	error_message = message
	return self
