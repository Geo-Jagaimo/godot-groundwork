@tool
class_name GwOsmParser
extends RefCounted
## Turns an Overpass JSON response ([code]out geom[/code]) into building
## footprints and road centrelines in scene-local XZ coordinates.
##
## Multipolygons keep their inner rings as holes of the outer ring containing
## them. Pure and thread-safe.

## highway=* values that are not drivable / walkable lines.
const EXCLUDED_HIGHWAYS: Array[String] = [
	"proposed",
	"construction",
	"abandoned",
	"disused",
	"razed",
	"platform",
	"bus_stop",
	"elevator",
	"services",
	"rest_area",
	"emergency_access_point",
]
## waterway=* values drawn as lines (riverbanks are areas).
const WATER_LINES: Array[String] = ["river", "stream", "canal", "drain", "ditch"]
## Two ring end points closer than this (local units) are treated as the same node.
const JOIN_EPSILON := 0.01


class Building:
	## Outer ring, open (the closing point is not repeated).
	var ring := PackedVector2Array()
	## Inner rings (courtyards), open.
	var holes: Array[PackedVector2Array] = []
	var tags := {}


class Road:
	var points := PackedVector2Array()
	var highway := ""
	var tags := {}


class WaterArea:
	var ring := PackedVector2Array()
	var holes: Array[PackedVector2Array] = []
	var tags := {}


class WaterLine:
	var points := PackedVector2Array()
	var waterway := ""
	var tags := {}


class Result:
	var buildings: Array[Building] = []
	var roads: Array[Road] = []
	var water_areas: Array[WaterArea] = []
	var water_lines: Array[WaterLine] = []
	## Multipolygon outer rings that could not be closed.
	var broken_rings := 0
	var skipped_roads := 0
	var error := ""


static func parse(text: String, georef: GwGeoReference) -> Result:
	var data: Variant = null
	if text.strip_edges().begins_with("{"):
		data = JSON.parse_string(text)
	if not data is Dictionary or not (data as Dictionary).has("elements"):
		var r := Result.new()
		r.error = "Invalid Overpass response."
		return r
	return parse_data(data, georef)


static func parse_data(data: Dictionary, georef: GwGeoReference) -> Result:
	var r := Result.new()
	for e: Variant in data.get("elements", []):
		if not e is Dictionary:
			continue
		var el: Dictionary = e
		var tags: Dictionary = el.get("tags", {})
		var type: String = el.get("type", "")
		if type == "way" and tags.has("building") and tags["building"] != "no":
			var ring := _to_local(el.get("geometry", []), georef)
			if _is_closed(ring):
				ring.remove_at(ring.size() - 1)
				_add_building(r, ring, tags)
		elif type == "relation" and tags.has("building") and tags.get("type") == "multipolygon":
			var polys := multipolygon_rings(el, georef)
			r.broken_rings += polys["broken"]
			for poly: Dictionary in polys["polygons"]:
				_add_building(r, poly["outer"], tags, poly["holes"])
		elif type == "way" and is_water_area(tags):
			var ring := _to_local(el.get("geometry", []), georef)
			if _is_closed(ring):
				ring.remove_at(ring.size() - 1)
				_add_water(r, ring, tags, [])
		elif type == "relation" and is_water_area(tags) and tags.get("type") == "multipolygon":
			var polys := multipolygon_rings(el, georef)
			r.broken_rings += polys["broken"]
			for poly: Dictionary in polys["polygons"]:
				_add_water(r, poly["outer"], tags, poly["holes"])
		elif type == "way" and str(tags.get("waterway", "")) in WATER_LINES:
			if tags.get("tunnel", "no") in ["yes", "culvert"]:
				continue
			var line := WaterLine.new()
			line.points = _to_local(el.get("geometry", []), georef)
			line.waterway = tags["waterway"]
			line.tags = tags
			if line.points.size() >= 2:
				r.water_lines.append(line)
		elif type == "way" and tags.has("highway"):
			if not is_road(tags):
				r.skipped_roads += 1
				continue
			var road := Road.new()
			road.points = _to_local(el.get("geometry", []), georef)
			road.highway = tags["highway"]
			road.tags = tags
			if road.points.size() >= 2:
				r.roads.append(road)
	return r


## Lakes, ponds, reservoirs and river areas.
static func is_water_area(tags: Dictionary) -> bool:
	return (
		tags.get("natural") == "water"
		or tags.get("waterway") == "riverbank"
		or tags.get("landuse") in ["reservoir", "basin"]
	)


