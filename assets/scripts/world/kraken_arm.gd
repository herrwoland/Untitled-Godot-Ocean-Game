class_name KrakenArm extends RefCounted
## One arm of the Kraken, moved entirely in code: a chain of points, one per
## joint, simulated like a heavy rope hanging in water. Every frame the Kraken
## gives each point a goal (trailing behind a swim stroke, wrapped round a
## rock, reaching for the prey, coiled round it, gripping a hull) and the
## points drift toward their goals while keeping their momentum, so the arm
## lags, overshoots and settles on its own instead of snapping into poses.
## The root stays fixed to the crown; with a pinned tip (reaching, gripping)
## the chain is solved from both ends (FABRIK) so the tip lands where aimed.
## The bones are then turned to lie along the chain.
##
## Expects one bone chain per arm, root first, each bone's +Y running toward
## the tip (see kraken/source/build_kraken_placeholder.py for the convention).

enum Role { FREE, REACH, HOLD, BOAT, RECOIL }

var skeleton: Skeleton3D
var index := 0 # which arm round the crown, 0..
var bones: PackedInt32Array # root to tip
var length := 0.0 # m, root to tip
var along: PackedFloat32Array # m from the root to each point
var points: PackedVector3Array # world, one more than there are bones: the tip
var goals: PackedVector3Array # world, where each point is drawn to this frame
var root_radius := 1.35 # m, the arm's thickness at the root...
var tip_radius := 0.12 # ...and at the tip; wraps keep the arm on a surface, not in it

var role := Role.FREE
var pin_tip := false # solve the tip onto tip_target exactly
var tip_target := Vector3.ZERO # world
var hull_point := Vector3.ZERO # BOAT: where it grips, in the ship's local space
var timer := 0.0 # seconds in the current role
var gripped := false # BOAT: the tip has hold of the hull

var _segments: PackedFloat32Array # m, point k to point k+1
var _prev: PackedVector3Array # last frame's points: their difference is the momentum
var _parent_bone := -1
var _rest_basis: Array[Basis] = [] # skeleton space, per bone
var _rest_local: Array[Basis] = [] # each bone's rest rotation against its parent
const TELEPORT := 30.0 # a root jump this big in one step starts the arm over

func _init(target: Skeleton3D, arm_index: int, chain: PackedInt32Array) -> void:
	skeleton = target
	index = arm_index
	bones = chain
	_parent_bone = skeleton.get_bone_parent(bones[0])
	var n := bones.size()
	for k in n:
		var rest := skeleton.get_bone_global_rest(bones[k])
		_rest_basis.append(rest.basis.orthonormalized())
		_rest_local.append(skeleton.get_bone_rest(bones[k]).basis.orthonormalized())
	for k in n - 1:
		_segments.append(skeleton.get_bone_global_rest(bones[k]).origin.distance_to(
			skeleton.get_bone_global_rest(bones[k + 1]).origin))
	_segments.append(_segments[-1] if n > 1 else 1.0) # the tip bone: same as its neighbour
	along.append(0.0)
	for s in _segments:
		length += s
		along.append(length)
	var xf := skeleton.global_transform
	for k in n:
		points.append(xf * skeleton.get_bone_global_rest(bones[k]).origin)
	points.append(points[-1] + (xf.basis * _rest_basis[-1].y).normalized() * _segments[-1])
	_prev = points.duplicate()
	goals = points.duplicate()

func root() -> Vector3:
	return skeleton.global_transform * skeleton.get_bone_global_rest(bones[0]).origin

func tip() -> Vector3:
	return points[-1]

## Thickness at a point, so wraps sit on the rock's skin instead of inside it.
func radius_at(i: int) -> float:
	return lerpf(root_radius, tip_radius, pow(along[i] / length, 0.8))

func set_role(new_role: Role) -> void:
	role = new_role
	timer = 0.0
	gripped = false
	pin_tip = new_role == Role.REACH or new_role == Role.BOAT
	if pin_tip:
		tip_target = tip() # the reach starts from wherever the tip is now

