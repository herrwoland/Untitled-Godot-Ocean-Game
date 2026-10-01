class_name FishSpine extends RefCounted
## Bends a fish's spine chain along the path its head actually swam, so the
## long body curves through a turn like a train on its track instead of
## swinging round stiffly, plus a tail sway that beats faster the faster it
## swims. The head bone stays rigid (the jaw and eyes hang off the root).
##
## Expects one bone chain, head first, each bone's +Y running toward the
## tail and +Z pointing up (fish_01's spine_0..spine_7). Driven by
## HunterFish, which owns the tuning exports.

const TRAIL_SPACING := 1.0 # m between remembered head positions
const TELEPORT := 60.0 # a jump this big in one step restarts the trail

var skeleton: Skeleton3D
var sway_angle := 8.0 # degrees at the tail tip
var sway_frequency := 0.3 # tail beats per second when barely moving...
var sway_frequency_per_speed := 0.01 # ...plus this much per m/s
var max_joint_bend := 25.0 # degrees one joint may fold against the previous

var _lengths: PackedFloat32Array # bone k origin -> bone k+1 origin
var _trail: PackedVector3Array = [] # world positions of the head bone, newest first
var _trail_length := 0.0
var _body_length := 0.0
var _phase := 0.0

func _init(target: Skeleton3D) -> void:
	skeleton = target
	for b in skeleton.get_bone_count() - 1:
		var length := skeleton.get_bone_global_rest(b).origin.distance_to(skeleton.get_bone_global_rest(b + 1).origin)
		_lengths.append(length)
		_body_length += length

func update(delta: float, speed: float) -> void:
	var xf := skeleton.global_transform
	var head := xf * skeleton.get_bone_global_rest(0).origin
	_record(head)
	_phase = fmod(_phase + delta * TAU * (sway_frequency + speed * sway_frequency_per_speed), TAU)

	var up := xf.basis.y.normalized()
	var rest_back := (xf.basis * skeleton.get_bone_global_rest(0).basis.y).normalized() # head bone, toward the tail
	var inv := xf.basis.inverse()
	var bones := skeleton.get_bone_count()
	var parent_basis := skeleton.get_bone_global_rest(0).basis # the head keeps its rest pose
	var pos := xf * skeleton.get_bone_global_rest(1).origin
	var prev_dir := rest_back
	var walked := _lengths[0]
	for k in range(1, bones):
		var dir := prev_dir
		if k < bones - 1:
			walked += _lengths[k]
			var target := _point_behind(head, walked, rest_back)
			if target.distance_to(pos) > 0.001:
				dir = (target - pos).normalized()
		# Keep any one joint from folding too sharply (fresh trails, hard turns).
		var bend := prev_dir.angle_to(dir)
		var limit := deg_to_rad(max_joint_bend)
		if bend > limit:
			dir = prev_dir.slerp(dir, limit / bend).normalized()
		# Tail sway: a wave running down the body, growing toward the tail.
		var along := float(k) / float(bones - 1)
		var sway := deg_to_rad(sway_angle) * pow(along, 1.5) * sin(_phase - along * 2.5)
		dir = dir.rotated(up, sway)
		if k < bones - 1:
			pos += dir * _lengths[k]
		prev_dir = dir

		# Bone basis in skeleton space: +Y along the body, +Z up.
		var y := (inv * dir).normalized()
		var z_up := Vector3.UP - y * y.dot(Vector3.UP)
		if z_up.length() < 0.01:
			z_up = parent_basis.z
		var z := z_up.normalized()
		var bone_basis := Basis(y.cross(z), y, z)
		skeleton.set_bone_pose_rotation(k, (parent_basis.inverse() * bone_basis).get_rotation_quaternion())
		parent_basis = bone_basis

## Remember where the head has been, one point per TRAIL_SPACING meters,
## only as far back as the body reaches.
func _record(head: Vector3) -> void:
	if _trail.is_empty() or head.distance_to(_trail[0]) > TELEPORT:
		_trail = [head]
		_trail_length = 0.0
		return
	var step := head.distance_to(_trail[0])
	if step < TRAIL_SPACING:
		return
	_trail.insert(0, head)
	_trail_length += step
	while _trail.size() > 2 and _trail_length - _trail[-1].distance_to(_trail[-2]) > _body_length + 10.0:
		_trail_length -= _trail[-1].distance_to(_trail[-2])
		_trail.remove_at(_trail.size() - 1)

## The point `distance` meters back along the head's path from where it is
## now. Past the end of the remembered path it carries on straight back.
func _point_behind(head: Vector3, distance: float, straight_back: Vector3) -> Vector3:
	var from := head
	var left := distance
	for p in _trail:
		var seg := from.distance_to(p)
		if seg >= left and seg > 0.0001:
			return from.lerp(p, left / seg)
		left -= seg
		from = p
	return from + straight_back * left