## Whether a highway=* way should become a road ribbon: tunnels, areas and
## indoor or underground ways are left out because they would be drawn on the
## terrain surface.
static func is_road(tags: Dictionary) -> bool:
	if str(tags.get("highway", "")) in EXCLUDED_HIGHWAYS:
		return false
	if tags.get("area") == "yes" or tags.get("indoor") == "yes":
		return false
	if tags.get("tunnel", "no") in ["yes", "culvert"]:
		return false
	var level := str(tags.get("level", "0"))
	if level.begins_with("-") or str(tags.get("layer", "0")).begins_with("-"):
		return false
	return true


## Joins open ways into closed rings by matching end points. Returns
## {"rings": Array[PackedVector2Array] (open), "broken": int}.
static func assemble_rings(segments: Array[PackedVector2Array]) -> Dictionary:
	var pool: Array[PackedVector2Array] = []
	for s in segments:
		if s.size() >= 2:
			pool.append(s)
	var rings: Array[PackedVector2Array] = []
	var broken := 0
	while not pool.is_empty():
		var ring: PackedVector2Array = pool.pop_back()
		while not _is_closed(ring):
			var found := false
			for i in pool.size():
				var s := pool[i]
				if _same(s[0], ring[ring.size() - 1]):
					ring.append_array(s.slice(1))
				elif _same(s[s.size() - 1], ring[ring.size() - 1]):
					var rev := s.duplicate()
					rev.reverse()
					ring.append_array(rev.slice(1))
				else:
					continue
				pool.remove_at(i)
				found = true
				break
			if not found:
				break
		if _is_closed(ring):
			ring.remove_at(ring.size() - 1)
			rings.append(ring)
		else:
			broken += 1
	return {"rings": rings, "broken": broken}


## Outer and inner rings of a multipolygon relation, each inner ring assigned to
## the outer ring containing it. Returns {"polygons": [{"outer":
## PackedVector2Array, "holes": Array[PackedVector2Array]}], "broken": int}.
static func multipolygon_rings(relation: Dictionary, georef: GwGeoReference) -> Dictionary:
	var outer_ways: Array[PackedVector2Array] = []
	var inner_ways: Array[PackedVector2Array] = []
	for m: Variant in relation.get("members", []):
		if not m is Dictionary or m.get("type") != "way":
			continue
		var line := _to_local(m.get("geometry", []), georef)
		if m.get("role", "") == "inner":
			inner_ways.append(line)
		elif m.get("role", "") in ["outer", ""]:
			outer_ways.append(line)
	var outers := assemble_rings(outer_ways)
	var inners := assemble_rings(inner_ways)
	var polygons := []
	for ring: PackedVector2Array in outers["rings"]:
		var holes: Array[PackedVector2Array] = []
		polygons.append({"outer": ring, "holes": holes})
	for hole: PackedVector2Array in inners["rings"]:
		for poly: Dictionary in polygons:
			if Geometry2D.is_point_in_polygon(hole[0], poly["outer"]):
				poly["holes"].append(hole)
				break
	return {"polygons": polygons, "broken": outers["broken"] + inners["broken"]}


static func _add_water(
	r: Result, ring: PackedVector2Array, tags: Dictionary, holes: Array[PackedVector2Array]
) -> void:
	if ring.size() < 3:
		return
	var w := WaterArea.new()
	w.ring = ring
	w.holes = holes
	w.tags = tags
	r.water_areas.append(w)


static func _add_building(
	r: Result, ring: PackedVector2Array, tags: Dictionary, holes: Array[PackedVector2Array] = []
) -> void:
	if ring.size() < 3:
		return
	var b := Building.new()
	b.ring = ring
	b.holes = holes
	b.tags = tags
	r.buildings.append(b)


static func _to_local(geometry: Variant, georef: GwGeoReference) -> PackedVector2Array:
	var out := PackedVector2Array()
	if not geometry is Array:
		return out
	for p: Variant in geometry:
		if p is Dictionary and p.has("lat") and p.has("lon"):
			var l := georef.to_local(float(p["lat"]), float(p["lon"]))
			out.append(Vector2(l.x, l.z))
	return out


static func _is_closed(ring: PackedVector2Array) -> bool:
	return ring.size() >= 4 and _same(ring[0], ring[ring.size() - 1])


static func _same(a: Vector2, b: Vector2) -> bool:
	return a.distance_squared_to(b) <= JOIN_EPSILON * JOIN_EPSILON
