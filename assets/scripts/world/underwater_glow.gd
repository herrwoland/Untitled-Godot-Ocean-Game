@tool
class_name UnderwaterGlow extends Node3D
## A soft glow in the water around something bright (a lamp, a lure, a glowing rock): the light
## it throws into the murk, the way a lamp lights up volumetric fog. Put it at the centre of the
## bright thing (parent it to follow it); hide it to switch it off. Only works under the water.
## Drawn by the underwater effect with the camera under the water (Water node's
## underwater_glow_strength) and through the surface from above (the water material's
## glow_above_water dial). Water.gd gathers them every frame; the nearest 16 to the camera count.

## Colour of the glow.
@export var color := Color(0.6, 0.85, 1.0)
## Brightness looking straight at it (HDR: above 1 it blooms).
@export_range(0.0, 20.0, 0.01, 'or_greater') var strength := 1.0
## Radius of the bright core (m). The glow falls off with the square of the distance beyond it,
## like light scattered by real fog.
@export_range(0.05, 20.0, 0.05, 'or_greater') var size := 1.0
## How far through the water the glow can still be seen (m).
@export_range(1.0, 500.0, 1.0, 'or_greater') var reach := 60.0

func _ready() -> void:
	add_to_group(&'underwater_glow')

## (position, core size) for the shaders.
func pack_a() -> Vector4:
	var p := global_position
	return Vector4(p.x, p.y, p.z, size)

## (colour * strength, reach) for the shaders.
func pack_b() -> Vector4:
	return Vector4(color.r * strength, color.g * strength, color.b * strength, reach)
