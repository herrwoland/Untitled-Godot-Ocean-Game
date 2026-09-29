extends Node
## Hold-to-inspect (Resident Evil / Gone Home style): the item lerps to a
## socket in front of the camera, the world dims, mouse drag rotates it and
## the wheel zooms. Carried items can be re-inspected any time with F,
## which also cycles between them.

const ROTATE_SENSITIVITY := 0.008
const ZOOM_STEP := 0.06
const ZOOM_NEAR := -0.28
const ZOOM_FAR := -0.9
const DEFAULT_ZOOM := -0.55

@export var player: CharacterBody3D
@export var camera: Camera3D
@export var socket: Node3D
@export var overlay: CanvasLayer
@export var item_label: Label

var carried: Array[Node3D] = []
var current: Node3D = null

var _cycle_index: int = 0
var _guard_msec: int = 0

func _ready() -> void:
	add_to_group(&'inspection_controller')

func begin_inspect(item: Node3D) -> void:
	if current == item:
		return
	if current:
		_put_away(current)
	current = item
	player.inspecting = true
	socket.position = Vector3(0, 0, DEFAULT_ZOOM)
	item.set_collision_active(false)
	if item.get_parent() != socket:
		item.reparent(socket)
	item.visible = true
	var tween := create_tween()
	tween.tween_property(item, "transform", Transform3D(Basis.IDENTITY, Vector3.ZERO), 0.25) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	overlay.visible = true
	item_label.text = item.item_name
	if item.carry_on_inspect and not carried.has(item):
		carried.append(item)
	item.notify_inspected()
	_guard_msec = Time.get_ticks_msec() + 250

func end_inspect() -> void:
	if not current:
		return
	_put_away(current)
	current = null
	player.inspecting = false
	overlay.visible = false
	# The closing press must not immediately re-trigger a world interaction.
	player.interact_cooldown_until_msec = Time.get_ticks_msec() + 250

func _put_away(item: Node3D) -> void:
	# Carried items simply vanish into your coat; they stay parented to the
	# socket, hidden, until re-inspected or restaged by a new morning.
	item.visible = false

## Delivery consumes the carried package.
func consume(item: Node3D) -> void:
	carried.erase(item)
	item.visible = false
	if current == item:
		end_inspect()

## New morning: nothing is carried anymore (the mission controller restages items).
func reset_day() -> void:
	if current:
		end_inspect()
	carried.clear()
	_cycle_index = 0

func _unhandled_input(event: InputEvent) -> void:
	if current:
		_inspect_input(event)
	elif event.is_action_pressed(&'inspect_carried') and not carried.is_empty() and player.state < 2: # not while piloting or at a station
		_cycle_index = _cycle_index % carried.size()
		begin_inspect(carried[_cycle_index])
		_cycle_index += 1

func _inspect_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# Trackball rotation in camera space (the socket is a camera child).
		var pitch := Basis(Vector3.RIGHT, -event.relative.y * ROTATE_SENSITIVITY)
		var yaw := Basis(Vector3.UP, -event.relative.x * ROTATE_SENSITIVITY)
		current.transform.basis = pitch * yaw * current.transform.basis
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			socket.position.z = minf(socket.position.z + ZOOM_STEP, ZOOM_NEAR)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			socket.position.z = maxf(socket.position.z - ZOOM_STEP, ZOOM_FAR)
	elif event.is_action_pressed(&'inspect_carried') and carried.size() > 1:
		_cycle_index = (carried.find(current) + 1) % carried.size()
		begin_inspect(carried[_cycle_index])
	elif event.is_action_pressed(&'interact') and Time.get_ticks_msec() > _guard_msec:
		end_inspect()
