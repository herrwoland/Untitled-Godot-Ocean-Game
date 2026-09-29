extends Area3D
## A mounted light the player takes hold of, like a stationary gun in other games:
## the view moves to `view_camera` and looking around swings `hinge`, within narrow
## limits since it is bolted to the deck. Jump or interact (key) lets go again.
## Where the hinge was left pointing is where the light stays.

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

var highlight_material := preload("res://assets/scripts/interact_highlight_material.tres")

var _rest: Basis
var _yaw := 0.0 # radians, positive = left
var _pitch := 0.0 # radians, positive = up

func _ready() -> void:
	if hinge == null:
		hinge = get_parent() as Node3D
	if view_camera == null and hinge:
		view_camera = hinge.find_children("*", "Camera3D", true, false).front() as Camera3D
	_rest = hinge.transform.basis

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
	_yaw = clampf(_yaw + yaw_delta * turn_weight, -deg_to_rad(yaw_limit), deg_to_rad(yaw_limit))
	_pitch = clampf(_pitch + pitch_delta * turn_weight, -deg_to_rad(pitch_down_limit), deg_to_rad(pitch_up_limit))
	# The light faces the hinge's +Z, so tipping it up is a negative turn about X.
	hinge.transform.basis = _rest * Basis.from_euler(Vector3(-_pitch, _yaw, 0.0))

## Overlays every MeshInstance3D at or below highlight_mesh, so it works both
## on a single mesh and on an imported model with its own subtree.
func set_highlighted(on: bool) -> void:
	if highlight_mesh == null:
		return
	var meshes := highlight_mesh.find_children("*", "MeshInstance3D", true, false)
	if highlight_mesh is MeshInstance3D:
		meshes.append(highlight_mesh)
	for m in meshes:
		m.material_overlay = highlight_material if on else null
