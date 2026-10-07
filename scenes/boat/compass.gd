extends Node3D
## Keeps the dial pointing at geographic north (world +X, see coordinate_system.gd) however the
## boat turns, pitches or rolls.

## Extra turn of the dial, if it ever needs trimming. 0: rotation.y = 0 is north with the boat unturned.
@export_range(-180.0, 180.0, 1.0) var north_offset_deg: float = 0.0
## How quickly the dial follows (higher = snappier); a little lag feels like a real, damped compass.
@export_range(0.5, 20.0, 0.5) var follow_speed: float = 6.0

@onready var compass_inside: MeshInstance3D = $compass/compass_body/compass_inside

func rotate_compass(degree := 0.0):
	#0 means north, 180 means south
	compass_inside.rotation.y = degree

var _boat: Node3D
var _rest_angle := 0.0 # where north lies around the dial's axis with the boat unturned

# World north as the dial's parent sees it, as an angle around the dial's own up axis.
func _north_angle(parent: Node3D) -> float:
	var north := parent.global_basis.orthonormalized().inverse() * Vector3.RIGHT
	return atan2(north.x, north.z)

func _ready() -> void:
	_boat = owner as Node3D
	if _boat == null:
		set_process(false)
		return
	# The dial's rotation.y = 0 is north when the boat sits unturned, so measure from there.
	var parent := compass_inside.get_parent_node_3d()
	var rel := _boat.global_basis.orthonormalized().inverse() * parent.global_basis.orthonormalized()
	var north := rel.inverse() * Vector3.RIGHT
	_rest_angle = atan2(north.x, north.z)

func _process(delta: float) -> void:
	var target := _north_angle(compass_inside.get_parent_node_3d()) - _rest_angle + deg_to_rad(north_offset_deg)
	compass_inside.rotation.y = lerp_angle(compass_inside.rotation.y, target, 1.0 - exp(-follow_speed * delta))
