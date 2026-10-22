extends Node3D
## Demo: loads a scene imported with the Geo dock and drops a first-person
## player at its centre.
##
## Import an area named "demo" into res://geo/ (the default output folder),
## or point [member terrain_scene] at another import, then run the project.

const Player := preload("res://demo/player.gd")

@export_file("*.tscn") var terrain_scene := "res://geo/demo/demo.tscn"


func _ready() -> void:
	add_environment(self)
	if not ResourceLoader.exists(terrain_scene):
		_show_message(
			(
				"No imported scene at %s.\n\n" % terrain_scene
				+ 'Open the Geo dock, Shift+drag an area, name it "demo" and press Import.'
			)
		)
		return
	var terrain := (load(terrain_scene) as PackedScene).instantiate()
	add_child(terrain)
	var player := Player.new()
	player.name = "Player"
	var spawn := Vector3.ZERO
	if terrain is GwSceneRoot:
		var root := terrain as GwSceneRoot
		spawn.y = root.sample_elevation(Vector2.ZERO)
		var geo := root.local_to_geo(spawn)
		print("Spawned at %.5f, %.5f (%.0f m)" % [geo[0], geo[1], spawn.y])
	player.position = spawn + Vector3.UP * 2.0
	add_child(player)


## Sky, light and fog; also used by the runtime demo.
static func add_environment(parent: Node) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_density = 0.00005
	env.fog_aerial_perspective = 0.6
	var world := WorldEnvironment.new()
	world.environment = env
	parent.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, -50, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600.0
	parent.add_child(sun)


func _show_message(text: String) -> void:
	var layer := CanvasLayer.new()
	var label := Label.new()
	label.text = text
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.grow_vertical = Control.GROW_DIRECTION_BOTH
	layer.add_child(label)
	add_child(layer)
