extends Node3D
## Runtime demo: downloads a real place while the game runs (network required)
## with GwTerrainLoader, then drops a first-person player on it.

const Player := preload("res://demo/player.gd")
const Main := preload("res://demo/main.gd")

@export var latitude := 35.3606
@export var longitude := 138.7274
@export var size_m := 2000.0
@export var elevation_provider := "terrarium_aws"
@export var imagery_provider := ""

var _status: Label


func _ready() -> void:
	Main.add_environment(self)
	_status = Label.new()
	_status.position = Vector2(16, 16)
	var layer := CanvasLayer.new()
	layer.add_child(_status)
	add_child(layer)

	var loader := GwTerrainLoader.new()
	loader.request = GwTerrainLoader.request_around(
		latitude, longitude, size_m, elevation_provider, imagery_provider
	)
	loader.progress.connect(
		func(stage: String, done: int, total: int) -> void:
			_status.text = "%s %d/%d" % [GwWorldBuilder.stage_label(stage), done, total]
	)
	add_child(loader)
	var result: GwImportResult = await loader.build()
	if not result.ok:
		_status.text = "Could not load the terrain: %s" % result.error_message
		return
	_status.text = ""
	var root := loader.scene_root
	var player := Player.new()
	player.name = "Player"
	player.position = Vector3(0, root.sample_elevation(Vector2.ZERO) + 2.0, 0)
	add_child(player)
