extends Node3D
## The navigation lock beside the wheel. Pulled (from the helm or on foot), it holds the ship's
## course full ahead with nobody steering, and lets the helmsman go. It lets go by itself when
## the furnace runs out, once she has stopped making way for stall_time seconds (aground, held
## fast), and when someone takes the wheel again or the lever is pulled back.

signal locked_changed(locked: bool)

@export var lock_angle: float = 30.0 # degrees
@export var unlock_angle: float = -30.0 # degrees
## The throttle she holds while locked.
@export_range(0.0, 1.0, 0.05) var cruise_throttle: float = 1.0
## Under this forward speed (m/s) she counts as stopped.
@export var stall_speed: float = 0.3
## Stopped this long (s) while locked, the lock lets go.
@export var stall_time: float = 5.0
## How long the lever takes to throw (s).
@export var throw_time: float = 0.45
## The ship it drives. Left empty, the boat this lock is part of.
@export var ship: RigidBody3D

@onready var navigation_handle: MeshInstance3D = $speed_control/navigation_shaft/navigation_handle
@onready var _interactable: Area3D = $speed_control/navigation_shaft/navigation_handle/interactable
@onready var _lock_sound: AudioStreamPlayer3D = get_node_or_null(^'LockSound')
@onready var _unlock_sound: AudioStreamPlayer3D = get_node_or_null(^'UnlockSound')

var locked := false
var _stalled_for := 0.0
var _tween: Tween

func _ready() -> void:
	if ship == null:
		ship = owner as RigidBody3D
	navigation_handle.rotation_degrees.z = unlock_angle
	if _interactable.has_signal(&'pulled'):
		_interactable.pulled.connect(_on_pulled)
	var bus := get_node_or_null(^'/root/EventBus')
	if bus: bus.day_started.connect(func(_day: int) -> void: lock_navigation(false))

func _on_pulled(player: Node) -> void:
	if not locked and player and player.get(&'piloted_ship') == ship and player.has_method(&'exit_pilot'):
		player.exit_pilot() # she steers herself now: the helmsman lets go of the wheel
	lock_navigation(not locked)

func lock_navigation(lock: bool = true):
	if lock == locked:
		return
	locked = lock
	_stalled_for = 0.0
	if ship and ship.has_method(&'set_cruise'):
		ship.set_cruise(cruise_throttle if lock else 0.0)
	# A heavy lever: it gives a little, swings over and settles just past the notch.
	if _tween: _tween.kill()
	_tween = create_tween().set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_BACK)
	_tween.tween_property(navigation_handle, ^'rotation_degrees:z', lock_angle if lock else unlock_angle, throw_time)
	var sound := _lock_sound if lock else _unlock_sound
	if sound and sound.stream:
		sound.play()
	locked_changed.emit(locked)

func _physics_process(delta: float) -> void:
	if not locked or ship == null:
		return
	if ship.get(&'piloted') == true:
		lock_navigation(false) # someone has the wheel again
		return
	if ship.get(&'engine_fuel_power') == 0.0:
		lock_navigation(false) # the furnace is out: nothing left to hold her course with
		return
	var forward := -ship.linear_velocity.dot(ship.global_basis.x) # her bow is -X (engine thrust, buoyant_cell.gd)
	_stalled_for = _stalled_for + delta if forward < stall_speed else 0.0
	if _stalled_for >= stall_time:
		lock_navigation(false)
