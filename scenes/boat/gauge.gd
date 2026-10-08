extends Node3D
## The furnace's dial gauge: the hand follows the furnace's fuel, sweeping from rot_min (empty)
## to rot_max (full), and trembles a little like the needle of an old barometer.

## The furnace to read. Left empty, it is found by name inside the boat.
@export var furnace: Node
## How far (degrees) the hand trembles either way.
@export_range(0.0, 10.0, 0.1) var jitter_amount: float = 1.2
## How quickly the tremble wanders.
@export_range(0.1, 30.0, 0.1) var jitter_speed: float = 9.0
## How quickly the hand settles on a new reading (higher = snappier).
@export_range(0.5, 20.0, 0.5) var settle_speed: float = 4.0

@onready var gauge_hand: MeshInstance3D = $gauge_furnace2/gauge_hand

static var rot_min: int = 150 # degrees, empty
static var rot_max: int = -150 # degrees, full

var _level := 1.0 # fuel as 0..1 of the tank
var _shown := 1.0 # where the hand rests now, 0..1
var _t := randf() * 100.0

func _ready() -> void:
	if furnace == null:
		var root := owner if owner else get_tree().current_scene
		furnace = root.find_child("furnace_fire", true, false)
	if furnace and furnace.has_signal(&'fuel_changed'):
		furnace.fuel_changed.connect(update_display)
		update_display(furnace.get(&'fuel'), furnace.get(&'max_fuel'))

func update_display(fuel: float, max_fuel: float = 100.0):
	_level = clampf(fuel / maxf(max_fuel, 0.001), 0.0, 1.0)

func _process(delta: float) -> void:
	_t += delta * jitter_speed
	_shown = lerpf(_shown, _level, 1.0 - exp(-settle_speed * delta))
	# Two unrelated sines make an uneven tremble rather than a steady buzz.
	var shiver := (sin(_t) + sin(_t * 2.37 + 1.3) * 0.6) / 1.6 * jitter_amount
	gauge_hand.rotation_degrees.z = remap(_shown, 0.0, 1.0, rot_min, rot_max) + shiver
