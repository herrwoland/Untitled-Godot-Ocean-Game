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
	if hand_r != Vector3.INF:
		_grip(sk, '_r', hand_r, pole_r)
	_close(sk, fingers_l, grip_l)
	_close(sk, fingers_r, grip_r)

## The arm reaches so its palm lands on `grip`: aimed once, then corrected by what it missed (the
## hand angles at the wrist, so the first aim is a few cm off).
func _grip(sk: Skeleton3D, side: String, grip: Vector3, pole: Vector3) -> void:
	var upper := StringName('upperarm' + side)
	var lower := StringName('lowerarm' + side)
	var hand := StringName('hand' + side)
	var knuckle := StringName('middle_01' + side)
	var aim := _palm_on(sk, upper, hand, knuckle, grip)
	for pass_i in 2:
		_reach(sk, upper, lower, hand, aim, pole)
		aim += grip - _palm(sk, hand, knuckle)

## Where the palm is: halfway from the wrist to the knuckles.
func _palm(sk: Skeleton3D, hand_name: StringName, knuckle_name: StringName) -> Vector3:
	return sk.get_bone_global_pose(sk.find_bone(hand_name)).origin.lerp(sk.get_bone_global_pose(sk.find_bone(knuckle_name)).origin, 0.55)

## Where the wrist goes for the palm (halfway to the knuckles) to sit on `grip`: a little short of it,
## back toward the shoulder, so the fingers close round the handle rather than the wrist.
func _palm_on(sk: Skeleton3D, shoulder_name: StringName, hand_name: StringName, knuckle_name: StringName, grip: Vector3) -> Vector3:
	var hand := sk.find_bone(hand_name)
	var knuckle := sk.find_bone(knuckle_name)
	if hand < 0 or knuckle < 0:
		return grip
	var palm := sk.get_bone_global_pose(hand).origin.distance_to(sk.get_bone_global_pose(knuckle).origin) * 0.55
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
