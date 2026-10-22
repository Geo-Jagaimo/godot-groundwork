@tool
class_name GwSceneRoot
extends Node3D
## Root of a generated scene. Converts between geographic and scene coordinates.
##
## "Local" means relative to this node. Use the [code]*_global[/code] variants
## when the scene has been moved, rotated or instanced somewhere else.
## (Named [code]geo_to_local[/code] rather than [code]to_local[/code] because
## [method Node3D.to_local] already exists.)

@export var geo_reference: GwGeoReference
@export var heightfield: GwHeightfield


## Position of a geographic point in this node's space. When
## [param elevation] is NAN the terrain height at that point is used.
func geo_to_local(lat: float, lon: float, elevation: float = NAN) -> Vector3:
	var p := geo_reference.to_local(lat, lon, 0.0)
	p.y = sample_elevation(Vector2(p.x, p.z)) if is_nan(elevation) else elevation
	return p


## [lat, lon] of a point in this node's space.
func local_to_geo(local: Vector3) -> PackedFloat64Array:
	return geo_reference.to_geo(local)


func geo_to_global(lat: float, lon: float, elevation: float = NAN) -> Vector3:
	return global_transform * geo_to_local(lat, lon, elevation)


func global_to_geo(global_point: Vector3) -> PackedFloat64Array:
	return local_to_geo(global_transform.affine_inverse() * global_point)


## Terrain elevation at a local XZ position (NAN without a heightfield).
func sample_elevation(local_xz: Vector2) -> float:
	if heightfield == null:
		return NAN
	return heightfield.sample(local_xz)


func get_attribution() -> String:
	return geo_reference.attribution if geo_reference != null else ""
