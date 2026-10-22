extends SceneTree
## Runs one real import from the command line (network required).
##
## godot --headless --path . -s res://tools/smoke_import.gd -- \
##     --lat=35.3606 --lon=138.7274 --size=3000 --elevation=gsi_dem10b \
##     --imagery=gsi_seamlessphoto --name=fuji --resolution=10 \
##     [--buildings] [--roads] [--water] [--osm-file=<saved overpass.json>]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	var lat := float(args.get("lat", "35.3606"))
	var lon := float(args.get("lon", "138.7274"))
	var size := float(args.get("size", "3000"))

	var req := GwImportRequest.new()
	req.import_name = args.get("name", "smoke")
	req.output_dir = args.get("out", "res://geo/")
	req.bbox = GwGeoBBox.from_center_size(lat, lon, size, size)
	req.elevation_provider = GwProviderRegistry.find(args.get("elevation", "terrarium_aws"))
	var imagery: String = args.get("imagery", "")
	req.imagery_provider = GwProviderRegistry.find(imagery) if not imagery.is_empty() else null
	req.target_resolution_m = float(args.get("resolution", "10"))
	req.imagery_zoom_offset = int(args.get("zoom-offset", "2"))
	req.mesh_decimation = int(args.get("decimation", "1"))
	req.include_buildings = args.has("buildings")
	req.include_roads = args.has("roads")
	req.include_water = args.has("water")
	if args.has("osm-file"):
		# A saved Overpass response instead of a live query.
		var local := (GwProviderRegistry.find("overpass_main").duplicate()) as GwTileProvider
		local.url_template = args["osm-file"]
		req.osm_provider = local
		req.osm_use_fallbacks = false
	req.overwrite = true

	var plan := GwImportPlan.from_request(req)
	print("plan: ", plan.describe())
	for e in plan.errors:
		printerr("plan error: ", e)
	for w in plan.warnings:
		print("plan warning: ", w)

	var builder := GwWorldBuilder.new()
	var last := {"stage": ""}
	builder.progress.connect(
		func(stage: String, done: int, total: int) -> void:
			if stage != last["stage"] or (done == total and total > 0):
				print("  %s %d/%d" % [GwWorldBuilder.stage_label(stage), done, total])
				last["stage"] = stage
	)
	var result: GwImportResult = await builder.build(req)
	print("ok=%s code=%d %s" % [result.ok, result.error_code, result.error_message])
	print("scene: ", result.scene_path)
	print("stats: ", result.stats)
	for w in result.warnings:
		print("warning: ", w)
	quit(0 if result.ok else 1)
