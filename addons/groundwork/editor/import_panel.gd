@tool
extends VBoxContainer
## Import parameters, estimate, progress and result. Holds no import logic:
## the dock builds the request, the plan and runs the builder.

signal changed
signal import_requested
signal cancel_requested
signal open_requested
signal instance_requested

const SettingsBridge := preload("res://addons/groundwork/editor/settings_bridge.gd")
const CHUNK_SIZES: Array[int] = [64, 128, 256]
const DECIMATIONS: Array[int] = [1, 2, 4]

var bbox: GwGeoBBox

var _elevation: Array[GwTileProvider] = []
var _imagery: Array[GwTileProvider] = []
var _overpass: Array[GwTileProvider] = []
var _name_edit: LineEdit
var _dir_edit: LineEdit
var _dir_dialog: EditorFileDialog
var _elev_option: OptionButton
var _res_spin: SpinBox
var _img_option: OptionButton
var _offset_spin: SpinBox
var _chunk_option: OptionButton
var _decim_option: OptionButton
var _collision_check: CheckBox
var _label_check: CheckBox
var _buildings_check: CheckBox
var _roads_check: CheckBox
var _osm_option: OptionButton
var _height_spin: SpinBox
var _estimate: Label
var _messages: RichTextLabel
var _import_button: Button
var _cancel_button: Button
var _progress: ProgressBar
var _stage: Label
var _result_box: HBoxContainer
var _plan_ok := false
var _busy := false


