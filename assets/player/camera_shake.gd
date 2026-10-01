class_name CameraShake extends Node
## Trauma-based camera shake for jolts and rumbles (after Squirrel Eiserloh's
## "Math for Game Programmers: Juicing Your Cameras With Math").
##
## Anything asks for a shake through the EventBus, never by reaching for the
## camera:   EventBus.camera_shake_requested.emit(0.5)
## The value is a floor: trauma rises to AT LEAST that, then drains at `decay`
## per second. So one emit is a jolt that dies away on its own, and emitting
## every frame holds a steady rumble that fades once the emits stop.
##
## Rotation only, never position: the eye stays exactly where it is, so the
## waterline and underwater checks keep their cm accuracy. The rotation lives
## on a ShakePivot node this inserts between the camera and its parent at
## start-up (it does not exist in the saved scene) — the shake owns that node
## outright, so mouse look, the wave roll and the drowning tilt all keep
## writing the camera's own rotation and never fight it.
## Global strength (0 = off) is GameSettings.camera_shake_strength.

@export var camera: Camera3D
## Trauma lost per second: 1.5 lets a full-strength jolt ring for ~0.7 s.
@export var decay := 1.5
## Shake = trauma ^ exponent. 2 keeps light trauma subtle and lets heavy trauma
## hit hard, instead of every shake feeling the same.
@export_range(1.0, 4.0, 0.1) var exponent := 2.0
## Largest swing at full trauma, in degrees.
@export var max_yaw := 3.0
@export var max_pitch := 3.0
@export var max_roll := 5.0
## How fast the jitter wanders (roughly swings per second).
@export var frequency := 18.0

var trauma := 0.0

var _pivot: Node3D
var _noise := FastNoiseLite.new()
var _time := 0.0

func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0
	_noise.seed = randi()
	EventBus.camera_shake_requested.connect(shake)
	set_process(false)
	_insert_pivot.call_deferred() # after every sibling has cached its camera references

## Raise trauma to at least `amount` (0..1). Call once for a jolt, every frame
## for a sustained rumble.
func shake(amount: float) -> void:
	amount *= GameSettings.current().camera_shake_strength
	if amount <= trauma or _pivot == null:
		return
	trauma = minf(amount, 1.0)
	set_process(true)

func _process(delta: float) -> void:
	trauma = maxf(trauma - decay * delta, 0.0)
	if trauma <= 0.0:
		_pivot.rotation = Vector3.ZERO
		set_process(false)
		return
	_time += delta
	var amount := pow(trauma, exponent)
	var t := _time * frequency
	# Three far-apart slices of one noise field: smooth, unrelated wobbles.
	_pivot.rotation = Vector3(
		deg_to_rad(max_pitch) * amount * _noise.get_noise_1d(t),
		deg_to_rad(max_yaw) * amount * _noise.get_noise_1d(t + 1000.0),
		deg_to_rad(max_roll) * amount * _noise.get_noise_1d(t + 2000.0))

## Slip a pivot in above the camera, sitting exactly at the eye, so its
## rotation turns the view about the eye without moving it.
func _insert_pivot() -> void:
	if camera == null:
		push_warning("CameraShake: no camera set.")
		return
	var parent := camera.get_parent()
	_pivot = Node3D.new()
	_pivot.name = &'ShakePivot'
	parent.add_child(_pivot)
	parent.move_child(_pivot, camera.get_index())
	_pivot.position = camera.position
	camera.reparent(_pivot) # keeps the camera's world transform
