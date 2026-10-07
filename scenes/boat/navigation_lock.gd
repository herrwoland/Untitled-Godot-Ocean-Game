extends Node3D

@export var lock_angle: int = 30
@export var unlock_angle: int = -30

@onready var navigation_handle: MeshInstance3D = $speed_control/navigation_shaft/navigation_handle

func lock_navigation(lock: bool = true):
	#TODO: tween the movement and play a sound. tween needs to be realistic, so use ease_in_out and BACK
	if lock:
		#TODO: make the player release from the navigation mode and unlock the navigation
		navigation_handle.rotation.z = lock_angle
	else:
		#TODO: stop going forward
		navigation_handle.rotation.z = unlock_angle
		
