extends Node3D
## The boat's fuel gauge: the arrow follows the furnace's fuel, shivering a little like the needle
## of an old barometer, and the low-fuel light and the body's red glow come on when it runs low.

## Warning comes on at or below this share of the tank, in percent.
@export_range(0.0, 100.0, 1.0) var warning_value: float = 15.0
## The furnace to read. Left empty, it is found by name inside the boat.
@export var furnace: Node
## How far (m along the dial) the needle shivers. The dial is about 0.53 wide.
@export_range(0.0, 0.02, 0.0005) var jitter_amount: float = 0.003
## How quickly the shiver wanders.
@export_range(0.1, 30.0, 0.1) var jitter_speed: float = 9.0
## How quickly the needle settles on a new reading (higher = snappier).
@export_range(0.5, 20.0, 0.5) var settle_speed: float = 4.0

@onready var low_fuel_light: SpotLight3D = $low_fuel_light
@onready var fuel_meter_body: MeshInstance3D = $fuel_meter/fuel_meter_body
@onready var fuel_meter_arrow: MeshInstance3D = $fuel_meter/fuel_meter_body/fuel_meter_arrow

const arrow_low_pos_x = 0.266
const arrow_high_pos_x = -0.266

var _level := 1.0 # fuel as 0..1 of the tank
var _shown := 1.0 # where the needle rests now, 0..1
var _t := randf() * 100.0

func _ready() -> void:
	if furnace == null:
		var root := owner if owner else get_tree().current_scene
		furnace = root.find_child("furnace_fire", true, false)
	if furnace and furnace.has_signal(&'fuel_changed'):
		furnace.fuel_changed.connect(update_fuel_meter)
		update_fuel_meter(furnace.get(&'fuel'), furnace.get(&'max_fuel'))

func fuel_light(light_on := false):
	low_fuel_light.visible = light_on
	var mat := fuel_meter_body.get_surface_override_material(0) as StandardMaterial3D
	if mat:
		mat.emission_energy_multiplier = 1.0 if light_on else 0.0

func update_fuel_meter(fuel: float, max_fuel: float = 100.0):
	_level = clampf(fuel / maxf(max_fuel, 0.001), 0.0, 1.0)
	fuel_light(_level * 100.0 <= warning_value)

func _process(delta: float) -> void:
	_t += delta * jitter_speed
	_shown = lerpf(_shown, _level, 1.0 - exp(-settle_speed * delta))
	# Two unrelated sines make an uneven tremble rather than a steady buzz.
	var shiver := (sin(_t) + sin(_t * 2.37 + 1.3) * 0.6) / 1.6 * jitter_amount
	fuel_meter_arrow.position.x = remap(_shown, 0.0, 1.0, arrow_low_pos_x, arrow_high_pos_x) + shiver
