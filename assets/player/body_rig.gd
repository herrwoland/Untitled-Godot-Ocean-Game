extends SkeletonModifier3D
## Adjusts the player's body after its clip has posed it (see PlayerBody):
##  - the look: the upper body turns toward where the view looks while the legs stay where they
##    stand, shared out from the lower back up to the neck as a real one turns;
##  - the lean: the upper body bends forward/back and side to side from the lower back, so it can
##    ride a heaving deck softly while the feet stay put;
##  - the hands: each arm reaches its hand to a point (on the helm's wheel), the elbow bending out
##    and down toward a pole, the way an arm does (two-bone IK), its fingers closed round a grip.
## All points are in the skeleton's own space; PlayerBody sets them every frame.

## How far the upper body is turned toward the view (radians, about the skeleton's up).
var twist := 0.0
## Hands to reach, or Vector3.INF to leave that arm to its clip.
var hand_l := Vector3.INF
var hand_r := Vector3.INF
## Where each elbow bends toward.
var pole_l := Vector3.ZERO
var pole_r := Vector3.ZERO
## The upper body's lean (radians): x forward (+) or back, y to its right (+) or left.
var lean := Vector2.ZERO
## How closed each hand is round a grip, from an open hand (just above 0) to the holding pose (1);
## 0 leaves the fingers to the clip. The holding fingers' turns (bone -> local rotation) are taken
## from a clip that grips (see PlayerBody); the open hand is the rig's rest pose.
var grip_l := 0.0
var grip_r := 0.0
var fingers_l := {}
var fingers_r := {}
## How deep a handle sits in the hand (0 = at the wrist, 1 = at the knuckles).
var grip_depth := 0.55
## The gripping hands' turn at the wrist (radians): x bend, y twist about the forearm, z tilt.
## Applied to the left hand as is and mirrored on the right.
var wrist := Vector3.ZERO
## The thumbs' turn at their base (radians): x pitch (opening the thumb out from the palm), y turn.
## Mirrored on the right like the wrists.
var thumb := Vector2.ZERO
## The wheel the hands hold, in the skeleton's space: its middle and axle, and where each hand
## likes to hold it (a direction out from the middle). A hand stays locked to its spoke: past
## LOCK_FROM from home it turns with the spoke as a hand gripping it would, rather than keeping
## the angle the forearm gives it (which, at full lock, turns the back of the hand to the handle).
var wheel_center := Vector3.INF
var wheel_axle := Vector3.ZERO
var home_l := Vector3.ZERO
var home_r := Vector3.ZERO
var _lock := {} # per side: the hand's turn relative to its spoke, as it was near home
const LOCK_FROM := 10.0 # degrees from home: up to here the hand is as the arm leaves it
const LOCK_FULL := 25.0 # degrees from home: from here it turns wholly with its spoke

## How the lean is shared out up the back (adds up to 1).
const LEAN := {&'spine_01': 0.4, &'spine_02': 0.35, &'spine_03': 0.25}

## How the turn is shared out, lower back to neck (adds up to 1).
const TWIST := {&'spine_01': 0.15, &'spine_02': 0.2, &'spine_03': 0.25, &'neck_01': 0.4}

func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if lean.length() > 0.0001:
		# in the skeleton's space the body faces +Z: about +X leans it forward, about +Z to its right
		for bone_name: StringName in LEAN:
			var b := sk.find_bone(bone_name)
			if b < 0:
				continue
			var g := sk.get_bone_global_pose(b)
			var k: float = LEAN[bone_name]
			g.basis = Basis(Vector3.RIGHT, lean.x * k) * Basis(Vector3.BACK, lean.y * k) * g.basis
			sk.set_bone_global_pose(b, g)
	if absf(twist) > 0.001:
		for bone_name: StringName in TWIST:
			var b := sk.find_bone(bone_name)
			if b < 0:
				continue
			var g := sk.get_bone_global_pose(b)
			g.basis = Basis(Vector3.UP, twist * TWIST[bone_name]) * g.basis
			sk.set_bone_global_pose(b, g)
	if hand_l != Vector3.INF:
		_grip(sk, '_l', hand_l, pole_l)
	else:
		_lock.erase('_l')
	if hand_r != Vector3.INF:
		_grip(sk, '_r', hand_r, pole_r)
	else:
		_lock.erase('_r')
	_close(sk, fingers_l, grip_l)
	_close(sk, fingers_r, grip_r)
	if grip_l > 0.001:
		_turn_thumb(sk, '_l')
	if grip_r > 0.001:
		_turn_thumb(sk, '_r')

## The thumb opened and turned at its base, by the thumb sliders.
func _turn_thumb(sk: Skeleton3D, side: String) -> void:
	var b := sk.find_bone('thumb_01' + side)
	if b < 0 or thumb == Vector2.ZERO:
		return
	var m := 1.0 if side == '_l' else -1.0
	sk.set_bone_pose_rotation(b, sk.get_bone_pose_rotation(b) * Quaternion.from_euler(Vector3(thumb.x, thumb.y * m, 0.0)))

