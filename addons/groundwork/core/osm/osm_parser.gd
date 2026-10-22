@tool
class_name GwOsmParser
extends RefCounted
## Turns an Overpass JSON response ([code]out geom[/code]) into building
## footprints and road centrelines in scene-local XZ coordinates.
##
## Multipolygon buildings keep only their outer rings (holes come in v0.3).
## Pure and thread-safe.

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
## Two ring end points closer than this (local units) are treated as the same node.
const JOIN_EPSILON := 0.01


class Building:
	## Outer ring, open (the closing point is not repeated).
	var ring := PackedVector2Array()
	var tags := {}


class Road:
	var points := PackedVector2Array()
	var highway := ""
	var tags := {}


class Result:
	var buildings: Array[Building] = []
	var roads: Array[Road] = []
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
			var outers: Array[PackedVector2Array] = []
			for m: Variant in el.get("members", []):
				if (
					m is Dictionary
					and m.get("type") == "way"
					and m.get("role", "") in ["outer", ""]
				):
					outers.append(_to_local(m.get("geometry", []), georef))
			var rings := assemble_rings(outers)
			r.broken_rings += rings["broken"]
			for ring: PackedVector2Array in rings["rings"]:
				_add_building(r, ring, tags)
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


static func _add_building(r: Result, ring: PackedVector2Array, tags: Dictionary) -> void:
	if ring.size() < 3:
		return
	var b := Building.new()
	b.ring = ring
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
