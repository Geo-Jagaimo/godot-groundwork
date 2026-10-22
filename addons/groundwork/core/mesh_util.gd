@tool
class_name GwMeshUtil
extends RefCounted
## Small helpers for building mesh arrays. Thread-safe.


## Appends triangle (a, b, c), flipping it if needed so that its front face
## (clockwise, Godot's convention) points along [param facing].
static func add_triangle(
	indices: PackedInt32Array, verts: PackedVector3Array, a: int, b: int, c: int, facing: Vector3
) -> void:
	var front := (verts[c] - verts[a]).cross(verts[b] - verts[a])
	if front.dot(facing) < 0.0:
		indices.append_array(PackedInt32Array([a, c, b]))
	else:
		indices.append_array(PackedInt32Array([a, b, c]))


## Arrays for [method ArrayMesh.add_surface_from_arrays], or null when empty.
static func surface_arrays(
	verts: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> Variant:
	if indices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays
