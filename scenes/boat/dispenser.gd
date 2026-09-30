extends Node3D
## The fuel dispenser. Pull the handle: it plays "open" and a fuel cell appears on the platform,
## riding up with it. It stays open until the handle is pulled again, then plays "close" and
## waits on stand-by. Pulls while it is still opening or closing are ignored.
##
## The new cell sits on the platform (frozen, moving with the boat) until the player takes it;
## from then on it belongs to the world. If the last one is still sitting there untouched, no
## second one is made, so repeated pulls never stack cells inside each other.

enum State { STANDBY, OPENING, OPEN, CLOSING }

@export var fuel_scene: PackedScene = preload("res://scenes/boat/fuel.tscn")

@onready var _anim: AnimationPlayer = $AnimationPlayer
@onready var _spawn_point: Node3D = $platform/fuel_spawn_point
@onready var _handle: Area3D = $handle_hinge/HandleInteractable
@onready var _open_sound: AudioStreamPlayer3D = get_node_or_null(^'OpenSound')
@onready var _close_sound: AudioStreamPlayer3D = get_node_or_null(^'CloseSound')

const CARRYABLE_WAITING_LAYER := 0b100 # interact only

var state := State.STANDBY
var _cell: Node3D = null # the cell waiting on the platform, until someone takes it

func _ready() -> void:
	_handle.pulled.connect(_on_handle_pulled)
	_anim.animation_finished.connect(_on_animation_finished)

func _on_handle_pulled(_player: Node) -> void:
	match state:
		State.STANDBY:
			state = State.OPENING
			_anim.play(&'open')
			_play(_open_sound)
			_spawn_cell()
		State.OPEN:
			state = State.CLOSING
			_anim.play(&'close')
			_play(_close_sound)

func _on_animation_finished(anim_name: StringName) -> void:
	if anim_name == &'open' and state == State.OPENING:
		state = State.OPEN
	elif anim_name == &'close' and state == State.CLOSING:
		state = State.STANDBY

func _spawn_cell() -> void:
	if is_instance_valid(_cell) and _cell.get_parent() == _spawn_point:
		return # the last one is still waiting here
	_cell = fuel_scene.instantiate()
	_spawn_point.add_child(_cell)
	_cell.transform = Transform3D.IDENTITY
	if _cell is RigidBody3D:
		_cell.freeze = true # rides on the platform (and the boat) until it is picked up
		# Aimable, but otherwise out of the physics: a frozen body the ship's own hull can't push
		# away, put back inside it every frame, throws the whole ship into the air. It rejoins
		# the world (carryable.on_dropped) once the player has taken it and puts it down.
		_cell.collision_layer = CARRYABLE_WAITING_LAYER
		_cell.collision_mask = 0

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_cell) or _cell.get_parent() != _spawn_point:
		return
	# Once taken, the cell leaves the dispenser for the world, and the next pull makes a fresh one.
	if _cell.get(&'carried') == true:
		_cell.reparent(_world_parent())
		_cell = null
		return
	# A frozen body keeps its place in the world when its parent moves, so hold it on the
	# platform by hand: up with the platform, and along with the boat.
	_cell.global_transform = _spawn_point.global_transform

## Where loose things live: beside the ship this dispenser sits on, or the scene itself.
func _world_parent() -> Node:
	var node: Node = self
	while node:
		if node is RigidBody3D and node.get_parent():
			return node.get_parent()
		node = node.get_parent()
	return get_tree().current_scene if get_tree().current_scene else get_tree().root

func _play(sound: AudioStreamPlayer3D) -> void:
	if sound and sound.stream:
		sound.play()
