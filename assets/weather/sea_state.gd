@tool
class_name SeaState extends Resource
## A weather preset: the sea, sky, clouds, fog, sun and rain in one file (see weather.gd, which
## saves, applies and blends them). Each dictionary maps a property or shader parameter name to
## its value; only what a dictionary holds gets changed, so a preset can leave things out.

## Per wave cascade, in the same order as the Water node's (eg. wind_speed, foam_amount).
@export var waves : Array[Dictionary] = []
## Water node: water and foam colour.
@export var water : Dictionary = {}
## Water material (mat_water.tres) shader parameters: clarity, tints, foam, rain look, shafts...
@export var water_material : Dictionary = {}
## Sky material shader parameters: clouds, sky colours, sunset, lightning.
@export var sky_material : Dictionary = {}
## Environment: fog, volumetric fog, ambient light, sky energy, glow.
@export var environment : Dictionary = {}
## Sun: colour, energy, direction (quaternion).
@export var sun : Dictionary = {}
## The world FogVolume's material.
@export var world_fog : Dictionary = {}
## Rain: intensity and wind.
@export var rain : Dictionary = {}
