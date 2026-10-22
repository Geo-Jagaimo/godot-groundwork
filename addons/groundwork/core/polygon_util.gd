@tool
class_name GwPolygonUtil
extends RefCounted
## 2D polygon helpers: winding, and triangulation of polygons with holes.
##
## Holes are joined to the outline by "bridge" edges into one simple polygon,
## which Geometry2D.triangulate_polygon() (ear clipping) can handle. Pure and
## thread-safe.


## Shoelace area in the XZ plane; positive for counter-clockwise (x right, y up).
static func signed_area(ring: PackedVector2Array) -> float:
	var a := 0.0
	for i in ring.size():
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		a += p.x * q.y - q.x * p.y
	return a / 2.0


## [param ring] with positive (or, with [param positive] false, negative) area.
static func with_winding(ring: PackedVector2Array, positive: bool) -> PackedVector2Array:
	if (signed_area(ring) > 0.0) == positive:
		return ring
	var out := ring.duplicate()
	out.reverse()
	return out


## One simple polygon equal to [param outer] minus [param holes], joined by
## bridge edges (each bridge vertex appears twice). Holes that cannot be joined
## are left out.
static func bridge_holes(
	outer: PackedVector2Array, holes: Array[PackedVector2Array]
) -> PackedVector2Array:
	var merged := with_winding(outer, true)
	var pending: Array[PackedVector2Array] = []
	for h in holes:
		if h.size() >= 3:
			pending.append(with_winding(h, false))
	# Right-most holes first, so earlier bridges do not block later ones.
	pending.sort_custom(
		func(a: PackedVector2Array, b: PackedVector2Array) -> bool: return _max_x(a) > _max_x(b)
	)
	while not pending.is_empty():
		var hole: PackedVector2Array = pending.pop_front()
		var m := _index_of_max_x(hole)
		var target := _visible_vertex(merged, hole[m], pending, hole)
		if target < 0:
			continue
		var joined := PackedVector2Array()
		joined.append_array(merged.slice(0, target + 1))
		for k in hole.size() + 1:
			joined.append(hole[(m + k) % hole.size()])
		joined.append(merged[target])
		joined.append_array(merged.slice(target + 1))
		merged = joined
	return merged


## Triangulates [param outer] minus [param holes]. Returns {"points":
## PackedVector2Array, "indices": PackedInt32Array, "holes_dropped": bool}; if
## the holes make triangulation fail, the plain outline is used.
static func triangulate(outer: PackedVector2Array, holes: Array[PackedVector2Array]) -> Dictionary:
	if not holes.is_empty():
		var merged := bridge_holes(outer, holes)
		var tris := Geometry2D.triangulate_polygon(merged)
		if not tris.is_empty():
			return {"points": merged, "indices": tris, "holes_dropped": false}
	return {
		"points": outer,
		"indices": Geometry2D.triangulate_polygon(outer),
		"holes_dropped": not holes.is_empty(),
	}


## Index of the vertex of [param poly] closest to [param from] whose straight
## connection crosses no edge of [param poly], [param others] or [param hole];
## -1 if none.
static func _visible_vertex(
	poly: PackedVector2Array,
	from: Vector2,
	others: Array[PackedVector2Array],
	hole: PackedVector2Array
) -> int:
	var order: Array[int] = []
	for i in poly.size():
		order.append(i)
	order.sort_custom(
		func(a: int, b: int) -> bool:
			return from.distance_squared_to(poly[a]) < from.distance_squared_to(poly[b])
	)
	for i in order:
		var to := poly[i]
		if _crosses(from, to, poly) or _crosses(from, to, hole):
			continue
		var blocked := false
		for o in others:
			if _crosses(from, to, o):
				blocked = true
				break
		if not blocked:
			return i
	return -1


## Whether segment a-b crosses an edge of [param ring] other than at a or b.
static func _crosses(a: Vector2, b: Vector2, ring: PackedVector2Array) -> bool:
	for i in ring.size():
		var p := ring[i]
		var q := ring[(i + 1) % ring.size()]
		if (
			p.is_equal_approx(a)
			or p.is_equal_approx(b)
			or q.is_equal_approx(a)
			or q.is_equal_approx(b)
		):
			continue
		if Geometry2D.segment_intersects_segment(a, b, p, q) != null:
			return true
	return false


static func _index_of_max_x(ring: PackedVector2Array) -> int:
	var best := 0
	for i in ring.size():
		if ring[i].x > ring[best].x:
			best = i
	return best


static func _max_x(ring: PackedVector2Array) -> float:
	return ring[_index_of_max_x(ring)].x
