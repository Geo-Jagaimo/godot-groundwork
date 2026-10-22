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