func _init() -> void:
	add_theme_constant_override("separation", 6)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	add_child(grid)

	_name_edit = LineEdit.new()
	_name_edit.text = "terrain"
	_name_edit.text_changed.connect(_emit_changed.unbind(1))
	_row(grid, "Name", _name_edit)

	var dir_row := HBoxContainer.new()
	_dir_edit = LineEdit.new()
	_dir_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dir_edit.text_changed.connect(_emit_changed.unbind(1))
	dir_row.add_child(_dir_edit)
	var browse := Button.new()
	browse.text = "…"
	browse.tooltip_text = "Choose the output folder"
	browse.pressed.connect(_browse_dir)
	dir_row.add_child(browse)
	_row(grid, "Output", dir_row)

	_elev_option = OptionButton.new()
	_elev_option.item_selected.connect(_emit_changed.unbind(1))
	_elev_option.fit_to_longest_item = false
	_row(grid, "Elevation", _elev_option)

	_res_spin = SpinBox.new()
	_res_spin.min_value = 0.5
	_res_spin.max_value = 500.0
	_res_spin.step = 0.5
	_res_spin.suffix = "m"
	_res_spin.tooltip_text = "Target heightfield spacing. The closest zoom level is used."
	_res_spin.value_changed.connect(_emit_changed.unbind(1))
	_row(grid, "Resolution", _res_spin)

	_img_option = OptionButton.new()
	_img_option.item_selected.connect(_emit_changed.unbind(1))
	_img_option.fit_to_longest_item = false
	_row(grid, "Imagery", _img_option)

	_offset_spin = SpinBox.new()
	_offset_spin.min_value = 0
	_offset_spin.max_value = 4
	_offset_spin.value = 2
	_offset_spin.prefix = "+"
	_offset_spin.tooltip_text = "Imagery zoom = elevation zoom + this."
	_offset_spin.value_changed.connect(_emit_changed.unbind(1))
	_row(grid, "Imagery zoom", _offset_spin)

	_chunk_option = OptionButton.new()
	for s in CHUNK_SIZES:
		_chunk_option.add_item("%d cells" % s)
	_chunk_option.select(1)
	_chunk_option.item_selected.connect(_emit_changed.unbind(1))
	_row(grid, "Chunk size", _chunk_option)

	_decim_option = OptionButton.new()
	for d in DECIMATIONS:
		_decim_option.add_item("1/%d" % d if d > 1 else "Full")
	_decim_option.tooltip_text = "Use every Nth sample to lighten meshes (e.g. for mobile)."
	_decim_option.item_selected.connect(_emit_changed.unbind(1))
	_row(grid, "Mesh detail", _decim_option)

	_collision_check = CheckBox.new()
	_collision_check.text = "Collision (HeightMapShape3D)"
	_collision_check.button_pressed = true
	_collision_check.toggled.connect(_emit_changed.unbind(1))
	_row(grid, "", _collision_check)

	_label_check = CheckBox.new()
	_label_check.text = "Attribution label in scene"
	_label_check.button_pressed = true
	_label_check.tooltip_text = "Data providers require attribution wherever the data is shown."
	_label_check.toggled.connect(_emit_changed.unbind(1))
	_row(grid, "", _label_check)

	var osm_title := Label.new()
	osm_title.text = "OpenStreetMap"
	osm_title.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	grid.add_child(osm_title)
	# Keep the two-column grid aligned.
	grid.add_child(Control.new())
	var osm_row := HBoxContainer.new()
	_buildings_check = CheckBox.new()
	_buildings_check.text = "Buildings"
	_buildings_check.tooltip_text = "Extruded buildings with collision (flat roofs)."
	_buildings_check.toggled.connect(_on_osm_toggled.unbind(1))
	osm_row.add_child(_buildings_check)
	_roads_check = CheckBox.new()
	_roads_check.text = "Roads"
	_roads_check.tooltip_text = "Roads draped over the terrain (no collision of their own)."
	_roads_check.toggled.connect(_on_osm_toggled.unbind(1))
	osm_row.add_child(_roads_check)
	_row(grid, "", osm_row)

	_osm_option = OptionButton.new()
	_osm_option.fit_to_longest_item = false
	_osm_option.clip_text = true
	_osm_option.tooltip_text = "Overpass API server. The others are tried if it fails."
	_osm_option.item_selected.connect(_emit_changed.unbind(1))
	_row(grid, "Overpass", _osm_option)

	_height_spin = SpinBox.new()
	_height_spin.min_value = 1.0
	_height_spin.max_value = 200.0
	_height_spin.step = 0.5
	_height_spin.value = 6.0
	_height_spin.suffix = "m"
	_height_spin.tooltip_text = "Height of buildings without height or building:levels tags."
	_height_spin.value_changed.connect(_emit_changed.unbind(1))
	_row(grid, "Default height", _height_spin)
	_update_osm_rows()

	add_child(HSeparator.new())
	_estimate = Label.new()
	_estimate.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_estimate.add_theme_color_override("font_color", Color(0.75, 0.78, 0.82))
	add_child(_estimate)

	var buttons := HBoxContainer.new()
	_import_button = Button.new()
	_import_button.text = "Import"
	_import_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_import_button.pressed.connect(func() -> void: import_requested.emit())
	buttons.add_child(_import_button)
	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.disabled = true
	_cancel_button.pressed.connect(func() -> void: cancel_requested.emit())
	buttons.add_child(_cancel_button)
	add_child(buttons)

	_progress = ProgressBar.new()
	_progress.visible = false
	add_child(_progress)
	_stage = Label.new()
	_stage.visible = false
	_stage.clip_text = true
	add_child(_stage)

	_messages = RichTextLabel.new()
	_messages.bbcode_enabled = true
	_messages.fit_content = true
	_messages.scroll_active = false
	_messages.selection_enabled = true
	add_child(_messages)

	_result_box = HBoxContainer.new()
	_result_box.visible = false
	var open := Button.new()
	open.text = "Open Scene"
	open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open.pressed.connect(func() -> void: open_requested.emit())
	_result_box.add_child(open)
	var inst := Button.new()
	inst.text = "Add to Current Scene"
	inst.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inst.pressed.connect(func() -> void: instance_requested.emit())
	_result_box.add_child(inst)
	add_child(_result_box)