## Jump straight into the goal pose (a new morning: nobody saw it move).
func snap_to_goals() -> void:
	points = goals.duplicate()
	points[0] = root()
	_follow_root()
	_prev = points.duplicate()

## ---- goal shapes (all world space) -------------------------------------------

## Loose, swimming or hovering: straight out of the crown along axis, splayed
## by spread toward out (the arm's own side of the crown), with a travelling
## wave and a curl at the tip.
func goals_spread(axis: Vector3, out: Vector3, spread: float, wave_amp: float, phase: float, curl: float) -> void:
	var start := points[0]
	var dir := (axis + out * spread).normalized()
	var side := axis.cross(out).normalized()
	for i in points.size():
		var t := along[i] / length
		var wave := side * sin(phase - t * 5.0) + out * 0.6 * cos(phase * 0.7 - t * 4.0)
		var g := start + dir * along[i] + wave * wave_amp * pow(t, 1.5)
		if t > 0.65: # the last third rolls back on itself
			g += (out - dir * 0.5) * curl * pow((t - 0.65) / 0.35, 2.0) * length * 0.25
		goals[i] = g

## Wrapped round a vertical-ish column: a helix on its surface. From the root
## it swings onto the rock over the first few meters, then winds round it,
## turn = +1/-1 for the direction, pitch = radians up (+) or down (-).
## rock_radius(height, angle) -> m gives the rock's real surface (Kraken
## measures it once), with e1/e2 the frame its angles are measured in.
func goals_wrap_column(center: Vector3, up: Vector3, e1: Vector3, e2: Vector3, rock_radius: Callable, turn: float, pitch: float, angle_offset: float) -> void:
	var start := points[0]
	var rel := start - center
	var a := atan2(rel.dot(e2), rel.dot(e1)) + angle_offset
	var h := rel.dot(up)
	var horizontal := cos(pitch)
	for i in points.size():
		if i > 0: # walk the helix one segment at a time, so a bulging rock is wound round, not cut through
			var r_here: float = rock_radius.call(h, a) + radius_at(i)
			a += turn * _segments[i - 1] * horizontal / maxf(r_here, 1.0)
			h += _segments[i - 1] * sin(pitch)
		var r: float = rock_radius.call(h, a) + radius_at(i) * 0.9
		var on_rock := center + up * h + (e1 * cos(a) + e2 * sin(a)) * r
		goals[i] = start.lerp(on_rock, smoothstep(0.0, 7.0, along[i]))

## Lying on a flat surface (the sea floor, a rock shelf): spirals outward from
## the root along the plane, the tip curling round.
func goals_wrap_plane(origin: Vector3, normal: Vector3, out: Vector3, curl: float) -> void:
	var start := points[0]
	var flat_out := (out - normal * out.dot(normal)).normalized()
	var on_plane := start - normal * (start - origin).dot(normal)
	var pos := on_plane
	goals[0] = start
	for i in range(1, points.size()):
		var t := along[i] / length
		var dir := flat_out.rotated(normal, curl * t * t * PI * 1.6)
		pos += dir * _segments[i - 1]
		goals[i] = start.lerp(pos + normal * radius_at(i), smoothstep(0.0, 6.0, along[i]))

## Reaching for a point: a shallow arc from the root to the target, bowed
## toward bow (the tip itself is pinned there by the solver).
func goals_reach(target: Vector3, bow: Vector3) -> void:
	var start := points[0]
	var span := minf(start.distance_to(target), length)
	for i in points.size():
		var t := along[i] / length
		goals[i] = start.lerp(target, t) + bow * sin(t * PI) * span * 0.18

