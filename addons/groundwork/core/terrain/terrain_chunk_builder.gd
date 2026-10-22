@tool
class_name GwTerrainChunkBuilder
extends RefCounted
## Splits a heightfield into chunks and builds their mesh arrays and collision.
##
## A chunk of N x M cells has (N + 1) x (M + 1) vertices and shares its border
## vertices with its neighbours, so there are no seams. Vertices are in the
## scene root's space, computed from global grid indices, so shared border
## vertices are bit-identical and chunk nodes need no transform (Godot 4.4 writes
## .tscn transforms with only 6 significant digits, which would open cracks).
## Array building is pure and thread-safe; creating ArrayMesh /
## HeightMapShape3D is left to the main thread.


## Number of chunks along X and Z.
static func chunk_grid(hf: GwHeightfield, chunk_size: int) -> Vector2i:
	return Vector2i(
		ceili((hf.width - 1) / float(chunk_size)), ceili((hf.height - 1) / float(chunk_size))
	)


## Cells covered by chunk (cx, cz): position = first cell, size = cell count.
static func chunk_cells(hf: GwHeightfield, chunk_size: int, cx: int, cz: int) -> Rect2i:
	var c0 := cx * chunk_size
	var r0 := cz * chunk_size
	return Rect2i(c0, r0, mini(chunk_size, hf.width - 1 - c0), mini(chunk_size, hf.height - 1 - r0))


## Mesh arrays for [method ArrayMesh.add_surface_from_arrays]. UVs span 0..1
## over the chunk. With [param vertex_colors], adds an elevation gradient.
static func build_arrays(hf: GwHeightfield, cells: Rect2i, vertex_colors: bool = false) -> Array:
	var vw := cells.size.x + 1
	var vh := cells.size.y + 1
	var count := vw * vh
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	verts.resize(count)
	normals.resize(count)
	uvs.resize(count)
	if vertex_colors:
		colors.resize(count)
	var cs := hf.cell_size
	var ox := hf.origin.x
	var oz := hf.origin.y
	var src := hf.data
	var w := hf.width
	var last_c := hf.width - 1
	var last_r := hf.height - 1
	var inv_w := 1.0 / cells.size.x
	var inv_h := 1.0 / cells.size.y
	var range_h := maxf(hf.max_height - hf.min_height, 0.001)
	var i := 0
	for j in vh:
		var r := cells.position.y + j
		var ru := maxi(r - 1, 0)
		var rd := mini(r + 1, last_r)
		var dz_len := (rd - ru) * cs
		for k in vw:
			var c := cells.position.x + k
			var cl := maxi(c - 1, 0)
			var cr := mini(c + 1, last_c)
			var h := src[r * w + c]
			verts[i] = Vector3(ox + c * cs, h, oz + r * cs)
			# Central differences on the whole heightfield (same as normal_at),
			# so normals match across chunk borders.
			var dx := (src[r * w + cr] - src[r * w + cl]) / ((cr - cl) * cs)
			var dz := (src[rd * w + c] - src[ru * w + c]) / dz_len
			normals[i] = Vector3(-dx, 1.0, -dz).normalized()
			uvs[i] = Vector2(k * inv_w, j * inv_h)
			if vertex_colors:
				colors[i] = elevation_color((h - hf.min_height) / range_h)
			i += 1

	var indices := PackedInt32Array()
	indices.resize(cells.size.x * cells.size.y * 6)
	var n := 0
	for j in cells.size.y:
		for k in cells.size.x:
			var a := j * vw + k
			var b := a + 1
			var d := a + vw
			var e := d + 1
			# Clockwise when seen from above (Godot's front face).
			indices[n] = a
			indices[n + 1] = b
			indices[n + 2] = d
			indices[n + 3] = b
			indices[n + 4] = e
			indices[n + 5] = d
			n += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	if vertex_colors:
		arrays[Mesh.ARRAY_COLOR] = colors
	return arrays


## Heights for a HeightMapShape3D of the chunk, divided by the cell size because
## the shape is scaled uniformly by it (see [method collision_transform]).
static func build_collision_heights(hf: GwHeightfield, cells: Rect2i) -> PackedFloat32Array:
	var vw := cells.size.x + 1
	var vh := cells.size.y + 1
	var out := PackedFloat32Array()
	out.resize(vw * vh)
	var inv := 1.0 / hf.cell_size
	var i := 0
	for j in vh:
		var row := (cells.position.y + j) * hf.width + cells.position.x
		for k in vw:
			out[i] = hf.data[row + k] * inv
			i += 1
	return out


## Placement of the chunk's HeightMapShape3D in the scene root's space. The
## shape is centred on its origin with unit spacing, so it is moved to the
## chunk centre and scaled uniformly by the cell size (non-uniform scaling of
## collision shapes is not supported).
static func collision_transform(hf: GwHeightfield, cells: Rect2i) -> Transform3D:
	var cs := hf.cell_size
	var basis := Basis.from_scale(Vector3(cs, cs, cs))
	var center := hf.origin + (Vector2(cells.position) + Vector2(cells.size) / 2.0) * cs
	return Transform3D(basis, Vector3(center.x, 0.0, center.y))


static func create_mesh(arrays: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func create_collision_shape(cells: Rect2i, heights: PackedFloat32Array) -> HeightMapShape3D:
	var shape := HeightMapShape3D.new()
	shape.map_width = cells.size.x + 1
	shape.map_depth = cells.size.y + 1
	shape.map_data = heights
	return shape


## Fallback colouring when there is no imagery: green lowlands to white peaks.
static func elevation_color(t: float) -> Color:
	const STOPS: Array[Color] = [
		Color(0.24, 0.42, 0.22),
		Color(0.45, 0.55, 0.30),
		Color(0.55, 0.47, 0.35),
		Color(0.60, 0.58, 0.56),
		Color(0.95, 0.95, 0.97),
	]
	var x := clampf(t, 0.0, 1.0) * (STOPS.size() - 1)
	var i := mini(floori(x), STOPS.size() - 2)
	return STOPS[i].lerp(STOPS[i + 1], x - i)
