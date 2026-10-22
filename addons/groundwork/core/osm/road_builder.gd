@tool
class_name GwRoadBuilder
extends RefCounted
## Turns OSM road centrelines into ribbons draped over the terrain.
##
## Centrelines are resampled every [constant STEP] metres; at each point a
## left / centre / right vertex is placed on the heightfield and lifted a little
## to avoid z-fighting. Crossings are simply overlapped. Roads have no collision:
## they sit on the terrain collision. One mesh per road class (see
## [constant CLASSES]) so each class can have its own material. Pure and
## thread-safe.

## Width in metres per highway=* value; *_link uses its base value times
## [constant LINK_FACTOR].
const DEFAULT_WIDTHS := {
	"motorway": 12.0,
	"trunk": 10.0,
	"primary": 10.0,
	"secondary": 8.0,
	"tertiary": 6.0,
	"residential": 6.0,
	"unclassified": 6.0,
	"road": 6.0,
	"busway": 6.0,
	"living_street": 5.0,
	"service": 4.0,
	"pedestrian": 4.0,
	"track": 3.0,
	"footway": 2.0,
	"path": 2.0,
	"cycleway": 2.0,
	"bridleway": 2.0,
	"steps": 2.0,
	"corridor": 2.0,
}
const DEFAULT_WIDTH := 4.0
const LINK_FACTOR := 0.7
## Mesh / material groups, lowest first: later classes are lifted slightly more
## so that major roads win where they overlap minor ones.
const CLASSES := {
	"path":
	["footway", "path", "cycleway", "bridleway", "steps", "pedestrian", "track", "corridor"],
	"service": ["service"],
	"residential": ["residential", "unclassified", "living_street", "road", "busway"],
	"tertiary": ["tertiary"],
	"secondary": ["secondary"],
	"primary": ["primary"],
	"motorway": ["motorway", "trunk"],
}
const CLASS_COLORS := {
	"path": Color(0.62, 0.58, 0.52),
	"service": Color(0.42, 0.42, 0.42),
	"residential": Color(0.36, 0.36, 0.37),
	"tertiary": Color(0.33, 0.33, 0.34),
	"secondary": Color(0.31, 0.31, 0.32),
	"primary": Color(0.29, 0.29, 0.30),
	"motorway": Color(0.26, 0.26, 0.28),
}
const STEP := 5.0
const LIFT := 0.15
const CLASS_LIFT := 0.02


static func base_highway(highway: String) -> String:
	return highway.trim_suffix("_link")


static func width_for(highway: String, overrides: Dictionary = {}) -> float:
	if overrides.has(highway):
		return float(overrides[highway])
	var base := base_highway(highway)
	var w: float = overrides.get(base, DEFAULT_WIDTHS.get(base, DEFAULT_WIDTH))
	return w * LINK_FACTOR if highway.ends_with("_link") else w


## Mesh group for a highway=* value.
static func road_class(highway: String) -> String:
	var base := base_highway(highway)
	for cls: String in CLASSES:
		if base in CLASSES[cls]:
			return cls
	return "residential"


static func class_names() -> Array[String]:
	var out: Array[String] = []
	for cls: String in CLASSES:
		out.append(cls)
	return out


## Inserts points so that consecutive points are at most [param step] apart.
## Original vertices are kept.
static func resample(points: PackedVector2Array, step: float = STEP) -> PackedVector2Array:
	var out := PackedVector2Array()
	if points.is_empty():
		return out
	out.append(points[0])
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var n := ceili(a.distance_to(b) / step)
		for k in range(1, n):
			out.append(a.lerp(b, float(k) / n))
		if a.distance_squared_to(b) > 0.0:
			out.append(b)
	return out


## Splits a polyline into the runs of points inside [param rect].
static func clip(points: PackedVector2Array, rect: Rect2) -> Array[PackedVector2Array]:
	var runs: Array[PackedVector2Array] = []
	var run := PackedVector2Array()
	for p in points:
		if rect.has_point(p):
			run.append(p)
		else:
			if run.size() >= 2:
				runs.append(run)
			run = PackedVector2Array()
	if run.size() >= 2:
		runs.append(run)
	return runs


## Groups roads by [method road_class]. Returns {class: Array[GwOsmParser.Road]}.
static func group_by_class(roads: Array) -> Dictionary:
	var groups := {}
	for r: GwOsmParser.Road in roads:
		var cls := road_class(r.highway)
		if not groups.has(cls):
			groups[cls] = []
		groups[cls].append(r)
	return groups


## Mesh arrays for the roads of one class. Returns {"arrays": Array or null,
## "built": int}.
static func build(
	roads: Array, hf: GwHeightfield, road_cls: String, overrides: Dictionary = {}
) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Keep ribbons a little inside the terrain so they never hang over its edge.
	var rect := Rect2(hf.origin, hf.get_extent()).grow(-hf.cell_size)
	var class_lift := LIFT + CLASSES.keys().find(road_cls) * CLASS_LIFT
	var built := 0
	for r_index in roads.size():
		var road: GwOsmParser.Road = roads[r_index]
		var half := width_for(road.highway, overrides) / 2.0
		# A tiny per-road offset reduces z-fighting where same-class roads cross.
		var lift := class_lift + (r_index % 4) * 0.004
		for run in clip(resample(road.points), rect):
			add_ribbon(run, half, lift, hf, verts, normals, uvs, indices)
			built += 1
	return {"arrays": GwMeshUtil.surface_arrays(verts, normals, uvs, indices), "built": built}


## Appends a ribbon of half-width [param half] along [param pts], draped over
## [param hf] and lifted by [param lift] metres.
static func add_ribbon(
	pts: PackedVector2Array,
	half: float,
	lift: float,
	hf: GwHeightfield,
	verts: PackedVector3Array,
	normals: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array
) -> void:
	var start := verts.size()
	var along := 0.0
	var n := pts.size()
	for i in n:
		var p := pts[i]
		var t := pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		t = t.normalized() if t.length_squared() > 0.0 else Vector2.RIGHT
		var side := Vector2(-t.y, t.x) * half
		if i > 0:
			along += pts[i - 1].distance_to(p)
		var v := along / (half * 2.0)
		var k := 0
		for q: Vector2 in [p + side, p, p - side]:
			verts.append(Vector3(q.x, hf.sample(q) + lift, q.y))
			normals.append(hf.sample_normal(q))
			uvs.append(Vector2(k * 0.5, v))
			k += 1
	for i in n - 1:
		var a := start + i * 3
		var b := a + 3
		for j in 2:
			GwMeshUtil.add_triangle(indices, verts, a + j, a + j + 1, b + j, Vector3.UP)
			GwMeshUtil.add_triangle(indices, verts, a + j + 1, b + j + 1, b + j, Vector3.UP)