func _ready() -> void:
	_dir_dialog = EditorFileDialog.new()
	_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_dir_dialog.dir_selected.connect(
		func(dir: String) -> void:
			_dir_edit.text = dir
			_emit_changed()
	)
	add_child(_dir_dialog)
	reload_providers()
	_dir_edit.text = SettingsBridge.project_default(SettingsBridge.DEFAULT_OUTPUT_DIR, "res://geo/")
	_res_spin.set_value_no_signal(
		float(SettingsBridge.project_default(SettingsBridge.DEFAULT_RESOLUTION, 10.0))
	)


## Refreshes provider lists (built-in presets + res://groundwork_providers/).
func reload_providers() -> void:
	var elev_id := _selected_id(_elevation, _elev_option)
	var img_id := _selected_id(_imagery, _img_option, true)
	if elev_id.is_empty():
		elev_id = SettingsBridge.project_default(SettingsBridge.DEFAULT_ELEVATION, "terrarium_aws")
	if img_id.is_empty():
		img_id = SettingsBridge.project_default(SettingsBridge.DEFAULT_IMAGERY, "")
	var osm_id := _selected_id(_overpass, _osm_option)
	_elevation = GwProviderRegistry.list_providers(GwTileProvider.Kind.ELEVATION)
	_imagery = GwProviderRegistry.list_providers(GwTileProvider.Kind.IMAGERY)
	_overpass = GwProviderRegistry.list_providers(GwTileProvider.Kind.VECTOR)
	_fill(_elev_option, _elevation, elev_id, false)
	_fill(_img_option, _imagery, img_id, true)
	_fill(_osm_option, _overpass, osm_id, false)
	_emit_changed()


func set_bbox(value: GwGeoBBox) -> void:
	bbox = value
	_emit_changed()


func all_providers() -> Array[GwTileProvider]:
	var out: Array[GwTileProvider] = []
	out.append_array(_elevation)
	out.append_array(_imagery)
	out.append_array(_overpass)
	return out


func build_request() -> GwImportRequest:
	var req := GwImportRequest.new()
	req.import_name = _name_edit.text.strip_edges()
	req.output_dir = _dir_edit.text.strip_edges()
	req.bbox = bbox
	req.elevation_provider = _provider_at(_elevation, _elev_option, false)
	req.target_resolution_m = _res_spin.value
	req.imagery_provider = _provider_at(_imagery, _img_option, true)
	req.imagery_zoom_offset = int(_offset_spin.value)
	req.chunk_size = CHUNK_SIZES[maxi(_chunk_option.selected, 0)]
	req.mesh_decimation = DECIMATIONS[maxi(_decim_option.selected, 0)]
	req.generate_collision = _collision_check.button_pressed
	req.add_attribution_label = _label_check.button_pressed
	req.include_buildings = _buildings_check.button_pressed
	req.include_roads = _roads_check.button_pressed
	req.osm_provider = _provider_at(_overpass, _osm_option, false)
	req.building_default_height_m = _height_spin.value
	return req


## Restores fields from a previous request (e.g. an import_request.tres).
func apply_request(req: GwImportRequest) -> void:
	_name_edit.text = req.import_name
	_dir_edit.text = req.output_dir
	_res_spin.set_value_no_signal(req.target_resolution_m)
	_offset_spin.set_value_no_signal(req.imagery_zoom_offset)
	_chunk_option.select(maxi(CHUNK_SIZES.find(req.chunk_size), 0))
	_decim_option.select(maxi(DECIMATIONS.find(req.mesh_decimation), 0))
	_collision_check.set_pressed_no_signal(req.generate_collision)
	_label_check.set_pressed_no_signal(req.add_attribution_label)
	if req.elevation_provider:
		_fill(_elev_option, _elevation, req.elevation_provider.id, false)
	_fill(_img_option, _imagery, req.imagery_provider.id if req.imagery_provider else "", true)
	_buildings_check.set_pressed_no_signal(req.include_buildings)
	_roads_check.set_pressed_no_signal(req.include_roads)
	if req.osm_provider:
		_fill(_osm_option, _overpass, req.osm_provider.id, false)
	_height_spin.set_value_no_signal(req.building_default_height_m)
	_update_osm_rows()
	bbox = req.bbox
	_emit_changed()


