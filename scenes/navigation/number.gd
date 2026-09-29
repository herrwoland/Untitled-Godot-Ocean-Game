extends Node3D
## One number cylinder of a mechanical counter. Ten faces, 36 degrees apart.

@onready var number_cylinder: MeshInstance3D = $number_cylinder/number_cylinder

## Accepts fractions: 3.5 sits halfway between the 3 and the 4.
func change(the_number: float):
	number_cylinder.rotation.x = deg_to_rad(the_number * -36.0)
