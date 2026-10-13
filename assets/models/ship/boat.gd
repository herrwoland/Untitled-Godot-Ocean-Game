extends "res://assets/scripts/mass_calculation.gd"
## Root of the standalone boat scene. The physics rig — buoyant cells, the
## hull drag volume and the collider — is invisible and must never be touched
## when changing the ship's look. Swap models by replacing the placeholders
## under the three visual sockets instead: ShipModel, WheelModel and the
## StairsModel node inside each ladder.
## The water node lives in the main scene, so it cannot be referenced from
## inside this scene file: the instance passes it in and we hand it to every
## buoyant cell here before the physics starts. Left empty, the scene's water
## node (group "water", see water.gd) is used.

@export var water: Node

## The power was cut or restored (set_powered).
signal power_changed(on: bool)

@onready var _engine_loop: AudioStreamPlayer3D = get_node_or_null(^'EngineLoop')
@onready var _cough_sound: AudioStreamPlayer3D = get_node_or_null(^'CoughSound')

var _cough := 0.0 # 1 right at an engine cough, recovering to 0
var _cough_puff: GPUParticles3D # a burst of the exhaust smoke, thrown out on a cough
var _smoke: GPUParticles3D # the exhaust: it stops with the engine
var _electric_lights: Array[Node3D] = [] # Light3D and UnderwaterGlow nodes on the ship's power
var _electric_glow: Array[BaseMaterial3D] = [] # per-instance copies of lamp emissive materials
var _electric_glow_energy: Array[float] = []
var _power_tween: Tween

func _ready() -> void:
	if not water:
		water = get_tree().get_first_node_in_group(&'water')
	if not water:
		push_warning("Boat '%s': no water node set and none found in group 'water'." % name)
	for cell in buoyant_cells:
		cell.water = water
	super._ready()
	_make_cough_puff.call_deferred()
	_collect_electrics.call_deferred()

## Called by the furnace when it is running low (severity 0..1). The engine stumbles: its
## sound drops out for a moment and a dirty puff comes out of the exhaust. Power is untouched.
func cough(severity: float) -> void:
	_cough = clampf(0.5 + severity * 0.5, 0.0, 1.0)
	if _cough_sound and _cough_sound.stream:
		_cough_sound.play()
	if _cough_puff:
		_cough_puff.restart()

## A one-shot copy of the exhaust smoke: a few bigger, faster puffs at once.
func _make_cough_puff() -> void:
	var smoke := find_child("smoke", true, false) as GPUParticles3D
	_smoke = smoke
	if smoke == null or smoke.process_material == null:
		return
	_cough_puff = smoke.duplicate() as GPUParticles3D
	_cough_puff.name = &'CoughPuff'
	_cough_puff.one_shot = true
	_cough_puff.emitting = false
	_cough_puff.amount = 6
	_cough_puff.explosiveness = 0.85
	_cough_puff.lifetime = smoke.lifetime * 0.8
	var pm := smoke.process_material.duplicate() as ParticleProcessMaterial
	if pm:
		pm.initial_velocity_min = 1.5
		pm.initial_velocity_max = 3.0
		pm.scale_min = maxf(pm.scale_min, 1.0) * 1.4
		pm.scale_max = maxf(pm.scale_max, 1.0) * 1.4
		_cough_puff.process_material = pm
	smoke.get_parent().add_child(_cough_puff)

## The engine only runs while someone is at the helm or the navigation lock holds her course;
## throttle drives its volume and pitch so pushing the lever is audible, not just visible.
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_cough = move_toward(_cough, 0.0, delta / 0.35)
	if _engine_loop == null or _engine_loop.stream == null:
		return
	if powered and (piloted or cruise_throttle != 0.0):
		if not _engine_loop.playing:
			_engine_loop.play()
		var effort := absf(helm_throttle) * engine_fuel_power
		# A cough knocks the note down for a moment, like a misfire.
		_engine_loop.volume_db = lerpf(-16.0, -4.0, effort) - 18.0 * _cough
		_engine_loop.pitch_scale = lerpf(0.9, 1.25, effort) * (1.0 - 0.25 * _cough)
	elif _engine_loop.playing:
		_engine_loop.stop()

## Cuts or restores the ship's power (the power panel calls this). Off, the engine dies, the
## exhaust stops and every electric lamp goes dark at once. On, they stutter back to life.
## What counts as electric: every light, UnderwaterGlow and glowing surface on the ship,
## except subtrees in the "off_grid" group -- the furnace (fire), and things that handle the
## power themselves (the searchlight, the panel's own bulbs) by listening to power_changed.
func set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if _smoke:
		_smoke.emitting = on
	if _power_tween:
		_power_tween.kill()
	if on:
		# A stutter, like old wiring catching: on, off, a weak flash, a long dark beat, then on.
		_power_tween = create_tween()
		for step: Array in [[true, 0.06], [false, 0.12], [true, 0.04], [false, 0.3]]:
			_power_tween.tween_callback(_set_electrics.bind(step[0]))
			_power_tween.tween_interval(step[1])
		_power_tween.tween_callback(_set_electrics.bind(true))
	else:
		_set_electrics(false)
	power_changed.emit(on)
	var bus := get_node_or_null(^'/root/EventBus')
	if bus:
		bus.ship_power_changed.emit(self, on)

func _set_electrics(on: bool) -> void:
	for light in _electric_lights:
		if is_instance_valid(light):
			light.visible = on
	for i in _electric_glow.size():
		_electric_glow[i].emission_energy_multiplier = _electric_glow_energy[i] if on else 0.0

## Deferred so everything aboard has set itself up (and joined "off_grid") first.
func _collect_electrics() -> void:
	_collect_electrics_under(self)

func _collect_electrics_under(node: Node) -> void:
	for child in node.get_children():
		if child.is_in_group(&'off_grid'):
			continue
		if child is Light3D or child is UnderwaterGlow:
			_electric_lights.append(child)
		elif child is MeshInstance3D and child.mesh and child.visible:
			# Each glowing surface gets its own copy, so dimming it can't darken a lamp elsewhere
			# that shares the imported material.
			for s in child.mesh.get_surface_count():
				var mat := child.get_active_material(s) as BaseMaterial3D
				if mat and mat.emission_enabled and mat.emission_energy_multiplier > 0.0:
					mat = mat.duplicate()
					child.set_surface_override_material(s, mat)
					_electric_glow.append(mat)
					_electric_glow_energy.append(mat.emission_energy_multiplier)
		_collect_electrics_under(child)
