extends SkeletonModifier3D
## Adjusts the player's body after its clip has posed it (see PlayerBody):
##  - the look: the upper body turns toward where the view looks while the legs stay where they
##    stand, shared out from the lower back up to the neck as a real one turns;
##  - the hands: each arm reaches its hand to a point (on the helm's wheel), the elbow bending out
##    and down toward a pole, the way an arm does (two-bone IK).
## All points are in the skeleton's own space; PlayerBody sets them every frame.

## How far the upper body is turned toward the view (radians, about the skeleton's up).
var twist := 0.0
## Hands to reach, or Vector3.INF to leave that arm to its clip.
var hand_l := Vector3.INF
var hand_r := Vector3.INF
## Where each elbow bends toward.
var pole_l := Vector3.ZERO
var pole_r := Vector3.ZERO

## How the turn is shared out, lower back to neck (adds up to 1).
const TWIST := {&'spine_01': 0.15, &'spine_02': 0.2, &'spine_03': 0.25, &'neck_01': 0.4}

func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	if absf(twist) > 0.001:
		for bone_name: StringName in TWIST:
			var b := sk.find_bone(bone_name)
			if b < 0:
				continue
			var g := sk.get_bone_global_pose(b)
			g.basis = Basis(Vector3.UP, twist * TWIST[bone_name]) * g.basis
			sk.set_bone_global_pose(b, g)
	if hand_l != Vector3.INF:
		_reach(sk, &'upperarm_l', &'lowerarm_l', &'hand_l', hand_l, pole_l)
	if hand_r != Vector3.INF:
		_reach(sk, &'upperarm_r', &'lowerarm_r', &'hand_r', hand_r, pole_r)

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
