extends Node3D

@onready var compass_inside: MeshInstance3D = $compass/compass_body/compass_inside

func rotate_compass(degree:= 0.0):
	#0 means north, 180 means south
	compass_inside.rotate_y(degree)
