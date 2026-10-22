@tool
extends EditorPlugin
## Registers the Geo dock. All logic lives in core/ and editor/.

const GeoDock := preload("res://addons/groundwork/editor/geo_dock.gd")
const SettingsBridge := preload("res://addons/groundwork/editor/settings_bridge.gd")
const EditorImporter := preload("res://addons/groundwork/editor/editor_importer.gd")
const SELFTEST_ARG := "--groundwork-selftest"
const SELFTEST_SCRIPT := "res://addons/groundwork/tests/editor_selftest.gd"

var _dock: GeoDock
var _importer: EditorImporter


func _enter_tree() -> void:
	SettingsBridge.register()
	_importer = EditorImporter.new()
	GwWorldBuilder.default_file_importer = _importer.import_files
	_dock = GeoDock.new()
	_dock.name = "Geo"
	_dock.undo_redo = get_undo_redo()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)
	if SELFTEST_ARG in OS.get_cmdline_user_args() and ResourceLoader.exists(SELFTEST_SCRIPT):
		var selftest: Node = load(SELFTEST_SCRIPT).new()
		selftest.set("dock", _dock)
		add_child(selftest)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	GwWorldBuilder.default_file_importer = Callable()
	_importer = null
