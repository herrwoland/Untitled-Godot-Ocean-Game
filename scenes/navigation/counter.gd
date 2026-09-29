extends Node3D
## Mechanical five-cylinder coordinate counter. Rolls like an odometer:
## the ones cylinder turns to each new number, and a higher cylinder only
## turns while every cylinder below it passes from 9 to 0.

const CoordinateSystem := preload("res://assets/scripts/core/coordinate_system.gd")

enum Axis { FROM_NAME, NORTH, WEST, NONE }

## Which coordinate this counter follows. FROM_NAME: a node named with "W"
## (like counter_W) shows west, anything else north. NONE: only
## display_number() moves it.
@export var axis := Axis.FROM_NAME
## How quickly the cylinders catch up with a new number (higher = snappier).
@export var roll_speed := 6.0

@onready var number_0: Node3D = $number_0
@onready var number_1: Node3D = $number_1
@onready var number_2: Node3D = $number_2
@onready var number_3: Node3D = $number_3
@onready var number_4: Node3D = $number_4
@onready var N: Sprite3D = $N
@onready var W: Sprite3D = $W

@onready var _cylinders: Array[Node3D] = [number_0, number_1, number_2, number_3, number_4]

const MAX_VALUE := 99999.0

var _target := 0.0
var _shown := -1.0  # value the cylinders currently show; -1 = never set

func _ready() -> void:
	if axis == Axis.FROM_NAME:
		axis = Axis.WEST if name.contains("W") else Axis.NORTH
	if axis != Axis.NONE:
		_set_letter(axis == Axis.NORTH)
		_track(true)

func display_number(the_number: int, north: bool = true) -> void:
	_set_letter(north)
	_target = clampf(the_number, 0.0, MAX_VALUE)
	if _shown < 0.0:
		_apply(_target)

func _process(delta: float) -> void:
	if axis == Axis.NORTH or axis == Axis.WEST:
		_track(false)
	if _shown == _target:
		return
	var next := lerpf(_shown, _target, 1.0 - exp(-roll_speed * delta))
	if absf(_target - next) < 0.002:
		next = _target
	_apply(next)

func _track(snap: bool) -> void:
	var c := CoordinateSystem.coordinates(global_position)
	_target = clampf(roundf(c.x if axis == Axis.NORTH else c.y), 0.0, MAX_VALUE)
	if snap:
		_apply(_target)

func _set_letter(north: bool) -> void:
	N.visible = north
	W.visible = not north

## Odometer layout for a (possibly fractional) value.
func _apply(value: float) -> void:
	_shown = value
	var place := 1.0
	for cylinder in _cylinders:
		var digit := fmod(floorf(value / place), 10.0)
		var below := fmod(value, place)  # what the lower cylinders show
		var carry := value - floorf(value) if place == 1.0 else clampf(below - (place - 1.0), 0.0, 1.0)
		cylinder.change(digit + carry)
		place *= 10.0
