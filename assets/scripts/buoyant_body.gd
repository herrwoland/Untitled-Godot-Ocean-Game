extends "res://assets/scripts/mass_calculation.gd"
## Anything that floats the way the boat does, without being the boat: a RigidBody3D whose
## buoyant_cells (buoyant_cell.gd boxes) push it up by the water they displace, with the same
## water drag (mass_calculation.gd). Mass comes from the cells' density and size. Set the body's
## gravity_scale to 0 and let the cells weigh it (calc_f_gravity), like the boat.
##
## The water node lives in the main scene, so it is looked up by group here and handed to every
## cell, the same way boat.gd does it.

@export var water: Node

@export_group("Stick To Waves")
## Skip the buoyancy forces and glue the body to the water instead: every physics frame it is
## put exactly where its piece of the surface is, `stick_depth` under it. No lag, no bounce --
## it floats the way a mark painted on the waves would.
@export var stick_to_waves: bool = false
## How far below the surface the body's origin rides (m).
@export var stick_depth: float = 0.35
## Also ride the water's sideways sway as the waves pass (off: only up and down).
@export var stick_drift: bool = true
@export_group("")

var _rest := Vector2.INF # the piece of water we ride, as its rest position (Water.surface_rest)

func _ready() -> void:
	if not water:
		water = get_tree().get_first_node_in_group(&'water')
	if not water:
		push_warning("%s: no water node set and none found in group 'water'." % name)
	for cell in buoyant_cells:
		cell.water = water
		if stick_to_waves:
			cell.active = false # the water places us; no forces
	super._ready()
	if stick_to_waves:
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true

func _physics_process(delta: float) -> void:
	if not stick_to_waves or water == null:
		super._physics_process(delta)
		return
	if _rest == Vector2.INF:
		_rest = water.surface_rest(global_position)
	var p: Vector3 = water.surface_point(_rest)
	if not stick_drift:
		p.x = global_position.x
		p.z = global_position.z
	global_position = Vector3(p.x, p.y - stick_depth, p.z)
