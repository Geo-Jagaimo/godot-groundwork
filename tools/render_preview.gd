extends SceneTree
## Renders a generated scene to a PNG (needs a window; not --headless).
##
## godot --path . -s res://tools/render_preview.gd -- --scene=res://geo/fuji/fuji.tscn \
##     --out=/tmp/preview.png [--yaw=30] [--pitch=-25] [--distance=1.2 | --meters=300]
##     [--at=lat,lon] [--only-lod=<level>]


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	root.size = Vector2i(int(args.get("width", "1280")), int(args.get("height", "720")))
	var scene := (load(args.get("scene", "res://geo/fuji/fuji.tscn")) as PackedScene).instantiate()
	root.add_child(scene)
	if args.has("only-lod"):
		# Show a single terrain LOD level everywhere (0 = full detail).
		var level := int(args["only-lod"])
		for mi: GeometryInstance3D in scene.find_children("*", "GeometryInstance3D", true, false):
			var lod := 0
			if mi.name.begins_with("Lod"):
				lod = int(mi.name.trim_prefix("Lod"))
			elif not mi.name.begins_with("Chunk"):
				continue
			mi.visibility_range_begin = 0.0
			mi.visibility_range_end = 0.0
			mi.transparency = 0.0 if lod == level else 1.0

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	var sky := ProceduralSkyMaterial.new()
	sky.ground_horizon_color = sky.sky_horizon_color
	sky.ground_bottom_color = sky.sky_horizon_color
	env.environment.sky.sky_material = sky
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment.fog_enabled = args.get("fog", "false") == "true"
	env.environment.fog_density = 0.00008
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -60, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 8000.0
	root.add_child(sun)

	var hf: GwHeightfield = scene.heightfield
	var extent := hf.get_extent()
	var center := hf.origin + extent / 2.0
	var target := Vector3(center.x, hf.sample(center), center.y)
	if args.has("at"):
		var ll: PackedStringArray = args["at"].split(",")
		target = scene.geo_to_local(ll[0].to_float(), ll[1].to_float())
	var yaw := deg_to_rad(float(args.get("yaw", "30")))
	var pitch := deg_to_rad(float(args.get("pitch", "-28")))
	var dist := maxf(extent.x, extent.y) * float(args.get("distance", "0.9"))
	if args.has("meters"):
		dist = float(args["meters"])
	var cam := Camera3D.new()
	cam.far = dist * 4.0
	cam.near = 1.0
	cam.fov = 60.0
	root.add_child(cam)
	var dir := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
	cam.look_at_from_position(target + dir * dist, target)
	cam.make_current()

	for i in 20:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var out: String = args.get("out", "user://preview.png")
	img.save_png(out)
	print("saved ", out)
	quit()
