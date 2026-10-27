extends Node
## Carries one Carryable at the CarrySocket marker in front of the camera.
## The single rule (enforced in player._try_interact): interacting with a
## carryable picks it up; interacting while holding anything drops it.
## Move/tilt the CarrySocket marker in the editor to adjust where held items
## sit — bring it closer to make paper readable. While swimming they move to
## SwimCarrySocket instead, low and out of the way of the view.
## An item with grip markers is only placed here: the body's hand reaches for it and then carries it
## (see body_rig.gd's `carried_item`), so it ends up wherever the hand could reach.

@export var player: CharacterBody3D
@export var socket: Node3D
## Where held items sit while swimming (falls back to `socket` if unset).
@export var swim_socket: Node3D
## How far (degrees) below level the held item goes down with the view. Looking lower, it stays
## there and the view looks on past it, at the feet; followed all the way down, it went into the body.
@export_range(0.0, 90.0, 1.0) var max_look_down := 35.0

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
		_off = _held_at(target).affine_inverse() * carried.global_transform
		_target = target
		_gliding = true
	if _gliding:
		_off = _off.interpolate_with(Transform3D.IDENTITY, 1.0 - exp(-FOLLOW_STIFFNESS * delta))
		if _off.origin.length() < SETTLED and _off.basis.get_rotation_quaternion().get_angle() < SETTLED:
			_off = Transform3D.IDENTITY
			_gliding = false
	carried.global_transform = _held_at(target) * _off # held: it goes wherever we go

## Where `socket` holds the item: where it is, but never lower than max_look_down below level. Looking
## farther down, it is turned back up about the eyes by the difference.
func _held_at(socket_node: Node3D) -> Transform3D:
	var at := socket_node.global_transform
	var camera := player.get(&'camera') as Camera3D
	if camera == null:
		return at
	var eyes := camera.global_transform
	var look := -eyes.basis.z.normalized()
	var below := -asin(clampf(look.y, -1.0, 1.0)) - deg_to_rad(max_look_down)
	if below <= 0.0:
		return at
	var across := eyes.basis.x.normalized() # the view turns down about this; back up by `below`
	var up := Transform3D(Basis(across, below), Vector3.ZERO)
	return Transform3D(Basis.IDENTITY, eyes.origin) * up * Transform3D(Basis.IDENTITY, -eyes.origin) * at
