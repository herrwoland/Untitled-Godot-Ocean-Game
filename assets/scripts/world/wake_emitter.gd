@tool
class_name WakeEmitter extends Node3D
## Leaves a foam wake on the ocean while moving through the water. Put one at the stern of a
## boat at the waterline (the churned trail) and a narrower one at the bow (the bow wave that
## peels off the hull). water.gd gathers all emitters every frame and stamps their path into
## the wake map, which spreads into a V as it ages.

## Half the width of the trail it leaves (m), eg. half the hull's beam at the stern.
@export_range(0.1, 50.0, 0.1, 'or_greater') var half_width := 5.0
## Foam laid down at full speed.
@export_range(0.0, 1.0, 0.01) var foam := 0.9
## Churned water (lighter tint, flatter waves) laid down at full speed.
@export_range(0.0, 1.0, 0.01) var churn := 1.0
## 0 = foam across the whole width, 1 = foam mostly along the sides (two wake lines).
@export_range(0.0, 1.0, 0.01) var edge_bias := 0.3
## Speed (m/s) below which nothing is left behind.
@export_range(0.0, 10.0, 0.05) var min_speed := 0.5
## Speed (m/s) giving the full wake.
@export_range(0.1, 40.0, 0.1) var full_speed := 6.0
## Emits while the waterline is within this far below the emitter (m); higher out of the water
## (eg. the bow lifted by a wave) it leaves nothing.
@export_range(0.0, 10.0, 0.05) var max_height_above_water := 1.5

var _last_position := Vector3.INF

func _ready() -> void:
	add_to_group(&'wake_emitter')

## Stamp for this frame as [Vector4(x0, z0, x1, z1), Vector4(half width, foam, churn, edge
## bias)], or [] if it leaves nothing. Called by water.gd.
func get_stamp(delta : float, water_height : float) -> Array:
	var pos := global_position
	var last := _last_position
	_last_position = pos
	if delta <= 0.0 or last == Vector3.INF: return []
	var step := Vector2(pos.x - last.x, pos.z - last.z)
	if step.length() > 50.0: return [] # Teleported.
	var speed := step.length() / delta
	var amount := smoothstep(min_speed, full_speed, speed)
	amount *= 1.0 - smoothstep(0.0, max_height_above_water, pos.y - water_height)
	if amount <= 0.001: return []
	return [Vector4(last.x, last.z, pos.x, pos.z), Vector4(half_width, foam * amount, churn * amount, edge_bias)]
