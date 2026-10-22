extends GdUnitTestSuite


static func _hill(w: int, h: int, cell: float) -> GwHeightfield:
	var hf := GwHeightfield.create(w, h, cell, Vector2(-w * cell / 2.0, -h * cell / 2.0))
	for r in h:
		for c in w:
			hf.set_height(c, r, 100.0 + 50.0 * sin(c * 0.3) * cos(r * 0.2))
	hf.compute_min_max()
	return hf


func test_chunk_grid_and_cells() -> void:
	var hf := _hill(21, 11, 2.0)
	assert_that(GwTerrainChunkBuilder.chunk_grid(hf, 8)).is_equal(Vector2i(3, 2))
	assert_that(GwTerrainChunkBuilder.chunk_cells(hf, 8, 0, 0)).is_equal(Rect2i(0, 0, 8, 8))
	# Last chunks are partial: 20 cells = 8 + 8 + 4; 10 cells = 8 + 2.
	assert_that(GwTerrainChunkBuilder.chunk_cells(hf, 8, 2, 1)).is_equal(Rect2i(16, 8, 4, 2))


func test_vertex_and_index_counts() -> void:
	var hf := _hill(17, 17, 1.0)
	var cells := Rect2i(0, 0, 16, 16)
	var arrays := GwTerrainChunkBuilder.build_arrays(hf, cells)
	assert_int((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()).is_equal(17 * 17)
	assert_int((arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()).is_equal(16 * 16 * 6)
	assert_object(arrays[Mesh.ARRAY_COLOR]).is_null()
	var colored := GwTerrainChunkBuilder.build_arrays(hf, cells, true)
	assert_int((colored[Mesh.ARRAY_COLOR] as PackedColorArray).size()).is_equal(17 * 17)


func test_normals_unit_length_and_match_heightfield() -> void:
	var hf := _hill(17, 17, 1.0)
	var cells := Rect2i(8, 0, 8, 8)
	var arrays := GwTerrainChunkBuilder.build_arrays(hf, cells)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in normals.size():
		assert_float(normals[i].length()).is_equal_approx(1.0, 1e-4)
	var vw := cells.size.x + 1
	assert_vector(normals[3 * vw + 2]).is_equal_approx(
		hf.normal_at(10, 3), Vector3(1e-5, 1e-5, 1e-5)
	)


func test_front_faces_point_up() -> void:
	# Godot treats clockwise triangles as front faces.
	var hf := _hill(5, 5, 1.0)
	var arrays := GwTerrainChunkBuilder.build_arrays(hf, Rect2i(0, 0, 4, 4))
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for t in range(0, idx.size(), 3):
		var a := v[idx[t]]
		var n := (v[idx[t + 2]] - a).cross(v[idx[t + 1]] - a)
		assert_float(n.y).is_greater(0.0)


func test_chunk_borders_share_vertices() -> void:
	var hf := _hill(17, 9, 1.5)
	var left := Rect2i(0, 0, 8, 8)
	var right := Rect2i(8, 0, 8, 8)
	var la := GwTerrainChunkBuilder.build_arrays(hf, left)
	var ra := GwTerrainChunkBuilder.build_arrays(hf, right)
	var lv: PackedVector3Array = la[Mesh.ARRAY_VERTEX]
	var rv: PackedVector3Array = ra[Mesh.ARRAY_VERTEX]
	var ln: PackedVector3Array = la[Mesh.ARRAY_NORMAL]
	var rn: PackedVector3Array = ra[Mesh.ARRAY_NORMAL]
	for j in 9:
		var li := j * 9 + 8
		var ri := j * 9
		# Bit-identical, not just close: no cracks between chunks.
		assert_bool(lv[li] == rv[ri]).is_true()
		assert_vector(ln[li]).is_equal_approx(rn[ri], Vector3(1e-6, 1e-6, 1e-6))


func test_collision_heights_match_mesh() -> void:
	var hf := _hill(13, 13, 3.0)
	var cells := Rect2i(4, 4, 8, 8)
	var arrays := GwTerrainChunkBuilder.build_arrays(hf, cells)
	var heights := GwTerrainChunkBuilder.build_collision_heights(hf, cells)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_int(heights.size()).is_equal(verts.size())
	var xf := GwTerrainChunkBuilder.collision_transform(hf, cells)
	assert_vector(xf.basis.get_scale()).is_equal_approx(Vector3(3, 3, 3), Vector3(1e-6, 1e-6, 1e-6))
	# Centre of the chunk: the middle vertex of a 9 x 9 grid.
	var mid := verts[4 * 9 + 4]
	assert_vector(xf.origin).is_equal_approx(Vector3(mid.x, 0, mid.z), Vector3(1e-4, 1e-4, 1e-4))
	for i in verts.size():
		assert_float(heights[i] * hf.cell_size).is_equal_approx(verts[i].y, 1e-3)
	var shape := GwTerrainChunkBuilder.create_collision_shape(cells, heights)
	assert_int(shape.map_width).is_equal(9)
	assert_int(shape.map_depth).is_equal(9)
