extends Area3D
## Placed on a ship's deck. Pressing the interact key while looking at this
## area hands helm control (throttle/rudder) to `ship`, and moves the player
## camera to `helm_marker` for the duration. It also turns the ship's wheel
## with the rudder: over while you hold a direction, back to centre when you let go.

@export var ship: Node
@export var helm_marker: Node3D
@export var highlight_mesh: Node3D # visual (eg. the wheel) to outline when targeted; every mesh under it glows. Defaults to the wheel.

@export_group("Wheel")
## The node the wheel turns around (its pivot). Defaults to the ship's `steering_hinge`.
@export var wheel: Node3D
## The wheel's axle, in the wheel node's own space.
@export var wheel_axis := Vector3.RIGHT
## How far the wheel turns at full rudder, each way.
@export_range(0.0, 1080.0, 1.0, "degrees") var wheel_max_angle: float = 180.0
## How fast it turns while you hold a direction (degrees/sec).
@export var wheel_turn_speed: float = 220.0
## How fast it drifts back to centre once you let go (degrees/sec).
@export var wheel_return_speed: float = 120.0
## Flip if the wheel turns the wrong way for the rudder.
@export var wheel_reversed: bool = false

var _wheel_rest: Basis
var _wheel_angle := 0.0 # degrees, positive = turning right (the ship's rudder)

func _ready() -> void:
	if wheel == null and ship:
		wheel = ship.find_child("steering_hinge", true, false) as Node3D
	if highlight_mesh == null:
		highlight_mesh = wheel
	if wheel:
		_wheel_rest = wheel.transform.basis

func interact(player: Node) -> void:
	if player.has_method(&'enter_pilot'):
		player.enter_pilot(ship, helm_marker)

## Look and feel: the "Interact highlight" group in res://assets/settings/game_settings.tres.
func set_highlighted(on: bool) -> void:
	GameSettings.set_highlight(highlight_mesh, on)

func _process(delta: float) -> void:
	if wheel == null or ship == null:
		return
	var rudder: float = ship.get(&'helm_rudder') if &'helm_rudder' in ship else 0.0
	var target := clampf(rudder, -1.0, 1.0) * wheel_max_angle
	# Hands on it: quick. Let go: the slower drift home.
	var turning := target != 0.0 and (signf(target) != signf(_wheel_angle) or absf(target) > absf(_wheel_angle))
	var speed := wheel_turn_speed if turning else wheel_return_speed
	var angle := move_toward(_wheel_angle, target, speed * delta)
	if angle == _wheel_angle:
		return
	_wheel_angle = angle
	# Seen by the helmsman, a right turn is clockwise.
	var turn := deg_to_rad(_wheel_angle) * (1.0 if wheel_reversed else -1.0)
	wheel.transform.basis = _wheel_rest * Basis(wheel_axis.normalized(), turn)
