extends Node3D

@export var warning_value: int = 15

@onready var low_fuel_light: SpotLight3D = $low_fuel_light
@onready var fuel_meter_body: MeshInstance3D = $fuel_meter/fuel_meter_body
@onready var fuel_meter_arrow: MeshInstance3D = $fuel_meter/fuel_meter_body/fuel_meter_arrow

const arrow_low_pos_x = 0.266
const arrow_high_pos_x = -0.266

func fuel_light(light_on := false):
	if light_on:
		low_fuel_light.show()
		#TODO: change the emission value of the surface override material 0 on fuel_meter_body to 1
	else:
		low_fuel_light.hide()
		#TODO: change the emission value of the surface override material 0 on fuel_meter_body to 0
func update_fuel_meter(fuel:int):
	#if the fuel max is 100 this should set the arrow moving on the right place
	#TODO instead of 100, take the max fuel amount from the globals, if it's not in the globals it should be stored there in case we want to add upgrades to increase it
	#TODO: make the arrow shake a bit not stay still
	fuel_meter_arrow.position.x = remap(fuel,0,100,arrow_low_pos_x,arrow_high_pos_x)
	
	fuel_light(fuel <= warning_value)
	
	
