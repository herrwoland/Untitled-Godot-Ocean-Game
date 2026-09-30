extends Node3D
## The ship's furnace: it burns fuel, and the fuel drives the engine. Drop a fuel cell into
## the Intake (the space around the fire) and it is burnt: the fire flares up, then slowly
## sinks as the fuel runs down. Empty, only the coals glow, and the engine has nothing to give
## -- she can still be steered, but she drifts.
##
## The fire is its own gauge: the flames (the child particles) and the light they throw follow
## how much fuel is left. The light also breathes the way a fire does -- a restless wobble with
## the odd deeper dip when a flame collapses -- and sways a little so the shadows move.

signal fuel_changed(fuel: float, max_fuel: float)
signal refuelled(fuel: float)
signal ran_out

@export_group("Fuel")
## A full furnace.
@export var max_fuel: float = 100.0
## What one fuel cell adds (anything over max_fuel is wasted).
@export var fuel_per_cell: float = 30.0
## How long a full furnace burns, in seconds.
@export var full_burn_time: float = 120.0
## Fuel at the start of the game and of each new day.
@export var start_fuel: float = 100.0
## Below this share of a full furnace the engine starts to lose power (it fades to nothing at
## empty), so running dry is felt before it happens.
@export_range(0.0, 0.5, 0.01) var engine_fade_below: float = 0.08

@export_group("Fire")
## How much bigger and brighter the fire flares when a cell goes in (0 = no flare).
@export_range(0.0, 2.0, 0.05) var flare_strength: float = 0.8
## How long the flare takes to settle back (s).
@export_range(0.1, 20.0, 0.1) var flare_time: float = 5.0
## Flames at their smallest (almost empty) vs full, as a share of the Flames particle count.
## Full is the fire exactly as tuned on the Flames node.
@export var flames_amount_range := Vector2(0.2, 1.0)
## Flame height at their smallest vs fullest (1 = as authored).
@export var flames_size_range := Vector2(0.5, 1.0)

@export_group("Light")
## The light the fire casts. Defaults to a node called furnace_light in the same scene.
@export var light: Light3D
## Light left when the fuel is gone and only the coals glow, as a share of its set energy.
@export_range(0.0, 1.0, 0.01) var light_when_empty: float = 0.12
## How much the brightness wanders around its set energy (0 = steady, 0.5 = wild).
@export_range(0.0, 1.0, 0.01) var flicker_amount: float = 0.3
## How fast it wanders. Real fire flickers several times a second.
@export_range(0.1, 20.0, 0.1) var flicker_speed: float = 7.0
## How far (m) the light shifts about, so shadows sway with the flames.
@export_range(0.0, 0.3, 0.005) var flicker_sway: float = 0.04

@onready var _flames: GPUParticles3D = $Flames
@onready var _coals: GPUParticles3D = $Coals
@onready var _sparks: GPUParticles3D = $Sparks
@onready var _intake: Area3D = $Intake

var fuel := 0.0
var _flare := 0.0 # 1 right after a cell goes in, settling to 0
var _ship: Node = null # whatever has an engine to drive (see mass_calculation.gd)
var _noise := FastNoiseLite.new()
var _base_energy := 0.0
var _base_position := Vector3.ZERO
var _t := 0.0

func _ready() -> void:
	var root := owner if owner else get_parent()
	if light == null and root:
		light = root.find_child("furnace_light", true, false) as Light3D
	if light:
		_base_energy = light.light_energy
		_base_position = light.position
	_ship = _find_ship()
	_noise.seed = randi()
	_noise.frequency = 1.0
	_noise.fractal_octaves = 3
	_intake.body_entered.connect(_on_intake_body_entered)
	var bus := get_node_or_null(^'/root/EventBus')
	if bus: bus.day_started.connect(func(_day: int) -> void: set_fuel(start_fuel))
	set_fuel(start_fuel)

## How full the furnace is, 0..1.
func fuel_level() -> float:
	return clampf(fuel / maxf(max_fuel, 0.001), 0.0, 1.0)

func set_fuel(amount: float) -> void:
	var was_empty := fuel <= 0.0
	fuel = clampf(amount, 0.0, max_fuel)
	fuel_changed.emit(fuel, max_fuel)
	if fuel <= 0.0 and not was_empty:
		ran_out.emit()

## Burns one fuel cell: tops the furnace up and makes the fire flare.
func add_cell() -> void:
	set_fuel(fuel + fuel_per_cell)
	_flare = 1.0
	_sparks.restart() # a burst of sparks as it goes in
	refuelled.emit(fuel)

func _on_intake_body_entered(body: Node3D) -> void:
	if body.is_in_group(&'fuel') and body.get(&'carried') != true:
		body.queue_free()
		add_cell()

func _process(delta: float) -> void:
	if fuel > 0.0:
		set_fuel(fuel - max_fuel / maxf(full_burn_time, 0.01) * delta)
	_flare = move_toward(_flare, 0.0, delta / maxf(flare_time, 0.01))
	var heat := fuel_level()
	var burning := 1.0 if fuel > 0.0 else 0.0
	var flare := _flare * _flare * flare_strength # eases out: a big whoomph, then a long settle

	# The flames: fewer and lower as the fuel runs down, gone when it is out.
	_flames.amount_ratio = clampf(lerpf(flames_amount_range.x, flames_amount_range.y, heat) * burning, 0.0, 1.0)
	_flames.scale = Vector3.ONE * (lerpf(flames_size_range.x, flames_size_range.y, heat) + flare * 0.5)
	_coals.amount_ratio = lerpf(0.35, 1.0, heat)
	_sparks.amount_ratio = clampf(lerpf(0.1, 0.5, heat) + flare * 0.5, 0.0, 1.0) * burning

	if _ship:
		_ship.set(&'engine_fuel_power', smoothstep(0.0, maxf(engine_fade_below, 0.001), heat))

	_update_light(delta, lerpf(light_when_empty, 1.0, heat) + flare * 0.6)

## Fast wobble on top of a slower swell; the swell sometimes dips hard, like a flame collapsing.
func _update_light(delta: float, strength: float) -> void:
	if light == null or not light.is_visible_in_tree():
		return
	_t += delta * flicker_speed
	var wobble := _noise.get_noise_1d(_t)
	var swell := _noise.get_noise_1d(_t * 0.23 + 100.0)
	var dip := minf(swell, 0.0) * 1.5
	var flicker := maxf(1.0 + flicker_amount * (wobble + swell * 0.5 + dip), 0.2)
	light.light_energy = _base_energy * strength * flicker
	light.position = _base_position + flicker_sway * Vector3(
			_noise.get_noise_1d(_t * 0.7 + 30.0), _noise.get_noise_1d(_t * 0.7 + 60.0), _noise.get_noise_1d(_t * 0.7 + 90.0))

## The ship this furnace sits in: the nearest ancestor that has an engine to drive.
func _find_ship() -> Node:
	var node := get_parent()
	while node:
		if &'engine_fuel_power' in node:
			return node
		node = node.get_parent()
	return null
