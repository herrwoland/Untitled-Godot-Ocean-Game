extends Node3D
## A fire in a furnace: flames licking up off a bed of coals, a few sparks, and the light it
## throws flickering with them. The flames and sparks are the child particles; this script
## only makes `light` breathe the way a fire does -- a restless wobble with the odd deeper dip
## when a flame collapses -- and nudges it about a little so the shadows it casts move.

## The light the fire casts. Defaults to a node called furnace_light in the same scene.
@export var light: Light3D
## How much the brightness wanders around its set energy (0 = steady, 0.5 = wild).
@export_range(0.0, 1.0, 0.01) var flicker_amount: float = 0.3
## How fast it wanders. Real fire flickers several times a second.
@export_range(0.1, 20.0, 0.1) var flicker_speed: float = 7.0
## How far (m) the light shifts about, so shadows sway with the flames.
@export_range(0.0, 0.3, 0.005) var flicker_sway: float = 0.04

var _noise := FastNoiseLite.new()
var _base_energy := 0.0
var _base_position := Vector3.ZERO
var _t := 0.0

func _ready() -> void:
	if light == null:
		var root := owner if owner else get_parent()
		if root:
			light = root.find_child("furnace_light", true, false) as Light3D
	if light:
		_base_energy = light.light_energy
		_base_position = light.position
	_noise.seed = randi()
	_noise.frequency = 1.0
	_noise.fractal_octaves = 3

func _process(delta: float) -> void:
	if light == null or not light.is_visible_in_tree():
		return
	_t += delta * flicker_speed
	# Fast wobble on top of a slower swell; the swell sometimes dips hard, like a flame collapsing.
	var wobble := _noise.get_noise_1d(_t)
	var swell := _noise.get_noise_1d(_t * 0.23 + 100.0)
	var dip := minf(swell, 0.0) * 1.5
	light.light_energy = _base_energy * maxf(1.0 + flicker_amount * (wobble + swell * 0.5 + dip), 0.2)
	light.position = _base_position + flicker_sway * Vector3(
			_noise.get_noise_1d(_t * 0.7 + 30.0), _noise.get_noise_1d(_t * 0.7 + 60.0), _noise.get_noise_1d(_t * 0.7 + 90.0))
