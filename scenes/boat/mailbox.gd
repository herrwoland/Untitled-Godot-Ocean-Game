extends Node3D
## The cabin printer: the only voice that answers the deliveries. print_page()
## feeds a fresh sheet out of the slot with the print_paper animation; once it
## has stopped, the sheet is an ordinary carryable (read it by holding it
## close, like the letter). Clockwork and its own lamps -- it prints with the
## ship's power off too.

@export var paper_scene: PackedScene = preload("res://scenes/boat/printed_paper.tscn")

@onready var exit_point: Node3D = $paper_exit_point
@onready var animation: AnimationPlayer = $AnimationPlayer

var _in_slot: RigidBody3D = null # the last sheet, until someone takes it
var _pages: Array[RigidBody3D] = [] # every sheet ever printed; they stay aboard

func _ready() -> void:
	add_to_group(&'printer')
	add_to_group(&'off_grid') # its lamps are the animation's to light, not the ship's
	EventBus.day_started.connect(_on_day_started)

func print_page(text: String) -> void:
	# A sheet nobody took slips out onto the floor to make room.
	if is_instance_valid(_in_slot) and _in_slot.get_parent() == exit_point:
		_let_fall(_in_slot)
	var page: RigidBody3D = paper_scene.instantiate()
	page.process_mode = Node.PROCESS_MODE_DISABLED # no hover or stowing while it feeds out
	_fit_to_slot(page)
	exit_point.add_child(page)
	page.top_level = true # follows the slot unscaled (see _process)
	page.set_label_text(text)
	_in_slot = page
	_follow_slot()
	_pages.append(page)
	animation.stop()
	animation.play(&'print_paper')
	await animation.animation_finished
	if is_instance_valid(page):
		page.process_mode = Node.PROCESS_MODE_INHERIT

## The printer is modelled small and scaled up aboard, but a physics body must
## not be scaled: the sheet keeps a unit-scale body and grows its parts instead.
func _fit_to_slot(page: Node3D) -> void:
	var s := exit_point.global_basis.get_scale().x
	for child: Node3D in page.get_children():
		child.position *= s
		if child is CollisionShape3D:
			child.shape = child.shape.duplicate()
			child.shape.size *= s
		else:
			child.scale *= s

func _follow_slot() -> void:
	_in_slot.global_transform = exit_point.global_transform.orthonormalized()

func _process(_delta: float) -> void:
	if is_instance_valid(_in_slot) and not _in_slot.carried and _in_slot.get_parent() == exit_point:
		_follow_slot()

## Taken from the slot: it belongs to the world now, like the letter (it
## rejoins the ship by itself once it is set down on her deck).
func _physics_process(_delta: float) -> void:
	if is_instance_valid(_in_slot) and _in_slot.carried:
		_in_slot.reparent(_world())
		_in_slot.top_level = false
		_in_slot = null

## Overnight the carry controller lets go of whatever was held without dropping
## it; a printout held then is found on the cabin floor in the morning.
func _on_day_started(_day: int) -> void:
	for page in _pages:
		if is_instance_valid(page) and page.carried:
			page.global_transform = exit_point.global_transform
			_let_fall(page)

func _let_fall(page: RigidBody3D) -> void:
	var ship := _ship()
	if page.get_parent() != _world():
		page.reparent(_world())
	page.top_level = false
	page.process_mode = Node.PROCESS_MODE_INHERIT
	page.on_dropped(ship.linear_velocity if ship else Vector3.ZERO)

func _world() -> Node:
	var ship := _ship()
	return ship.get_parent() if ship else get_tree().current_scene

func _ship() -> RigidBody3D:
	var node := get_parent()
	while node and not node is RigidBody3D:
		node = node.get_parent()
	return node