func set_plan(plan: GwImportPlan) -> void:
	_plan_ok = plan != null and plan.is_valid()
	_estimate.text = plan.describe() if _plan_ok else ""
	var lines := PackedStringArray()
	if plan != null:
		for e in plan.errors:
			lines.append("[color=#ff7070]✕ %s[/color]" % e)
		for w in plan.warnings:
			lines.append("[color=#ffcc66]⚠ %s[/color]" % w)
	if not _busy:
		_messages.text = "\n".join(lines)
	_update_buttons()


func set_busy(busy: bool) -> void:
	_busy = busy
	_progress.visible = busy
	_stage.visible = busy
	if busy:
		_progress.value = 0
		_stage.text = "Starting…"
		_messages.text = ""
		_result_box.visible = false
	_update_buttons()


func set_progress(stage: String, done: int, total: int) -> void:
	var label := GwWorldBuilder.stage_label(stage)
	# The builder ignores Cancel while writing files; say so with the button.
	_cancel_button.disabled = not _busy or stage in GwWorldBuilder.WRITE_STAGES
	if total <= 0:
		# Unknown total (OpenStreetMap download): show the size so far.
		_progress.max_value = 1
		_progress.value = 0
		_stage.text = "%s  %.1f MB" % [label, done / 1.0e6]
		return
	_progress.max_value = total
	_progress.value = done
	_stage.text = "%s  %d / %d" % [label, done, total]


func show_result(result: GwImportResult) -> void:
	var lines := PackedStringArray()
	if result.ok:
		lines.append(
			(
				"[color=#80e080]✓ %s (%.1f s)[/color]"
				% [result.scene_path, result.stats.get("seconds", 0.0)]
			)
		)
	else:
		lines.append("[color=#ff7070]✕ %s[/color]" % result.error_message)
	for w in result.warnings:
		lines.append("[color=#ffcc66]⚠ %s[/color]" % w)
	_messages.text = "\n".join(lines)
	_result_box.visible = result.ok


func _update_buttons() -> void:
	_import_button.disabled = _busy or not _plan_ok
	_cancel_button.disabled = not _busy


func _on_osm_toggled() -> void:
	_update_osm_rows()
	_emit_changed()


func _update_osm_rows() -> void:
	var on := _buildings_check.button_pressed or _roads_check.button_pressed
	_osm_option.disabled = not on
	_height_spin.editable = _buildings_check.button_pressed


func _browse_dir() -> void:
	_dir_dialog.current_dir = _dir_edit.text
	_dir_dialog.popup_file_dialog()


func _emit_changed() -> void:
	changed.emit()


static func _row(grid: GridContainer, label: String, control: Control) -> void:
	var l := Label.new()
	l.text = label
	grid.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)


static func _fill(
	option: OptionButton, providers: Array[GwTileProvider], select_id: String, with_none: bool
) -> void:
	option.clear()
	if with_none:
		option.add_item("None (elevation colours)")
	var selected := 0
	for p in providers:
		if p.id == select_id:
			selected = option.item_count
		option.add_item(p.get_label())
		option.set_item_tooltip(option.item_count - 1, p.attribution_short)
	if option.item_count > 0:
		option.select(selected)


static func _provider_at(
	providers: Array[GwTileProvider], option: OptionButton, with_none: bool
) -> GwTileProvider:
	var i := option.selected - (1 if with_none else 0)
	return providers[i] if i >= 0 and i < providers.size() else null


static func _selected_id(
	providers: Array[GwTileProvider], option: OptionButton, with_none: bool = false
) -> String:
	if option == null or option.item_count == 0:
		return ""
	var p := _provider_at(providers, option, with_none)
	return p.id if p != null else ""
