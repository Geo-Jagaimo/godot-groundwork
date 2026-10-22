@tool
class_name GwImportPlan
extends RefCounted
## Everything derived from a [GwImportRequest] before anything is downloaded:
## zoom levels, tile ranges, grid sizes, estimates and validation.
## Cheap to compute, so the editor recomputes it on every change.

const WARN_EXTENT_M := 20000.0
const MAX_EXTENT_M := 50000.0
const WARN_LATITUDE := 60.0
const WARN_TRIANGLES := 10000000
## Largest area for one OpenStreetMap (Overpass) query.
const MAX_OSM_AREA_KM2 := 25.0
## Hard limit on heightfield samples per side (memory guard).
const MAX_GRID_SIDE := 16384

var request: GwImportRequest
var errors := PackedStringArray()
var warnings := PackedStringArray()

var origin_lat := 0.0
var origin_lon := 0.0
var scale_k := 1.0
var width_m := 0.0
var height_m := 0.0

var elevation_zoom := 0
## Elevation tiles as Rect2i(x_min, y_min, cols, rows).
var elevation_tiles := Rect2i()
## Heightfield samples per side after decimation.
var grid_width := 0
var grid_height := 0
var decimation := 1
## Heightfield spacing after decimation, in approximate metres.
var cell_size_m := 0.0
## Local XZ of heightfield sample (0, 0).
var grid_origin := Vector2.ZERO

var imagery_zoom := -1
var imagery_tiles := Rect2i()
var chunks := Vector2i.ZERO
var triangle_count := 0
var estimated_download_bytes := 0


static func from_request(req: GwImportRequest, api_keys: Dictionary = {}) -> GwImportPlan:
	var plan := GwImportPlan.new()
	plan.request = req
	plan._compute(api_keys)
	return plan


func is_valid() -> bool:
	return errors.is_empty()


func elevation_tile_list() -> Array[Vector3i]:
	return GwTileMath.tiles_in_range(elevation_tiles, elevation_zoom)


func imagery_tile_list() -> Array[Vector3i]:
	if imagery_zoom < 0:
		return []
	return GwTileMath.tiles_in_range(imagery_tiles, imagery_zoom)


## Overpass endpoints to try, in order.
func osm_endpoints() -> Array[GwTileProvider]:
	var out: Array[GwTileProvider] = []
	if request.osm_provider != null:
		out.append(request.osm_provider)
	if request.osm_provider == null or request.osm_use_fallbacks:
		for p in GwProviderRegistry.list_providers(GwTileProvider.Kind.VECTOR):
			if out.all(func(q: GwTileProvider) -> bool: return q.id != p.id):
				out.append(p)
	return out


func imagery_zoom_scale() -> float:
	return pow(2.0, imagery_zoom - elevation_zoom) if imagery_zoom >= 0 else 0.0


func chunk_count() -> int:
	return chunks.x * chunks.y


func create_geo_reference() -> GwGeoReference:
	var g := GwGeoReference.create(origin_lat, origin_lon)
	g.set_bbox(request.bbox)
	g.elevation_zoom = elevation_zoom
	g.cell_size_m = cell_size_m
	return g


## Heightfield samples (before decimation) that lie inside the selected area.
func bbox_samples() -> Rect2i:
	var g := create_geo_reference()
	var nw := g.to_local(request.bbox.north, request.bbox.west)
	var se := g.to_local(request.bbox.south, request.bbox.east)
	var raw_cell := cell_size_m / decimation
	var c0 := floori((nw.x - grid_origin.x) / raw_cell)
	var r0 := floori((nw.z - grid_origin.y) / raw_cell)
	var c1 := ceili((se.x - grid_origin.x) / raw_cell)
	var r1 := ceili((se.z - grid_origin.y) / raw_cell)
	return Rect2i(c0, r0, c1 - c0 + 1, r1 - r0 + 1)


