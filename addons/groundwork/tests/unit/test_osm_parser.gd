extends GdUnitTestSuite

const LAT0 := 35.66
const LON0 := 139.70


static func _georef() -> GwGeoReference:
	return GwGeoReference.create(LAT0, LON0)


## Geometry for local XZ points (metres).
static func _geom(points: Array) -> Array:
	var g := _georef()
	var out := []
	for p: Vector2 in points:
		var ll := g.to_geo(Vector3(p.x, 0, p.y))
		out.append({"lat": ll[0], "lon": ll[1]})
	return out


static func _square(x: float, z: float, s: float) -> Array:
	return [
		Vector2(x, z), Vector2(x + s, z), Vector2(x + s, z + s), Vector2(x, z + s), Vector2(x, z)
	]


static func _fixture() -> Dictionary:
	var elements := [
		{
			"type": "way",
			"tags": {"building": "yes", "height": "12"},
			"geometry": _geom(_square(0, 0, 10))
		},
		{"type": "way", "tags": {"building": "no"}, "geometry": _geom(_square(50, 0, 10))},
		# Not closed: ignored.
		{
			"type": "way",
			"tags": {"building": "yes"},
			"geometry": _geom([Vector2(0, 0), Vector2(5, 0)])
		},
		# Multipolygon whose outer ring is split into two ways (one reversed),
		# plus an inner ring (courtyard).
		{
			"type": "relation",
			"tags": {"type": "multipolygon", "building": "office", "building:levels": "4"},
			"members":
			[
				{
					"type": "way",
					"role": "outer",
					"geometry": _geom([Vector2(100, 0), Vector2(120, 0), Vector2(120, 20)])
				},
				{
					"type": "way",
					"role": "outer",
					"geometry": _geom([Vector2(100, 0), Vector2(100, 20), Vector2(120, 20)])
				},
				{"type": "way", "role": "inner", "geometry": _geom(_square(105, 5, 5))},
			]
		},
		{
			"type": "way",
			"tags": {"highway": "residential"},
			"geometry": _geom([Vector2(0, 30), Vector2(100, 30)])
		},
		{
			"type": "way",
			"tags": {"highway": "footway", "tunnel": "yes"},
			"geometry": _geom([Vector2(0, 40), Vector2(10, 40)])
		},
		{
			"type": "way",
			"tags": {"highway": "proposed"},
			"geometry": _geom([Vector2(0, 50), Vector2(10, 50)])
		},
		{
			"type": "way",
			"tags": {"highway": "pedestrian", "area": "yes"},
			"geometry": _geom(_square(0, 60, 5))
		},
		{"type": "node", "lat": LAT0, "lon": LON0, "tags": {"highway": "bus_stop"}},
	]
	return {"version": 0.6, "elements": elements}


func test_buildings() -> void:
	var r := GwOsmParser.parse_data(_fixture(), _georef())
	assert_int(r.buildings.size()).is_equal(2)
	var first := r.buildings[0]
	# Closing point dropped; coordinates back in local metres.
	assert_int(first.ring.size()).is_equal(4)
	assert_vector(first.ring[2]).is_equal_approx(Vector2(10, 10), Vector2(1e-3, 1e-3))
	assert_str(first.tags["height"]).is_equal("12")
	var multi := r.buildings[1]
	assert_int(multi.ring.size()).is_equal(4)
	assert_str(multi.tags["building:levels"]).is_equal("4")
	assert_int(multi.holes.size()).is_equal(1)
	assert_int(first.holes.size()).is_equal(0)
	assert_int(r.broken_rings).is_equal(0)


func test_roads() -> void:
	var r := GwOsmParser.parse_data(_fixture(), _georef())
	assert_int(r.roads.size()).is_equal(1)
	assert_str(r.roads[0].highway).is_equal("residential")
	assert_float(r.roads[0].points[1].x).is_equal_approx(100.0, 1e-3)
	assert_int(r.skipped_roads).is_equal(3)


func test_parse_text_and_errors() -> void:
	var r := GwOsmParser.parse(JSON.stringify(_fixture()), _georef())
	assert_str(r.error).is_empty()
	assert_int(r.buildings.size()).is_equal(2)
	assert_str(GwOsmParser.parse("<html>", _georef()).error).is_not_empty()


func test_assemble_rings_reports_broken() -> void:
	var open: Array[PackedVector2Array] = [
		PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1)]),
	]
	var res := GwOsmParser.assemble_rings(open)
	assert_int(res["rings"].size()).is_equal(0)
	assert_int(res["broken"]).is_equal(1)


func test_is_road() -> void:
	assert_bool(GwOsmParser.is_road({"highway": "primary"})).is_true()
	assert_bool(GwOsmParser.is_road({"highway": "primary", "bridge": "yes"})).is_true()
	assert_bool(GwOsmParser.is_road({"highway": "service", "layer": "-1"})).is_false()
	assert_bool(GwOsmParser.is_road({"highway": "footway", "indoor": "yes"})).is_false()
	assert_bool(GwOsmParser.is_road({"highway": "construction"})).is_false()
