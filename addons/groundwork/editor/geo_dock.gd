@tool
extends VBoxContainer
## The "Geo" dock: search, map with area selection, import panel.

const MapView := preload("res://addons/groundwork/editor/map_view.gd")
const ImportPanel := preload("res://addons/groundwork/editor/import_panel.gd")
const SettingsBridge := preload("res://addons/groundwork/editor/settings_bridge.gd")

## Set by plugin.gd.
var undo_redo: EditorUndoRedoManager

var map: MapView
var panel: ImportPanel
var _search: LineEdit
var _basemap_option: OptionButton
var _basemaps: Array[GwTileProvider] = []
var _area_label: Label
var _status: Label
var _cache_label: Label
var _overwrite_dialog: ConfirmationDialog
var _geocoder: GwGeocoder
var _builder: GwWorldBuilder
var _last_result: GwImportResult
var _pending_request: GwImportRequest
var _searching := false


func _init() -> void:
	add_theme_constant_override("separation", 4)
	# The editor would translate only the labels that happen to match its own
	# strings ("Name", "Import", ...), giving a half-translated dock.
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED

	var top := HBoxContainer.new()
	_search = LineEdit.new()
	_search.placeholder_text = "Search place, lat,lon or z/x/y"
	_search.tooltip_text = "Press Enter to search. " + GwGeocoder.ATTRIBUTION
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.clear_button_enabled = true
	_search.text_submitted.connect(_on_search)
	top.add_child(_search)
	_basemap_option = OptionButton.new()
	_basemap_option.tooltip_text = "Background map (display only)"
	_basemap_option.fit_to_longest_item = false
	_basemap_option.clip_text = true
	_basemap_option.custom_minimum_size.x = 150
	_basemap_option.item_selected.connect(_on_basemap_selected)
	top.add_child(_basemap_option)
	add_child(top)

	var split := VSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	map = MapView.new()
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.custom_minimum_size = Vector2(0, 220)
	map.selection_changed.connect(_on_selection_changed)
	split.add_child(map)

	# Map and settings share the height; the split can be dragged.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 200)
	split.add_child(scroll)
	var lower := VBoxContainer.new()
	lower.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(lower)

	_area_label = Label.new()
	_area_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lower.add_child(_area_label)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.visible = false
	lower.add_child(_status)

	panel = ImportPanel.new()
	panel.changed.connect(_update_plan)
	panel.import_requested.connect(_on_import_requested)
	panel.cancel_requested.connect(_on_cancel_requested)
	panel.open_requested.connect(_on_open_requested)
	panel.instance_requested.connect(_on_instance_requested)
	lower.add_child(panel)

	lower.add_child(HSeparator.new())
	var cache_row := HBoxContainer.new()
	_cache_label = Label.new()
	_cache_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cache_row.add_child(_cache_label)
	var reload := Button.new()
	reload.text = "Reload Providers"
	reload.tooltip_text = "Rescan presets and res://groundwork_providers/"
	reload.pressed.connect(_reload_providers)
	cache_row.add_child(reload)
	var clear := Button.new()
	clear.text = "Clear Cache"
	clear.pressed.connect(_on_clear_cache)
	cache_row.add_child(clear)
	lower.add_child(cache_row)


func _ready() -> void:
	var scale := EditorInterface.get_editor_scale()
	_basemap_option.custom_minimum_size.x = 150 * scale
	map.custom_minimum_size.y = 220 * scale
	_geocoder = GwGeocoder.new(self)
	_overwrite_dialog = ConfirmationDialog.new()
	_overwrite_dialog.title = "Overwrite Import"
	_overwrite_dialog.ok_button_text = "Overwrite"
	_overwrite_dialog.confirmed.connect(_on_overwrite_confirmed)
	add_child(_overwrite_dialog)
	_reload_providers()
	var view: Array = SettingsBridge.get_meta_value("view", [20.0, 0.0, 2.0])
	map.set_view(view[0], view[1], view[2])
	var sel: Variant = SettingsBridge.get_meta_value("selection", Vector4.ZERO)
	if sel is Vector4 and sel != Vector4.ZERO:
		var b := GwGeoBBox.from_vector4(sel)
		map.set_selection(b)
		_on_selection_changed(b)
	else:
		_on_selection_changed(null)
	_update_cache_label()


func _exit_tree() -> void:
	if map != null:
		SettingsBridge.set_meta_value(
			"view", [map.get_center_lat(), map.get_center_lon(), map.zoom]
		)
	if _builder != null:
		_builder.cancel()