func create_compositor() -> GwImageryCompositor:
	return GwImageryCompositor.create(elevation_tiles.position, imagery_zoom_scale(), decimation)


## Human-readable one-line summary for the editor.
func describe() -> String:
	if request == null or request.bbox == null:
		return ""
	var parts := PackedStringArray()
	parts.append("elevation z%d: %d tiles" % [elevation_zoom, elevation_tiles.get_area()])
	if imagery_zoom >= 0:
		parts.append("imagery z%d: %d tiles" % [imagery_zoom, imagery_tiles.get_area()])
	if request.includes_osm():
		var what := PackedStringArray()
		if request.include_buildings:
			what.append("buildings")
		if request.include_roads:
			what.append("roads")
		parts.append("OSM %s" % " + ".join(what))
	parts.append("%d chunks" % chunk_count())
	parts.append("%s triangles" % _si(triangle_count))
	var mb := estimated_download_bytes / 1.0e6
	parts.append(("~%.1f MB download" if mb < 10.0 else "~%.0f MB download") % mb)
	return " / ".join(parts)


func _compute(api_keys: Dictionary) -> void:
	var req := request
	if req.bbox == null or not req.bbox.is_valid():
		errors.append("Select an area first.")
		return
	if req.elevation_provider == null:
		errors.append("Choose an elevation provider.")
		return
	if req.elevation_provider.create_decoder() == null:
		errors.append(
			"Provider '%s' has no elevation decoder." % req.elevation_provider.get_label()
		)
		return
	if req.import_name.strip_edges().is_empty() or not req.import_name.is_valid_filename():
		errors.append("Name must be a valid file name.")
	if not req.output_dir.begins_with("res://"):
		errors.append("Output folder must be inside the project (res://).")
	if req.chunk_size < 16 or req.chunk_size > 512:
		errors.append("Chunk size must be between 16 and 512.")
		return

	var bbox := req.bbox
	origin_lat = bbox.center_lat()
	origin_lon = bbox.center_lon()
	scale_k = cos(deg_to_rad(origin_lat))
	width_m = bbox.width_m()
	height_m = bbox.height_m()
	var extent := maxf(width_m, height_m)
	if extent > MAX_EXTENT_M:
		errors.append(
			(
				"Area is %.1f km across; the limit is %.0f km. Split it into smaller imports."
				% [extent / 1000.0, MAX_EXTENT_M / 1000.0]
			)
		)
	elif extent > WARN_EXTENT_M:
		warnings.append(
			(
				"Area is %.1f km across: generation will be slow and mercator scale error grows."
				% (extent / 1000.0)
			)
		)
	if absf(origin_lat) > WARN_LATITUDE:
		warnings.append(
			"Latitude above %d°: Web Mercator distortion becomes noticeable." % WARN_LATITUDE
		)

	var ep := req.elevation_provider
	_check_provider(ep, api_keys)
	elevation_zoom = GwTileMath.resolution_to_zoom(
		req.target_resolution_m, origin_lat, ep.min_zoom, ep.max_zoom
	)
	elevation_tiles = GwTileMath.tile_range(bbox, elevation_zoom)
	decimation = clampi(req.mesh_decimation, 1, 4)
	var raw_w := elevation_tiles.size.x * GwTileMath.TILE_SIZE
	var raw_h := elevation_tiles.size.y * GwTileMath.TILE_SIZE
	# Same sizes as GwHeightfield.decimated().
	grid_width = ceili((raw_w - 1) / float(decimation)) + 1
	grid_height = ceili((raw_h - 1) / float(decimation)) + 1
	var raw_cell := GwTileMath.mercator_pixel_size(elevation_zoom) * scale_k
	cell_size_m = raw_cell * decimation
	if absf(raw_cell - req.target_resolution_m) / req.target_resolution_m > 0.6:
		warnings.append(
			(
				"%s offers %.1f m cells here (requested %.1f m)."
				% [ep.get_label(), raw_cell, req.target_resolution_m]
			)
		)
	if maxi(raw_w, raw_h) > MAX_GRID_SIDE:
		errors.append("Too many samples (%d x %d). Use a coarser resolution." % [raw_w, raw_h])

	# Local position of sample (0, 0): pixel centre of the first tile's corner.
	var origin_px_x := GwTileMath.lon_to_tile_x(origin_lon, elevation_zoom) * GwTileMath.TILE_SIZE
	var origin_px_y := GwTileMath.lat_to_tile_y(origin_lat, elevation_zoom) * GwTileMath.TILE_SIZE
	var first_px_x := elevation_tiles.position.x * GwTileMath.TILE_SIZE + 0.5
	var first_px_y := elevation_tiles.position.y * GwTileMath.TILE_SIZE + 0.5
	grid_origin = Vector2(
		(first_px_x - origin_px_x) * raw_cell, (first_px_y - origin_px_y) * raw_cell
	)

	var cells_x := grid_width - 1
	var cells_z := grid_height - 1
	chunks = Vector2i(
		ceili(cells_x / float(req.chunk_size)), ceili(cells_z / float(req.chunk_size))
	)
	triangle_count = 2 * cells_x * cells_z
	if triangle_count > WARN_TRIANGLES:
		warnings.append(
			(
				"About %s triangles: consider a coarser resolution or mesh decimation."
				% _si(triangle_count)
			)
		)
	estimated_download_bytes = int(elevation_tiles.get_area() * ep.avg_tile_kb * 1024.0)

	var ip := req.imagery_provider
	if ip != null:
		_check_provider(ip, api_keys)
		imagery_zoom = clampi(elevation_zoom + req.imagery_zoom_offset, ip.min_zoom, ip.max_zoom)
		if imagery_zoom < elevation_zoom:
			warnings.append(
				(
					"%s only goes up to zoom %d; imagery will be blurry."
					% [ip.get_label(), ip.max_zoom]
				)
			)
		var compositor := create_compositor()
		imagery_tiles = compositor.tile_range(Rect2i(0, 0, cells_x, cells_z))
		estimated_download_bytes += int(imagery_tiles.get_area() * ip.avg_tile_kb * 1024.0)
		var tex_side := req.chunk_size * compositor.px_per_cell
		if tex_side > compositor.max_texture_size:
			warnings.append(
				(
					"Chunk textures would be %d px; they will be downscaled to %d px."
					% [tex_side, compositor.max_texture_size]
				)
			)

	if req.includes_osm():
		_check_osm()


