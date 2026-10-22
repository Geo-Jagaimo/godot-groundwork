extends GdUnitTestSuite

const BBoxTool := preload("res://addons/groundwork/editor/bbox_tool.gd")


func test_bbox_tool_round_trip_and_resize() -> void:
	var tool := BBoxTool.new()
	var b := GwGeoBBox.from_sw_ne(35.0, 139.0, 35.1, 139.2)
	tool.set_bbox(b)
	var back := tool.get_bbox()
	assert_float(back.south).is_equal_approx(35.0, 1e-9)
	assert_float(back.east).is_equal_approx(139.2, 1e-9)
	tool.begin_drag(BBoxTool.Handle.E, tool.x1, tool.y0)
	tool.drag_to(tool.x1 + 0.001, tool.y0)
	tool.end_drag()
	assert_float(tool.get_bbox().east).is_greater(139.2)
	tool.begin_new(0.5, 0.5)
	tool.drag_to(0.4, 0.45)
	assert_float(tool.x0).is_equal(0.4)
	assert_float(tool.x1).is_equal(0.5)


func test_new_selection_is_clamped_to_the_world() -> void:
	var tool := BBoxTool.new()
	tool.begin_new(-0.2, 1.3)
	tool.drag_to(0.1, 0.9)
	assert_float(tool.x0).is_equal(0.0)
	assert_float(tool.y1).is_equal(1.0)
	assert_bool(tool.get_bbox().is_valid()).is_true()


func test_tiny_selection_has_no_handles() -> void:
	var tool := BBoxTool.new()
	tool.x0 = 0.5
	tool.y0 = 0.5
	tool.x1 = 0.5001
	tool.y1 = 0.5001
	tool.active = true
	var to_screen := func(nx: float, ny: float) -> Vector2: return Vector2(nx, ny) * 10000.0
	# 1 px on screen: a press next to it must not grab it.
	assert_int(tool.hit_test(Vector2(5000, 5000), to_screen)).is_equal(BBoxTool.Handle.NONE)
	var big := func(nx: float, ny: float) -> Vector2: return Vector2(nx, ny) * 1.0e6
	assert_int(tool.hit_test(Vector2(500050, 500050), big)).is_equal(BBoxTool.Handle.MOVE)
