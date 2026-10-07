extends Node3D
## Keeps the dial pointing at geographic north (world +X, see coordinate_system.gd) however the
## boat turns, pitches or rolls.

## Turns the dial if its north mark does not sit on the model's local +Z at rest.
@export_range(-180.0, 180.0, 1.0) var north_offset_deg: float = 0.0
## How quickly the dial follows (higher = snappier); a little lag feels like a real, damped compass.
@export_range(0.5, 20.0, 0.5) var follow_speed: float = 6.0

@onready var compass_inside: MeshInstance3D = $compass/compass_body/compass_inside

func rotate_compass(degree := 0.0):
	#0 means north, 180 means south
	compass_inside.rotation.y = degree

func _process(delta: float) -> void:
	# World north as the dial's parent sees it, then the angle of that around the dial's own up axis.
	var parent := compass_inside.get_parent_node_3d()
	var north := parent.global_basis.inverse() * Vector3.RIGHT
	var target := atan2(north.x, north.z) + deg_to_rad(north_offset_deg)
	compass_inside.rotation.y = lerp_angle(compass_inside.rotation.y, target, 1.0 - exp(-follow_speed * delta))
