extends Object
## Converts world XZ positions into the fictional coordinates shown on
## letters, packages and the ship's device (never raw engine units).

const ORIGIN_OFFSET := Vector2(4000.0, 7300.0)
const UNIT_SCALE := 0.1

## x = north, y = west, unrounded (the ship's counters roll through fractions).
static func coordinates(world_pos: Vector3) -> Vector2:
	return Vector2(ORIGIN_OFFSET.x + world_pos.x * UNIT_SCALE,
			ORIGIN_OFFSET.y - world_pos.z * UNIT_SCALE)

static func format_position(world_pos: Vector3) -> String:
	var c := coordinates(world_pos)
	return "%04d N  %04d W" % [roundi(c.x), roundi(c.y)]
