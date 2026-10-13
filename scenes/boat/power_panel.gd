extends Node3D
## The ship's power panel. Pull the lever and "power_down" plays: the handle throws, sparks fly,
## and at that moment (the animation's method track calls switch_off) the whole ship goes dark
## and the engine dies -- the only way to hide from things drawn to a lit ship. Pull it again and
## "power_up" brings everything back. Pulls while the lever is still moving are ignored.
## What the power reaches is decided by the ship: see Boat.set_powered.

## The ship it switches. Left empty, the ship this panel is aboard.
@export var ship: Node

@onready var _anim: AnimationPlayer = $AnimationPlayer
@onready var _lever: Area3D = $power_panel/power_board/switch_board/switch_handle/Area3D
@onready var _switch_sound: AudioStreamPlayer3D = get_node_or_null(^'switch')
@onready var _sparkles_sound: AudioStreamPlayer3D = get_node_or_null(^'sparkles')
@onready var _engine_sound: AudioStreamPlayer3D = get_node_or_null(^'engine')

var on := true
var _moving := false

func _ready() -> void:
	add_to_group(&'off_grid') # its bulbs are the animation's to light, not the ship's
	if ship == null:
		ship = _find_ship()
	_lever.pulled.connect(_on_lever_pulled)
	_anim.animation_finished.connect(func(_anim_name: StringName) -> void: _moving = false)

func _on_lever_pulled(_player: Node) -> void:
	if _moving:
		return
	_moving = true
	_anim.play(&'power_down' if on else &'power_up')
	_play(_switch_sound)

## Called from the animations' method track, the moment the handle hits home.
func switch_on() -> void:
	_set_power(true)

func switch_off() -> void:
	_set_power(false)

func _set_power(power: bool) -> void:
	on = power
	_play(_sparkles_sound)
	_play(_engine_sound)
	if ship and ship.has_method(&'set_powered'):
		ship.set_powered(power)

## The nearest ancestor with a power switch.
func _find_ship() -> Node:
	var node := get_parent()
	while node:
		if node.has_method(&'set_powered'):
			return node
		node = node.get_parent()
	return null

func _play(sound: AudioStreamPlayer3D) -> void:
	if sound and sound.stream:
		sound.play()
