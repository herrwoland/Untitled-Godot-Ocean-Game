extends Node
## Carries one Carryable at the CarrySocket marker in front of the camera.
## The single rule (enforced in player._try_interact): interacting with a
## carryable picks it up; interacting while holding anything drops it.
## Move/tilt the CarrySocket marker in the editor to adjust where held items
## sit — bring it closer to make paper readable. While swimming they move to
## SwimCarrySocket instead, low and out of the way of the view.

@export var player: CharacterBody3D
@export var socket: Node3D
## Where held items sit while swimming (falls back to `socket` if unset).
@export var swim_socket: Node3D

const FOLLOW_STIFFNESS := 18.0 # higher = snappier follow
const DROP_CLEAR_TIME := 0.6 # seconds a dropped item ignores the player while it falls clear
const SETTLED := 0.005 # m (and radians): near enough the socket to be held fast to it

var carried: RigidBody3D = null
var _target: Node3D # the socket it was last going to
var _gliding := false # still on its way into the hands
var _off := Transform3D.IDENTITY # where it is from the socket while it glides in

func _ready() -> void:
	add_to_group(&'carry_controller')

func is_carrying() -> bool:
	return carried != null

## Whether the carried item is still on its way into the hands (picked up, or changing sockets).
func is_settling() -> bool:
	return _gliding

func pick_up(item: RigidBody3D) -> void:
	if carried:
		drop()
	carried = item
	_target = null # glides in from where it lies
	item.on_picked_up()

func drop() -> void:
	if not carried:
		return
	var item := carried
	# Our velocity is only our own walking: riding a ship is extra. Hand the
	# item the ship's motion too, or the deck slides away from under it.
	var riding: Vector3 = player.deck_velocity() if player.has_method(&'deck_velocity') else Vector3.ZERO
	item.on_dropped(player.velocity * 0.8 + riding)
	carried = null
	# It leaves our hands right in front of our face: let it fall clear of us before it can
	# bump the body that is still standing there.
	if player is PhysicsBody3D and not item.ignore_player: # those keep their exception for good
		item.add_collision_exception_with(player)
		var item_ref: WeakRef = weakref(item) # it may be gone by then (eg. burnt in the furnace)
		get_tree().create_timer(DROP_CLEAR_TIME).timeout.connect(func() -> void:
			var still_here: RigidBody3D = item_ref.get_ref()
			if still_here and is_instance_valid(player):
				still_here.remove_collision_exception_with(player))

func reset_day() -> void:
	carried = null # items themselves are restaged by the mission controller

## Every drawn frame, not every physics step, and before the Body (an earlier sibling), so the
## hands find it where it is drawn. Chasing the socket on physics steps with a lag, it swung
## about in the hands as a rocking deck carried us.
func _process(delta: float) -> void:
	if not carried:
		return
	var target := socket
	if swim_socket and &'state' in player and player.state == 1: # Player State.SWIM
		target = swim_socket
	if target != _target:
		# picked up, or changing sockets: glide in from where it is, relative to the socket, so
		# however the deck moves us the glide only ever closes the gap
		_off = target.global_transform.affine_inverse() * carried.global_transform
		_target = target
		_gliding = true
	if _gliding:
		_off = _off.interpolate_with(Transform3D.IDENTITY, 1.0 - exp(-FOLLOW_STIFFNESS * delta))
		if _off.origin.length() < SETTLED and _off.basis.get_rotation_quaternion().get_angle() < SETTLED:
			_off = Transform3D.IDENTITY
			_gliding = false
	carried.global_transform = target.global_transform * _off # held: it goes wherever we go