func _check_osm() -> void:
	var area := request.bbox.area_km2()
	if area > MAX_OSM_AREA_KM2:
		var limit := (
			"Buildings and roads are limited to %.0f km² (selected: %.1f km²)."
			% [MAX_OSM_AREA_KM2, area]
		)
		errors.append(limit + " Select a smaller area or turn them off.")
	if osm_endpoints().is_empty():
		errors.append("No Overpass endpoint available for buildings and roads.")


func _check_provider(provider: GwTileProvider, api_keys: Dictionary) -> void:
	var bbox := request.bbox
	if provider.has_coverage_limit():
		var cov := provider.get_coverage()
		if not cov.intersects(bbox):
			errors.append("%s does not cover the selected area." % provider.get_label())
		elif not cov.contains_bbox(bbox):
			warnings.append(
				(
					"Part of the area is outside %s coverage; gaps will be filled."
					% provider.get_label()
				)
			)
	if provider.requires_api_key and str(api_keys.get(provider.id, "")).is_empty():
		errors.append(
			(
				"%s needs an API key: set Editor Settings > groundwork/api_keys/%s."
				% [provider.get_label(), provider.id]
			)
		)


static func _si(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (n / 1.0e6)
	if n >= 1000:
		return "%.0fk" % (n / 1.0e3)
	return str(n)
