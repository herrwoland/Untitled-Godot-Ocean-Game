extends Area3D
## A mounted light the player takes hold of, like a stationary gun in other games:
## the view moves to `view_camera` and looking around swings `hinge`, within narrow
## limits since it is bolted to the deck. Jump or interact (key) lets go again, and
## clicking switches the lamp on and off. Where it was left pointing is where it stays.
## Switching affects every light, UnderwaterGlow and glowing material under the hinge.

## The node that turns. Defaults to this area's parent (front_light_hinge).
@export var hinge: Node3D
## The view while operating. Should be a child of the hinge so it swings with it.
@export var view_camera: Camera3D
@export var highlight_mesh: Node3D # visual to outline when targeted; every mesh under it glows
## How far it swings left and right of where it was placed, each way.
@export_range(0.0, 180.0, 1.0, "degrees") var yaw_limit: float = 45.0
@export_range(0.0, 90.0, 1.0, "degrees") var pitch_up_limit: float = 25.0
@export_range(0.0, 90.0, 1.0, "degrees") var pitch_down_limit: float = 20.0
## Heavier than turning your head: scales the player's mouse sensitivity and key turn speed.
@export_range(0.1, 2.0, 0.05) var turn_weight: float = 0.6
## Whether the lamp is lit when the game starts.
@export var start_on: bool = true

@export_group("Sounds")
## Played once when switched on / off. Empty is fine.
@export var switch_on_sound: AudioStreamPlayer3D
@export var switch_off_sound: AudioStreamPlayer3D
## The grind of the mount while it swings. Give it a looping stream: it plays while the
## light is moving, louder and a touch higher the faster it turns, and fades out when it
## stops (or hits a limit). Its volume in the inspector is the loudest it gets.
@export var turn_sound: AudioStreamPlayer3D
## Turning this fast (degrees/sec) plays the turn sound at full volume.
@export var turn_sound_full_speed: float = 60.0
@export var turn_sound_pitch_range := Vector2(0.9, 1.1)

var _rest: Basis
var _yaw := 0.0 # radians, positive = left
var _pitch := 0.0 # radians, positive = up
var lit := true
var _glowing: Array[BaseMaterial3D] = [] # per-instance copies of the lamp's emissive materials
var _emission_energy: Array[float] = []
var _turned := 0.0 # radians moved since the last frame
var _turn_level := 0.0 # 0..1, smoothed, drives the turn sound
var _turn_full_db := 0.0

func _ready() -> void:
	if hinge == null:
		hinge = get_parent() as Node3D
	if view_camera == null and hinge:
		view_camera = hinge.find_children("*", "Camera3D", true, false).front() as Camera3D
	_rest = hinge.transform.basis
	# Its beam shows in the water around you when you dive (Water: light_beam_strength).
	for light in hinge.find_children("*", "Light3D", true, false):
		light.add_to_group(&'underwater_beam')
	_collect_glowing_materials()
	if turn_sound:
		_turn_full_db = turn_sound.volume_db
	set_lit(start_on, false)

func interact(player: Node) -> void:
	if player.has_method(&'enter_station'):
		player.enter_station(self)

## Called by the player when they take hold of / let go of the light.
func set_operated(on: bool, player_camera: Camera3D) -> void:
	if on:
		view_camera.make_current()
	elif is_instance_valid(player_camera):
		player_camera.make_current()

## Swings the light by the given angles (radians), clamped to its limits.
func aim(yaw_delta: float, pitch_delta: float) -> void:
	var yaw := clampf(_yaw + yaw_delta * turn_weight, -deg_to_rad(yaw_limit), deg_to_rad(yaw_limit))
	var pitch := clampf(_pitch + pitch_delta * turn_weight, -deg_to_rad(pitch_down_limit), deg_to_rad(pitch_up_limit))
	_turned += absf(yaw - _yaw) + absf(pitch - _pitch) # only real movement: silent against a stop
	_yaw = yaw
	_pitch = pitch
	# The light faces the hinge's +Z, so tipping it up is a negative turn about X.
	hinge.transform.basis = _rest * Basis.from_euler(Vector3(-_pitch, _yaw, 0.0))

## Look and feel: the "Interact highlight" group in res://assets/settings/game_settings.tres.
func set_highlighted(on: bool) -> void:
	GameSettings.set_highlight(highlight_mesh, on)

func toggle() -> void:
	set_lit(not lit)

func set_lit(on: bool, with_sound: bool = true) -> void:
	lit = on
	for node in hinge.find_children("*", "", true, false):
		if node is Light3D or node is UnderwaterGlow:
			node.visible = on
	for i in _glowing.size():
		_glowing[i].emission_energy_multiplier = _emission_energy[i] if on else 0.0
	var sound := switch_on_sound if on else switch_off_sound
	if with_sound and sound and sound.stream:
		sound.play()

## Gives every emissive surface under the hinge (the lamp glass) its own material copy, so
## switching this lamp off doesn't darken every other lamp sharing the imported material.
func _collect_glowing_materials() -> void:
	for mesh: MeshInstance3D in hinge.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null:
			continue
		for s in mesh.mesh.get_surface_count():
			var mat := mesh.get_active_material(s) as BaseMaterial3D
			if mat and mat.emission_enabled:
				mat = mat.duplicate()
				mesh.set_surface_override_material(s, mat)
				_glowing.append(mat)
				_emission_energy.append(mat.emission_energy_multiplier)

func _process(delta: float) -> void:
	if turn_sound == null or turn_sound.stream == null or delta <= 0.0:
		_turned = 0.0
		return
	var speed := rad_to_deg(_turned) / delta
	_turned = 0.0
	var target := clampf(speed / maxf(turn_sound_full_speed, 0.01), 0.0, 1.0)
	# Quick to start grinding, a little slower to die away.
	var rate := 20.0 if target > _turn_level else 8.0
	_turn_level = lerpf(_turn_level, target, 1.0 - exp(-rate * delta))
	if _turn_level < 0.01:
		if turn_sound.playing:
			turn_sound.stop()
		return
	turn_sound.volume_db = _turn_full_db + linear_to_db(_turn_level)
	turn_sound.pitch_scale = lerpf(turn_sound_pitch_range.x, turn_sound_pitch_range.y, _turn_level)
	if not turn_sound.playing:
		turn_sound.play()
