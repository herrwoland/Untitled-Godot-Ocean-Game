extends Node3D
## The cabin printer: the only voice that answers the deliveries. print_page()
## queues a sheet; it is printed once the player is in the cabin (inside the
## Area3D), feeding out of the slot with the print_paper animation. Once it has
## stopped, the sheet is an ordinary carryable (read it by holding it close,
## like the letter). Clockwork and its own lamps -- it prints with the ship's
## power off too.

const PLAYER_LAYER := 0b10 # the player body's collision layer
const FALL_CLEAR_TIME := 1.0 # seconds a sheet let go from the slot ignores the printer's body

@export var paper_scene: PackedScene = preload("res://scenes/boat/printed_paper.tscn")

@export_group("Debug")
## Prints a test page every debug_interval seconds (still waits for the player).
@export var debug_test_pages: bool = false
@export var debug_interval: float = 10.0

@onready var exit_point: Node3D = $paper_exit_point
@onready var animation: AnimationPlayer = $AnimationPlayer
@onready var presence: Area3D = get_node_or_null(^'Area3D') # no area = print at once

var _queue: Array[String] = [] # pages waiting for the player to come in
var _printing := false
var _in_slot: RigidBody3D = null # the last sheet, until someone takes it
var _pages: Array[RigidBody3D] = [] # every sheet ever printed; they stay aboard
var _debug_clock := 0.0
var _debug_count := 0

func _ready() -> void:
	add_to_group(&'printer')
	add_to_group(&'off_grid') # its lamps are the animation's to light, not the ship's
	EventBus.day_started.connect(_on_day_started)
	if presence:
		# Watch for the player only; never sit on a layer anything aboard collides with.
		presence.collision_layer = 0
		presence.collision_mask = PLAYER_LAYER
		presence.monitoring = true
		presence.body_entered.connect(func(_body: Node3D) -> void: _try_print())

func print_page(text: String) -> void:
	_queue.append(text)
	_try_print()

func _player_present() -> bool:
	if not presence:
		return true
	for body in presence.get_overlapping_bodies():
		if body.is_in_group(&'player'):
			return true
	return false

func _try_print() -> void:
	if _printing or _queue.is_empty() or not _player_present():
		return
	_printing = true
	await _print_now(_queue.pop_front())
	_printing = false
	_try_print() # anything else that arrived meanwhile

func _print_now(text: String) -> void:
	# A sheet nobody took slips out onto the floor to make room.
	if is_instance_valid(_in_slot) and _in_slot.get_parent() == exit_point:
		_let_fall(_in_slot)
	var page: RigidBody3D = paper_scene.instantiate()
	page.process_mode = Node.PROCESS_MODE_DISABLED # no hover or stowing while it feeds out
	page.continuous_cd = true # a sheet is thin enough to skip through the floor in one step
	page.ignore_player = true
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

func _process(delta: float) -> void:
	if debug_test_pages:
		_debug_clock += delta
		if _debug_clock >= debug_interval:
			_debug_clock = 0.0
			if _queue.is_empty(): # don't pile up test pages while nobody is aboard
				_debug_count += 1
				print_page("TEST PAGE %d\n\nTHE SEA IS CALM.\nTHE SEA IS NEVER CALM." % _debug_count)
	if is_instance_valid(_in_slot) and not _in_slot.carried and _in_slot.get_parent() == exit_point:
		_follow_slot()

## Taken from the slot: it belongs to the world now, like the letter (it
## rejoins the ship by itself once it is set down on her deck).
func _physics_process(_delta: float) -> void:
	if is_instance_valid(_in_slot) and _in_slot.carried:
		_in_slot.reparent(_world())
		_in_slot.top_level = false
		_in_slot = null

## A new (or repeated) morning: replies still waiting belong to a day that is
## gone. And the carry controller lets go of whatever was held without dropping
## it; a printout held overnight is found on the cabin floor.
func _on_day_started(_day: int) -> void:
	_queue.clear()
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
	# It leaves from inside the slot: let it fall clear of the printer's own body
	# first, or the solver flings the light sheet out of the box.
	var body: PhysicsBody3D = get_node_or_null(^'Collision')
	if body:
		page.add_collision_exception_with(body)
		var page_ref: WeakRef = weakref(page)
		get_tree().create_timer(FALL_CLEAR_TIME).timeout.connect(func() -> void:
			var still_here: RigidBody3D = page_ref.get_ref()
			if still_here and is_instance_valid(body):
				still_here.remove_collision_exception_with(body))
	page.on_dropped(ship.linear_velocity if ship else Vector3.ZERO)

func _world() -> Node:
	var ship := _ship()
	return ship.get_parent() if ship else get_tree().current_scene

func _ship() -> RigidBody3D:
	var node := get_parent()
	while node and not node is RigidBody3D:
		node = node.get_parent()
	return node