func _reload_providers() -> void:
	var current: String = (
		map.basemap.id if map.basemap else SettingsBridge.get_meta_value("basemap", "osm_standard")
	)
	_basemaps = GwProviderRegistry.list_providers(GwTileProvider.Kind.BASEMAP)
	_basemap_option.clear()
	var selected := 0
	for p in _basemaps:
		if p.id == current:
			selected = _basemap_option.item_count
		_basemap_option.add_item(p.get_label())
	if not _basemaps.is_empty():
		_basemap_option.select(selected)
		map.basemap = _basemaps[selected]
	panel.reload_providers()


func _on_basemap_selected(index: int) -> void:
	map.basemap = _basemaps[index]
	SettingsBridge.set_meta_value("basemap", map.basemap.id)


func _on_selection_changed(bbox: GwGeoBBox) -> void:
	if bbox == null:
		_area_label.text = "No area selected. Shift+drag on the map."
		SettingsBridge.set_meta_value("selection", Vector4.ZERO)
	else:
		_area_label.text = (
			"%.5f, %.5f – %.5f, %.5f\n%.2f km × %.2f km"
			% [
				bbox.south,
				bbox.west,
				bbox.north,
				bbox.east,
				bbox.width_m() / 1000.0,
				bbox.height_m() / 1000.0,
			]
		)
		SettingsBridge.set_meta_value("selection", bbox.to_vector4())
	panel.set_bbox(bbox)


func _update_plan() -> void:
	var req := panel.build_request()
	panel.set_plan(GwImportPlan.from_request(req, SettingsBridge.api_keys(panel.all_providers())))


func _on_search(text: String) -> void:
	var coords := GwGeocoder.parse_coordinates(text)
	var hit := coords
	if coords.is_empty():
		if not SettingsBridge.geocoder_enabled():
			_show_status(
				"Place search is disabled (Editor Settings > groundwork/geocoder/enabled)."
			)
			return
		if _searching:
			return
		_searching = true
		_show_status("Searching…")
		hit = await _geocoder.search(text)
		_searching = false
	if hit.is_empty():
		_show_status('Nothing found for "%s".' % text)
		return
	if hit.has("bbox"):
		map.fit_bbox(hit["bbox"])
	else:
		map.set_view(hit["lat"], hit["lon"], hit["zoom"])
	_show_status(hit.get("name", ""))


func _on_import_requested() -> void:
	var req := panel.build_request()
	if DirAccess.dir_exists_absolute(req.get_output_folder()):
		_pending_request = req
		_overwrite_dialog.dialog_text = (
			"%s already exists.\nOverwrite the generated files in it?" % req.get_output_folder()
		)
		_overwrite_dialog.popup_centered()
		return
	_start_import(req)


func _on_overwrite_confirmed() -> void:
	if _pending_request == null:
		return
	_pending_request.overwrite = true
	_start_import(_pending_request)
	_pending_request = null


func _start_import(req: GwImportRequest) -> void:
	if _builder != null:
		return
	var builder := GwWorldBuilder.new()
	builder.host_node = self
	builder.concurrency = SettingsBridge.concurrency()
	builder.api_keys = SettingsBridge.api_keys(panel.all_providers())
	builder.progress.connect(panel.set_progress)
	_builder = builder
	panel.set_busy(true)
	var result: GwImportResult = await builder.build(req)
	_builder = null
	_last_result = result
	panel.set_busy(false)
	panel.show_result(result)
	_update_cache_label()
	if result.ok:
		var efs := EditorInterface.get_resource_filesystem()
		efs.scan()
		if result.scene_path in EditorInterface.get_open_scenes():
			EditorInterface.reload_scene_from_path(result.scene_path)
	_update_plan()


func _on_cancel_requested() -> void:
	if _builder != null:
		_builder.cancel()


func _on_open_requested() -> void:
	if _last_result != null and _last_result.ok:
		EditorInterface.open_scene_from_path(_last_result.scene_path)


func _on_instance_requested() -> void:
	if _last_result == null or not _last_result.ok:
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		_on_open_requested()
		return
	var packed := ResourceLoader.load(_last_result.scene_path, "PackedScene") as PackedScene
	if packed == null:
		return
	var instance := packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	undo_redo.create_action("Add Groundwork Scene")
	undo_redo.add_do_method(scene_root, "add_child", instance, true)
	undo_redo.add_do_method(instance, "set_owner", scene_root)
	undo_redo.add_do_reference(instance)
	undo_redo.add_undo_method(scene_root, "remove_child", instance)
	undo_redo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(instance)


func _on_clear_cache() -> void:
	GwTileCache.new().clear()
	_update_cache_label()


func _update_cache_label() -> void:
	_cache_label.text = "Cache: %.1f MB" % (GwTileCache.new().get_size_bytes() / 1.0e6)


func _show_status(text: String) -> void:
	_status.text = text
	_status.visible = not text.is_empty()