## The arm reaches so its palm lands on `grip`: aimed once, then corrected by what it missed (the
## hand angles at the wrist, so the first aim is a few cm off).
func _grip(sk: Skeleton3D, side: String, grip: Vector3, pole: Vector3) -> void:
	var upper := StringName('upperarm' + side)
	var lower := StringName('lowerarm' + side)
	var hand := StringName('hand' + side)
	var knuckle := StringName('middle_01' + side)
	# the wrist's turn first, so the reach below lands the palm with the hand already turned
	var h := sk.find_bone(hand)
	if h >= 0 and wrist != Vector3.ZERO:
		var m := 1.0 if side == '_l' else -1.0
		var turn := Quaternion.from_euler(Vector3(wrist.x, wrist.y * m, wrist.z * m))
		sk.set_bone_pose_rotation(h, sk.get_bone_pose_rotation(h) * turn)
	var aim := _palm_on(sk, upper, hand, knuckle, grip)
	for pass_i in 3:
		_reach(sk, upper, lower, hand, aim, pole)
		_lock_to_spoke(sk, h, side, grip)
		aim += grip - _palm(sk, hand, knuckle)

## Turns the hand with the spoke it holds (see wheel_center).
func _lock_to_spoke(sk: Skeleton3D, h: int, side: String, grip: Vector3) -> void:
	if h < 0 or wheel_center == Vector3.INF:
		return
	var axle := wheel_axle.normalized()
	var out := grip - wheel_center
	out = (out - axle * out.dot(axle)).normalized()
	var home: Vector3 = home_l if side == '_l' else home_r
	var off := rad_to_deg(absf(home.signed_angle_to(out, axle)))
	var spoke := Basis(out, axle, out.cross(axle)) # turns as the spoke does
	var g := sk.get_bone_global_pose(h)
	var as_left := g.basis.orthonormalized()
	if off < LOCK_FROM:
		_lock[side] = spoke.inverse() * as_left # how the tuned hand sits on its spoke
		return
	if not _lock.has(side):
		return # took the wheel already turned: nothing to go by yet
	var locked: Basis = spoke * (_lock[side] as Basis)
	var w := smoothstep(LOCK_FROM, LOCK_FULL, off)
	var q := as_left.get_rotation_quaternion().slerp(locked.get_rotation_quaternion(), w)
	g.basis = Basis(q).scaled(g.basis.get_scale())
	sk.set_bone_global_pose(h, g)

## Where the palm is: halfway from the wrist to the knuckles.
func _palm(sk: Skeleton3D, hand_name: StringName, knuckle_name: StringName) -> Vector3:
	return sk.get_bone_global_pose(sk.find_bone(hand_name)).origin.lerp(sk.get_bone_global_pose(sk.find_bone(knuckle_name)).origin, grip_depth)

## Where the wrist goes for the palm (halfway to the knuckles) to sit on `grip`: a little short of it,
## back toward the shoulder, so the fingers close round the handle rather than the wrist.
func _palm_on(sk: Skeleton3D, shoulder_name: StringName, hand_name: StringName, knuckle_name: StringName, grip: Vector3) -> Vector3:
	var hand := sk.find_bone(hand_name)
	var knuckle := sk.find_bone(knuckle_name)
	if hand < 0 or knuckle < 0:
		return grip
	var palm := sk.get_bone_global_pose(hand).origin.distance_to(sk.get_bone_global_pose(knuckle).origin) * grip_depth
	var shoulder := sk.get_bone_global_pose(sk.find_bone(shoulder_name)).origin
	return grip - (grip - shoulder).normalized() * palm

## Fingers set `weight` of the way from an open hand to their holding pose.
func _close(sk: Skeleton3D, fingers: Dictionary, weight: float) -> void:
	if weight <= 0.001:
		return
	for b: int in fingers:
		var open := sk.get_bone_rest(b).basis.get_rotation_quaternion()
		sk.set_bone_pose_rotation(b, open.slerp(fingers[b], weight))

## Upper arm and forearm turned so the hand lands on `target`, the elbow toward `pole`.
func _reach(sk: Skeleton3D, upper_name: StringName, lower_name: StringName, hand_name: StringName, target: Vector3, pole: Vector3) -> void:
	var upper := sk.find_bone(upper_name)
	var lower := sk.find_bone(lower_name)
	var hand := sk.find_bone(hand_name)
	if upper < 0 or lower < 0 or hand < 0:
		return
	var gu := sk.get_bone_global_pose(upper)
	var s := gu.origin
	var e := sk.get_bone_global_pose(lower).origin
	var h := sk.get_bone_global_pose(hand).origin
	var a := s.distance_to(e)
	var b := e.distance_to(h)
	var to := target - s
	var d := clampf(to.length(), 0.01, (a + b) * 0.999) # out of reach: the arm straight toward it
	var dir := to.normalized()
	# the elbow: on the circle the two bones allow, on the pole's side
	var cos_a := clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0)
	var side := (pole - s) - dir * (pole - s).dot(dir)
	side = side.normalized() if side.length() > 0.0001 else dir.cross(Vector3.RIGHT).normalized()
	var elbow := s + dir * a * cos_a + side * a * sqrt(1.0 - cos_a * cos_a)
	gu.basis = Basis(Quaternion((e - s).normalized(), (elbow - s).normalized())) * gu.basis
	sk.set_bone_global_pose(upper, gu)
	var gl := sk.get_bone_global_pose(lower)
	var e2 := gl.origin
	var h2 := sk.get_bone_global_pose(hand).origin
	gl.basis = Basis(Quaternion((h2 - e2).normalized(), (s + dir * d - e2).normalized())) * gl.basis
	sk.set_bone_global_pose(lower, gl)
