@tool
class_name GwGltfExporter
extends RefCounted
## Writes the visible parts of a generated scene to glTF 2.0 (.glb or .gltf), for
## Blender or other engines.
##
## Terrain chunks (full detail only), buildings, roads and water are exported
## with their materials and embedded textures. Collision, the coarser LOD levels
## and the attribution overlay are left out: remember to credit the data
## providers (ATTRIBUTION.md) wherever the exported file is used.


## Exports [param root] (usually a GwSceneRoot) to [param path].
static func export_scene(root: Node3D, path: String) -> Error:
	var copy := visual_copy(root)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(copy, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	copy.free()
	return err


## A plain copy of the visible meshes, grouped as in [param root], with
## materials made exportable. The caller owns the result.
static func visual_copy(root: Node3D) -> Node3D:
	var out := Node3D.new()
	out.name = root.name
	_copy_children(root, out, root)
	return out


static func _copy_children(from: Node, to: Node3D, root: Node3D) -> void:
	for child in from.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			# Coarser LOD levels start at a distance; only full detail is exported.
			if mi.mesh == null or mi.visibility_range_begin > 0.0:
				continue
			to.add_child(_copy_mesh_instance(mi, root))
		elif child is Node3D and not child is CollisionObject3D:
			var group := Node3D.new()
			group.name = child.name
			to.add_child(group)
			_copy_children(child, group, root)
			if group.get_child_count() == 0:
				to.remove_child(group)
				group.free()


static func _copy_mesh_instance(mi: MeshInstance3D, root: Node3D) -> MeshInstance3D:
	var out := MeshInstance3D.new()
	out.name = mi.name
	out.transform = _relative_transform(mi, root)
	var material := mi.get_active_material(0)
	var mesh := mi.mesh
	if material is StandardMaterial3D:
		var std := (material as StandardMaterial3D).duplicate() as StandardMaterial3D
		if std.uv1_scale != Vector3.ONE or std.uv1_offset != Vector3.ZERO:
			# Bake the texture transform into the UVs: glTF readers vary in
			# their support for KHR_texture_transform.
			mesh = _transformed_uv_mesh(mesh, std.uv1_scale, std.uv1_offset)
			std.uv1_scale = Vector3.ONE
			std.uv1_offset = Vector3.ZERO
		if std.albedo_texture != null:
			std.albedo_texture = _exportable_texture(std.albedo_texture)
		material = std
	out.mesh = mesh
	out.set_surface_override_material(0, material)
	return out


## Transform of [param node] in [param root]'s space; works outside the tree.
static func _relative_transform(node: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


## An ImageTexture with plain (uncompressed) pixels, which glTF can embed.
static func _exportable_texture(texture: Texture2D) -> Texture2D:
	var image: Image
	var path := texture.resource_path
	if path.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp"]:
		# Imported textures are VRAM compressed; read the source file instead.
		image = Image.load_from_file(path)
	if image == null or image.is_empty():
		image = texture.get_image()
	if image == null or image.is_empty():
		return texture
	if image.is_compressed():
		image.decompress()
	image.clear_mipmaps()
	return ImageTexture.create_from_image(image)


static func _transformed_uv_mesh(mesh: Mesh, scale: Vector3, offset: Vector3) -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for i in uvs.size():
			uvs[i] = uvs[i] * Vector2(scale.x, scale.y) + Vector2(offset.x, offset.y)
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out
