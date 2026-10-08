extends Node3D

@onready var gauge_hand: MeshInstance3D = $gauge_furnace2/gauge_hand

static var rot_min: int = 150
static var rot_max: int = -150

func update_display(fuel:int, max_fuel: float = 100.0):
	gauge_hand.rotation.z = remap(fuel,0, max_fuel, rot_min,rot_max)
