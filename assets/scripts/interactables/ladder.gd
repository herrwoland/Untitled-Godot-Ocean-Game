class_name Ladder extends Area3D
## A ladder the player climbs. This area is where it can be grabbed; the climb itself runs
## along the line from `bottom` to `top` (where the player's feet go, a little out from the
## rungs), and at the top the player steps over onto `top_exit`.
##
## Get on by walking into it while facing it, or with jump/space (so a swimmer beside a ship
## climbs out the way they would swim up). On it: forward/space climbs, back goes down, and
## back at the bottom steps off; swim_down (C) lets go anywhere. The climb is worked out in
## the ladder's own space every physics frame, so on a moving ship the player rides it exactly.
##
## To add one: instance scenes/ladder/ladder.tscn beside a ladder model and drag its markers
## onto the rungs (Bottom, Top) and the landing (TopExit), then size the Shape to cover where
## a player should be able to grab it.

## Feet at the foot of the climb. Can be below the water.
@export var bottom: Node3D
## Feet at the top of the climb, just below the landing.
@export var top: Node3D
## Where the player ends up standing after stepping over the top.
@export var top_exit: Node3D
## Climbing speed (m/s along the ladder).
@export var climb_speed: float = 2.2
## How long stepping over the top takes (s).
@export var exit_time: float = 0.4

func _ready() -> void:
	if bottom == null: bottom = get_node_or_null(^'Bottom')
	if top == null: top = get_node_or_null(^'Top')
	if top_exit == null: top_exit = get_node_or_null(^'TopExit')
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node3D) -> void:
	if body.has_method(&'ladder_in_reach'):
		body.ladder_in_reach(self, true)

func _on_body_exited(body: Node3D) -> void:
	if body.has_method(&'ladder_in_reach'):
		body.ladder_in_reach(self, false)

## Length of the climb (m).
func length() -> float:
	return bottom.global_position.distance_to(top.global_position)

## A point on the climb, 0 = bottom, 1 = top, in world space right now.
func point(t: float) -> Vector3:
	return bottom.global_position.lerp(top.global_position, clampf(t, 0.0, 1.0))

## Where along the climb (0..1) a world position is closest to.
func closest_t(world_pos: Vector3) -> float:
	var a := bottom.global_position
	var ab := top.global_position - a
	return clampf((world_pos - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)

## The level direction from the climb towards the ladder (and over it at the top): the way a
## climber faces, whatever the ladder's lean.
func facing() -> Vector3:
	var d := top_exit.global_position - top.global_position
	d.y = 0.0
	return d.normalized() if d.length_squared() > 1e-6 else -global_basis.z
