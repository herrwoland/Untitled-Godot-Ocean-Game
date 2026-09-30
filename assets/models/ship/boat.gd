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

@onready var _engine_loop: AudioStreamPlayer3D = get_node_or_null(^'EngineLoop')
@onready var _cough_sound: AudioStreamPlayer3D = get_node_or_null(^'CoughSound')

var _cough := 0.0 # 1 right at an engine cough, recovering to 0
var _cough_puff: GPUParticles3D # a burst of the exhaust smoke, thrown out on a cough

func _ready() -> void:
	if not water:
		water = get_tree().get_first_node_in_group(&'water')
	if not water:
		push_warning("Boat '%s': no water node set and none found in group 'water'." % name)
	for cell in buoyant_cells:
		cell.water = water
	super._ready()
	_make_cough_puff.call_deferred()

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

## The engine only runs while someone is at the helm; throttle drives its
## volume and pitch so pushing the lever is audible, not just visible.
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_cough = move_toward(_cough, 0.0, delta / 0.35)
	if _engine_loop == null or _engine_loop.stream == null:
		return
	if piloted:
		if not _engine_loop.playing:
			_engine_loop.play()
		var effort := absf(helm_throttle) * engine_fuel_power
		# A cough knocks the note down for a moment, like a misfire.
		_engine_loop.volume_db = lerpf(-16.0, -4.0, effort) - 18.0 * _cough
		_engine_loop.pitch_scale = lerpf(0.9, 1.25, effort) * (1.0 - 0.25 * _cough)
	elif _engine_loop.playing:
		_engine_loop.stop()