## Coiled round something held (the player): the arm runs to it, then its last
## coil_length meters wind round center about axis.
func goals_coil(center: Vector3, axis: Vector3, coil_radius: float, coil_length: float, phase: float) -> void:
	var start := points[0]
	var e1 := axis.cross((center - start).normalized())
	if e1.length() < 0.1:
		e1 = axis.cross(Vector3.RIGHT)
	e1 = e1.normalized()
	var e2 := axis.cross(e1)
	var s0 := maxf(length - coil_length, 1.0)
	var coil_start := center + e1 * coil_radius - axis * coil_length * 0.06
	for i in points.size():
		var s := along[i]
		if s <= s0:
			var t := s / s0
			goals[i] = start.lerp(coil_start, t) + e2 * sin(t * PI) * 2.0
		else:
			var a := (s - s0) / coil_radius + phase
			goals[i] = center + (e1 * cos(a) + e2 * sin(a)) * coil_radius + axis * ((s - s0) * 0.12 - coil_length * 0.06)

## Gripping a hull: the tip hooks over at attach, the last wrap_length meters
## run down the hull's side (out = away from the hull, down = down its side),
## and the rest of the arm comes up to it from below.
func goals_hull(attach: Vector3, out: Vector3, down: Vector3, wrap_length: float) -> void:
	var start := points[0]
	var s0 := maxf(length - wrap_length, 1.0)
	var low := attach + out * 0.8 + down * wrap_length
	for i in points.size():
		var s := along[i]
		if s <= s0:
			goals[i] = start.lerp(low, s / s0)
		else:
			goals[i] = attach + out * 0.8 + down * (length - s)

## ---- simulation ----------------------------------------------------------------

## Drift every point toward its goal (stiffness: 1/s, stronger near the root,
## floppier at the tip), keep its momentum minus the water's drag, then hold
## the joints at their lengths.
func simulate(delta: float, stiffness: float, drag: float) -> void:
	var start := root()
	if start.distance_to(points[0]) > TELEPORT:
		goals[0] = start
		snap_to_goals()
		return
	points[0] = start
	_prev[0] = start
	var keep := exp(-drag * delta)
	var pull := 1.0 - exp(-stiffness * delta)
	for i in range(1, points.size()):
		var p := points[i]
		var momentum := (p - _prev[i]) * keep
		_prev[i] = p
		p += momentum
		p += (goals[i] - p) * minf(pull * lerpf(1.4, 0.6, along[i] / length), 1.0)
		points[i] = p
	if pin_tip:
		_fabrik(tip_target, 2)
	else:
		_follow_root()

## Each point at its joint length from the one before, root outward.
func _follow_root() -> void:
	for i in range(1, points.size()):
		var d := points[i] - points[i - 1]
		if d.length_squared() < 1e-8:
			d = goals[i] - points[i - 1]
		points[i] = points[i - 1] + d.normalized() * _segments[i - 1]

## Root fixed, tip on the target as nearly as the arm's length allows.
func _fabrik(target: Vector3, iterations: int) -> void:
	var n := points.size() - 1
	var start := points[0]
	for _it in iterations:
		points[n] = target
		for i in range(n - 1, -1, -1):
			var d := points[i] - points[i + 1]
			points[i] = points[i + 1] + (d.normalized() if d.length_squared() > 1e-8 else Vector3.UP) * _segments[i]
		points[0] = start
		_follow_root()

## Turn each bone to lie along the chain. Each bone's frame is carried down
## from its parent by the smallest rotation that lines its +Y up with the
## segment, so the arm never corkscrews.
func apply_to_skeleton() -> void:
	var inv := skeleton.global_transform.affine_inverse().basis
	var parent_global := _rest_basis_of(_parent_bone)
	var carried := _rest_basis[0]
	for k in bones.size():
		var dir := (inv * (points[k + 1] - points[k])).normalized()
		var frame := carried
		var y := frame.y.normalized()
		var d := y.dot(dir)
		if d < -0.9999:
			frame = Basis(frame.x.normalized(), PI) * frame
		elif d < 0.99999:
			frame = Basis(Quaternion(y, dir)) * frame
		skeleton.set_bone_pose_rotation(bones[k], (parent_global.inverse() * frame).get_rotation_quaternion())
		parent_global = frame
		if k + 1 < bones.size():
			carried = frame * _rest_local[k + 1]

func _rest_basis_of(bone: int) -> Basis:
	if bone < 0:
		return Basis.IDENTITY
	return skeleton.get_bone_global_rest(bone).basis.orthonormalized()
