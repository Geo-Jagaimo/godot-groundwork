@tool
extends RefCounted
## EditorSettings / ProjectSettings used by the dock.
##
## API keys are personal EditorSettings and never written to project files.

const API_KEY_PREFIX := "groundwork/api_keys/"
const CONCURRENCY := "groundwork/network/concurrency"
const GEOCODER_ENABLED := "groundwork/geocoder/enabled"
const DEFAULT_ELEVATION := "groundwork/defaults/elevation_provider"
const DEFAULT_IMAGERY := "groundwork/defaults/imagery_provider"
const DEFAULT_RESOLUTION := "groundwork/defaults/target_resolution_m"
const DEFAULT_OUTPUT_DIR := "groundwork/defaults/output_dir"
const META_SECTION := "groundwork"


static func register() -> void:
	var es := EditorInterface.get_editor_settings()
	_editor_setting(es, CONCURRENCY, 6, TYPE_INT, PROPERTY_HINT_RANGE, "1,16")
	_editor_setting(es, GEOCODER_ENABLED, true, TYPE_BOOL)
	_project_setting(DEFAULT_ELEVATION, "terrarium_aws", TYPE_STRING)
	_project_setting(DEFAULT_IMAGERY, "", TYPE_STRING)
	_project_setting(
		DEFAULT_RESOLUTION, 10.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0.5,500,0.5,suffix:m"
	)
	_project_setting(DEFAULT_OUTPUT_DIR, "res://geo/", TYPE_STRING, PROPERTY_HINT_DIR)
	_project_setting(
		GwLog.LEVEL_SETTING, GwLog.Level.WARN, TYPE_INT, PROPERTY_HINT_ENUM, "Error,Warn,Info,Debug"
	)


## provider id -> key for providers that need one. Also registers an empty
## setting per provider so it is easy to find in Editor Settings.
static func api_keys(providers: Array[GwTileProvider]) -> Dictionary:
	var es := EditorInterface.get_editor_settings()
	var keys := {}
	for p in providers:
		if not p.requires_api_key:
			continue
		var name := API_KEY_PREFIX + p.id
		_editor_setting(es, name, "", TYPE_STRING, PROPERTY_HINT_PASSWORD)
		keys[p.id] = str(es.get_setting(name))
	return keys


static func concurrency() -> int:
	return int(EditorInterface.get_editor_settings().get_setting(CONCURRENCY))


static func geocoder_enabled() -> bool:
	return bool(EditorInterface.get_editor_settings().get_setting(GEOCODER_ENABLED))


static func project_default(name: String, fallback: Variant) -> Variant:
	return ProjectSettings.get_setting(name, fallback)


static func get_meta_value(key: String, fallback: Variant) -> Variant:
	return EditorInterface.get_editor_settings().get_project_metadata(META_SECTION, key, fallback)


static func set_meta_value(key: String, value: Variant) -> void:
	EditorInterface.get_editor_settings().set_project_metadata(META_SECTION, key, value)


static func _editor_setting(
	es: EditorSettings,
	name: String,
	value: Variant,
	type: int,
	hint: int = PROPERTY_HINT_NONE,
	hint_string: String = ""
) -> void:
	if not es.has_setting(name):
		es.set_setting(name, value)
	es.set_initial_value(name, value, false)
	es.add_property_info({"name": name, "type": type, "hint": hint, "hint_string": hint_string})


## Registers a project setting. Values equal to the default are not written to
## project.godot.
static func _project_setting(
	name: String,
	value: Variant,
	type: int,
	hint: int = PROPERTY_HINT_NONE,
	hint_string: String = ""
) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, value)
	ProjectSettings.set_initial_value(name, value)
	ProjectSettings.add_property_info(
		{"name": name, "type": type, "hint": hint, "hint_string": hint_string}
	)
