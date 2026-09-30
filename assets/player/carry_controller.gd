extends Node
## Carries one Carryable at the CarrySocket marker in front of the camera.
## The single rule (enforced in player._try_interact): interacting with a
## carryable picks it up; interacting while holding anything drops it.
## Move/tilt the CarrySocket marker in the editor to adjust where held items
## sit — bring it closer to make paper readable.

@export var player: CharacterBody3D
@export var socket: Node3D

const FOLLOW_STIFFNESS := 18.0 # higher = snappier follow
const DROP_CLEAR_TIME := 0.6 # seconds a dropped item ignores the player while it falls clear

var carried: RigidBody3D = null

func _ready() -> void:
	add_to_group(&'carry_controller')

func is_carrying() -> bool:
	return carried != null

func pick_up(item: RigidBody3D) -> void:
	if carried:
		drop()
	carried = item
	item.on_picked_up()

func drop() -> void:
	if not carried:
		return
	var item := carried
	item.on_dropped(player.velocity * 0.8)
	carried = null
	# It leaves our hands right in front of our face: let it fall clear of us before it can
	# bump the body that is still standing there.
	if player is PhysicsBody3D:
		item.add_collision_exception_with(player)
		var item_ref: WeakRef = weakref(item) # it may be gone by then (eg. burnt in the furnace)
		get_tree().create_timer(DROP_CLEAR_TIME).timeout.connect(func() -> void:
			var still_here: RigidBody3D = item_ref.get_ref()
			if still_here and is_instance_valid(player):
				still_here.remove_collision_exception_with(player))

func reset_day() -> void:
	carried = null # items themselves are restaged by the mission controller

func _physics_process(delta: float) -> void:
	if not carried:
		return
	# Smoothly chase the socket; exponential decay keeps it framerate-stable.
	var weight := 1.0 - exp(-FOLLOW_STIFFNESS * delta)
	carried.global_transform = carried.global_transform.interpolate_with(socket.global_transform, weight)
