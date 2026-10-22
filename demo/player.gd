extends CharacterBody3D
## Minimal first-person controller for walking around imported terrain.
## WASD: move, Mouse: look, Shift: run, Space: jump, F: toggle flying,
## Esc: release the mouse.

@export var walk_speed := 5.0
@export var run_speed := 14.0
@export var fly_speed := 120.0
@export var jump_velocity := 5.0
@export var mouse_sensitivity := 0.0025

var flying := false
var camera: Camera3D


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	shape.shape = capsule
	shape.position.y = 0.9
	add_child(shape)
	camera = Camera3D.new()
	camera.position.y = 1.65
	camera.far = 20000.0
	camera.near = 0.1
	add_child(camera)
	camera.make_current()
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(50.0)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * mouse_sensitivity)
		camera.rotate_x(-motion.relative.y * mouse_sensitivity)
		camera.rotation.x = clampf(camera.rotation.x, -1.5, 1.5)
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_F:
				flying = not flying


func _physics_process(delta: float) -> void:
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	)
	var running := Input.is_physical_key_pressed(KEY_SHIFT)
	if flying:
		var dir := camera.global_basis * Vector3(input.x, 0.0, input.y)
		if Input.is_physical_key_pressed(KEY_SPACE):
			dir.y += 1.0
		velocity = dir.normalized() * fly_speed * (3.0 if running else 1.0)
		move_and_slide()
		return
	var speed := run_speed if running else walk_speed
	var wish := global_basis * Vector3(input.x, 0.0, input.y)
	wish.y = 0.0
	wish = wish.normalized() * speed
	velocity.x = wish.x
	velocity.z = wish.z
	if is_on_floor():
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity
	else:
		velocity.y -= 9.8 * delta
	move_and_slide()
