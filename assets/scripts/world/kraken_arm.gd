class_name KrakenArm extends RefCounted
## One arm of the Kraken, moved entirely in code.
##
## Built on how octopus arms actually move. An arm is a muscular hydrostat:
## no skeleton, and its stiffness falls steeply toward the thin tip, so the
## base stays long and nearly straight while the distal part does the
## curling. Reaching is a bend that travels from the base out to the tip
## (Gutfreund 1996, Sumbre 2001) — behind the bend the arm is straight and
## aimed, ahead of it the tip stays rolled; grasping is the tip coiling round
## the prey while the base positions it (Sumbre 2005). And a body this big
## moves slowly: everything eases, nothing snaps.
##
## So the arm is a chain of joints, each holding a bend (a swing away from
## the bone before it — no twist). Every frame:
##  1. the Kraken gives a goal shape (points in the world: trailing, wrapped
##     round a rock, aimed at the prey, gripping a hull);
##  2. that shape becomes a target bend per joint, walked from the root, each
##     clamped to the joint's limit — tiny near the body, large at the tip;
##  3. the targets are smoothed along the arm, so it always forms curves, and
##     special shapes are laid over them (the rolled tip ahead of a reach, a
##     coil round a held body);
##  4. each joint eases toward its target on a critically damped spring —
##     slow, no overshoot, no shiver;
##  5. the chain is rebuilt from the root and the bones are posed.
##
## Expects one bone chain per arm, root first, each bone's +Y running toward
## the tip, bones shortening toward the tip (see
## kraken/source/build_kraken_placeholder.py for the convention).

enum Role { FREE, REACH, HOLD, BOAT, RECOIL, FISH }

var skeleton: Skeleton3D
var index := 0 # which arm round the crown, 0..
var bones: PackedInt32Array # root to tip
var length := 0.0 # m, root to tip
var along: PackedFloat32Array # m from the root to each point (one per joint, plus the tip)
var points: PackedVector3Array # world, rebuilt every frame: joints, then the tip
var goals: PackedVector3Array # world, the shape the Kraken wants this frame
var root_radius := 1.35 # m, the arm's thickness at the root...
var tip_radius := 0.12 # ...and at the tip; wraps keep the arm on a surface, not in it

## Bend limits. Joint 0 is the arm's swing at the crown; after it the limit
## per joint grows from bend_root to bend_tip (radians) along the arm.
var swing_limit := deg_to_rad(40.0)
var bend_root := deg_to_rad(4.0)
var bend_tip := deg_to_rad(50.0)
var bend_exponent := 1.5 # >1: the limit stays small for longer before rising toward the tip
## How quickly the joints follow (natural frequency of their springs, rad/s).
## About 1 means a change takes ~3-4 s to settle. Set per role by the Kraken.
var response := 0.8
## Fastest any joint turns (rad/s). Joint motions add up toward the tip, so
## this is what keeps a 50 m arm from whipping.
var max_joint_speed := deg_to_rad(18.0)
## Fastest the tip may travel relative to the body (m/s).
var max_tip_speed := 14.0
## 0..1: how much of last frame's shape the goal keeps — the water holding a
## loose arm back as the body turns, so it trails instead of swinging stiffly.
var inertia := 0.0
## Holding: joints whose middle lies past curl_from meters coil at curl_rate
## radians per meter (a coil of radius 1/curl_rate). -1 = no coil.
var curl_from := -1.0
var curl_rate := 0.0
## Reaching: the bend front, 0..1 along the arm. Joints behind it aim at the
## goal; joints past it stay rolled up. 1 = no front (the whole arm aims).
var reach_front := 1.0
## Smoothing passes along the arm (curves). A grip lies on its route exactly: 0.
var smooth_passes := 2

var role := Role.FREE
var pin_tip := false # BOAT, gripped: the tip is held exactly on tip_target
var pin_joints := 7 # how many of the last joints turn to keep a pinned tip on
const PIN_DISTAL := 7 # the light end that holds a pinned tip exactly
const PIN_BASE_EASE := 0.12 # the heavier joints behind it lean this much of the way each frame
## The tip homing in on tip_target with its last joints (1/s, 0 = off): the
## fine finish of a reach, done by the light distal arm.
var seek_tip := 0.0
var tip_target := Vector3.ZERO # world
## BOAT: its route onto the hull, in the ship's local space, from the tip's
## hold on the deck back down the outside of the hull and under the keel.
var hull_path := PackedVector3Array()
var timer := 0.0 # seconds in the current role
var gripped := false # BOAT: the tip has hold of the hull
var fish_station := 0.5 # FISH: where along the fish (snout 0 .. tail 1) it coils

var _n := 0 # joints (= bones)
var _segments: PackedFloat32Array # m, bone lengths
var _limit: PackedFloat32Array # radians, per joint
var _bend: PackedVector2Array # current bend per joint: rotation vector (x, z) in the frame before it
var _vel: PackedVector2Array
var _target: PackedVector2Array
var _rest_local: Array[Basis] = [] # each bone's rest rotation against its parent
var _base: Basis # skeleton space: joint 0's frame before its bend (the crown socket)
var _root_origin: Vector3 # skeleton space
var _frames: Array[Basis] = [] # skeleton space, per bone, from the last rebuild
var _pos: PackedVector3Array # skeleton space, joints then the tip
var _world := 1.0 # world meters per skeleton unit (the model's scale in its scene)
const TELEPORT := 30.0 # a root jump this big in one step starts the arm over

func _init(target: Skeleton3D, arm_index: int, chain: PackedInt32Array) -> void:
	skeleton = target
	index = arm_index
	bones = chain
	_n = bones.size()
	for k in _n:
		_rest_local.append(skeleton.get_bone_rest(bones[k]).basis.orthonormalized())
	for k in _n - 1:
		_segments.append(skeleton.get_bone_global_rest(bones[k]).origin.distance_to(
			skeleton.get_bone_global_rest(bones[k + 1]).origin))
	# The tip bone's length is not stored in the rig: carry the taper on.
	var last := _segments[-1] if _n > 1 else 1.0
	if _n > 2 and _segments[-2] > 0.0:
		last = _segments[-1] * _segments[-1] / _segments[-2]
	_segments.append(last)
	# The model may be scaled in its scene: goals, lengths and radii are world
	# meters, the chain itself is built in the skeleton's own units.
	_world = skeleton.global_transform.basis.get_scale().x
	along.append(0.0)
	for s in _segments:
		length += s * _world
		along.append(length)
	var parent := skeleton.get_bone_parent(bones[0])
	var parent_basis := skeleton.get_bone_global_rest(parent).basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
	_base = parent_basis * _rest_local[0]
	_root_origin = skeleton.get_bone_global_rest(bones[0]).origin
	_bend.resize(_n)
	_vel.resize(_n)
	_target.resize(_n)
	_frames.resize(_n)
	_pos.resize(_n + 1)
	points.resize(_n + 1)
	goals.resize(_n + 1)
	configure()
	_rebuild()
	goals = points.duplicate()

## Recompute the per-joint limits after changing swing_limit / bend_*.
func configure() -> void:
	_limit.resize(_n)
	for k in _n:
		if k == 0:
			_limit[k] = swing_limit
		else:
			var t := (along[k] + _segments[k] * _world * 0.5) / length
			_limit[k] = lerpf(bend_root, bend_tip, pow(t, bend_exponent))

func root() -> Vector3:
	return skeleton.global_transform * _root_origin

func tip() -> Vector3:
	return points[-1]

## Thickness at a point, so wraps sit on the rock's skin instead of inside it.
func radius_at(i: int) -> float:
	return lerpf(root_radius, tip_radius, pow(along[i] / length, 0.8))

func set_role(new_role: Role) -> void:
	role = new_role
	timer = 0.0
	gripped = false
	pin_tip = false
	seek_tip = 0.0
	curl_from = -1.0
	reach_front = 1.0
	if new_role == Role.BOAT:
		tip_target = tip() # the reach for the hull starts from wherever the tip is now

## Where a held body sits: the centre of the coil (world). Valid while
## curl_from >= 0. Uses the coil the joints can really make: short of bones
## or bend, it is wider than asked for.
func coil_center() -> Vector3:
	for k in _n:
		var seg := _segments[k] * _world
		if along[k] + seg * 0.5 > curl_from:
			var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
			var bend := minf(curl_rate * seg, _limit[k])
			var radius := seg / maxf(bend, 0.01) / _world # in skeleton units
			return skeleton.global_transform * (_pos[k] + before.z.normalized() * radius)
	return tip()

## Jump straight into the goal pose (a new morning: nobody saw it move).
func snap_to_goals() -> void:
	_targets_from(goals)
	_smooth_targets()
	_lay_over_shapes()
	for k in _n:
		_bend[k] = _target[k]
		_vel[k] = Vector2.ZERO
	_rebuild()

## ---- goal shapes (all world space) -------------------------------------------

## Loose, swimming or hovering: straight out of the crown along axis, splayed
## by spread toward out (the arm's own side of the crown), with a slow wave
## running down it and the tip rolled back on itself.
func goals_spread(axis: Vector3, out: Vector3, spread: float, wave_amp: float, phase: float, curl: float) -> void:
	var start := points[0]
	var dir := (axis + out * spread).normalized()
	var side := axis.cross(out).normalized()
	for i in points.size():
		var t := along[i] / length
		var wave := side * sin(phase - t * 3.0) + out * 0.5 * cos(phase * 0.7 - t * 2.5)
		var g := start + dir * along[i] + wave * wave_amp * pow(t, 2.0)
		if t > 0.6: # the last part rolls back on itself
			g += (out - dir * 0.5) * curl * pow((t - 0.6) / 0.4, 2.0) * length * 0.2
		goals[i] = g

## Wrapped round a vertical-ish column. The base runs down along the rock
## (root_pitch, nearly straight) and the distal part winds round it at pitch
## (radians up + / down -), turn = +1/-1 for the direction. rock_radius
## (height, angle) -> m gives the rock's real surface, e1/e2 the frame its
## angles are measured in.
func goals_wrap_column(center: Vector3, up: Vector3, e1: Vector3, e2: Vector3, rock_radius: Callable, turn: float, pitch: float, root_pitch: float, angle_offset: float) -> void:
	var start := points[0]
	var rel := start - center
	var a := atan2(rel.dot(e2), rel.dot(e1)) + angle_offset
	var h := rel.dot(up)
	goals[0] = start
	for i in range(1, points.size()):
		var seg := along[i] - along[i - 1]
		var p := lerpf(root_pitch, pitch, smoothstep(0.1, 0.55, along[i] / length))
		var r_here: float = rock_radius.call(h, a) + radius_at(i)
		a += turn * seg * cos(p) / maxf(r_here, 1.0)
		h += seg * sin(p)
		var r: float = rock_radius.call(h, a) + radius_at(i) * 0.9
		var on_rock := center + up * h + (e1 * cos(a) + e2 * sin(a)) * r
		goals[i] = start.lerp(on_rock, smoothstep(0.0, 7.0, along[i]))

## Lying on a flat surface (the sea floor, a rock shelf): spirals outward from
## the root along the plane, the tip curling round.
func goals_wrap_plane(origin: Vector3, normal: Vector3, out: Vector3, curl: float) -> void:
	var start := points[0]
	var flat_out := (out - normal * out.dot(normal)).normalized()
	var pos := start - normal * (start - origin).dot(normal)
	goals[0] = start
	for i in range(1, points.size()):
		var t := along[i] / length
		var dir := flat_out.rotated(normal, curl * t * t * PI * 1.6)
		pos += dir * (along[i] - along[i - 1])
		goals[i] = start.lerp(pos + normal * radius_at(i), smoothstep(0.0, 6.0, along[i]))

## Aimed at a point: a shallow arc from the root to the target, bowed
## toward bow.
func goals_reach(target: Vector3, bow: Vector3) -> void:
	var start := points[0]
	var span := minf(start.distance_to(target), length)
	for i in points.size():
		var t := along[i] / length
		goals[i] = start.lerp(target, t) + bow * sin(t * PI) * span * 0.12

## Following a route laid onto something (a hull), given in the world from
## the tip's end back toward the body: the distal arm lies along the route —
## as much of it as 60 % of the arm can cover — and the rest of the arm comes
## straight from the crown to where the route starts.
func goals_path(path: PackedVector3Array) -> void:
	var start := points[0]
	var walked := PackedFloat32Array([0.0])
	for j in range(1, path.size()):
		walked.append(walked[-1] + path[j].distance_to(path[j - 1]))
	var wrap := minf(walked[-1], length * 0.6)
	var join := _point_on(path, walked, wrap)
	var s0 := maxf(length - wrap, 1.0)
	for i in points.size():
		var from_tip := length - along[i]
		goals[i] = _point_on(path, walked, from_tip) if from_tip <= wrap else start.lerp(join, along[i] / s0)

static func _point_on(path: PackedVector3Array, walked: PackedFloat32Array, distance: float) -> Vector3:
	for j in range(1, path.size()):
		if walked[j] >= distance:
			var seg := walked[j] - walked[j - 1]
			return path[j - 1].lerp(path[j], (distance - walked[j - 1]) / seg if seg > 0.0 else 0.0)
	return path[-1]

## ---- simulation ----------------------------------------------------------------

func simulate(delta: float) -> void:
	if root().distance_to(points[0]) > TELEPORT:
		snap_to_goals()
		return
	var chain := goals
	if inertia > 0.0:
		chain = goals.duplicate()
		for i in chain.size():
			chain[i] = goals[i].lerp(points[i], inertia)
	_targets_from(chain)
	_smooth_targets()
	_lay_over_shapes()
	var before_bend := _bend.duplicate()
	var tip_before := _pos[_n]
	# Critically damped springs: ease in, ease out, never overshoot. The
	# lighter tip answers a little quicker than the heavy base.
	for k in _n:
		var w := response * lerpf(0.8, 1.3, float(k) / maxf(_n - 1, 1))
		var acc := (_target[k] - _bend[k]) * (w * w) - _vel[k] * (2.0 * w)
		_vel[k] = (_vel[k] + acc * delta).limit_length(max_joint_speed)
		_bend[k] = (_bend[k] + _vel[k] * delta).limit_length(_limit[k])
	_rebuild()
	if seek_tip > 0.0 and not pin_tip:
		_pin_tip_to(tip_target, 1.0 - exp(-seek_tip * delta))
	# Joint motions add up toward the tip: if together they would fling it
	# faster than max_tip_speed (relative to the body), scale every joint's
	# step down alike — same shape, slower.
	var moved := _pos[_n].distance_to(tip_before)
	if moved * _world > max_tip_speed * delta:
		var scale := max_tip_speed * delta / (moved * _world)
		for k in _n:
			_bend[k] = before_bend[k].lerp(_bend[k], scale)
			_vel[k] *= scale
		_rebuild()
	if pin_tip: # a grip holds on whatever the hull does
		_pin_tip_to(tip_target, 1.0)

## The goal chain as a target bend per joint, walked from the root: each
## joint aims at its goal point from where the arm has really got to (after
## the joints before it were clamped), so the limits shape the whole arm.
func _targets_from(chain: PackedVector3Array) -> void:
	var inv := skeleton.global_transform.affine_inverse()
	var p := _root_origin
	var frame := _base
	for k in _n:
		var before := _base if k == 0 else frame * _rest_local[k]
		var want := inv * chain[k + 1] - p
		var b := Vector2.ZERO
		if want.length_squared() > 1e-8:
			b = _swing(before.transposed() * want.normalized())
			# A goal almost straight behind a joint has no clear side to bend
			# to: the side flips with every wobble and whips the arm across.
			# Past ~115 degrees, keep bending the way it already is.
			if b.length() > 2.0 and _bend[k].length() > 0.02 and b.dot(_bend[k]) < 0.0:
				b = _bend[k].normalized() * b.length()
			b = b.limit_length(_limit[k])
		_target[k] = b
		frame = before * _bend_basis(b)
		p += frame.y * _segments[k]

## Average each joint's target with its neighbours: no kinks, only curves.
func _smooth_targets() -> void:
	for _pass in smooth_passes:
		var prev := _target[0]
		for k in range(1, _n - 1):
			var here := _target[k]
			_target[k] = (prev * 0.25 + here * 0.5 + _target[k + 1] * 0.25).limit_length(_limit[k])
			prev = here

## The shapes that are not about reaching a point: the rolled tip ahead of a
## reach's bend front, and the coil round a held body.
func _lay_over_shapes() -> void:
	for k in _n:
		var mid := along[k] + _segments[k] * _world * 0.5
		if curl_from >= 0.0 and mid > curl_from:
			_target[k] = Vector2(minf(curl_rate * _segments[k] * _world, _limit[k]), 0.0)
		elif reach_front < 1.0 and mid > maxf(reach_front, 0.5) * length:
			_target[k] = Vector2(_limit[k] * 0.45, 0.0) # the far half stays rolled until the bend arrives

## Rebuild the chain from the joints' bends (skeleton space, then world).
func _rebuild() -> void:
	var xf := skeleton.global_transform
	var p := _root_origin
	_pos[0] = p
	points[0] = xf * p
	for k in _n:
		var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
		_frames[k] = before * _bend_basis(_bend[k])
		p += _frames[k].y * _segments[k]
		_pos[k + 1] = p
		points[k + 1] = xf * p

## Bring the tip onto a world point by turning the last few joints (cyclic
## coordinate descent), each within its limit. amount 1 = all the way now;
## less = that fraction of the way this frame, for a tip that homes in.
## With pin_joints past the light distal end, the heavy joints nearer the base
## first lean a little of the way each frame (PIN_BASE_EASE), so the whole arm
## drifts after a hold that moves away and the distal end does the exact part.
func _pin_tip_to(target: Vector3, amount: float) -> void:
	var t := skeleton.global_transform.affine_inverse() * target
	var distal := mini(pin_joints, PIN_DISTAL)
	for k in range(_n - distal - 1, maxi(_n - pin_joints, 0) - 1, -1):
		_turn_tip_toward(k, t, amount * PIN_BASE_EASE)
	for _it in (2 if amount >= 1.0 else 1):
		for k in range(_n - 1, maxi(_n - distal, 0) - 1, -1):
			_turn_tip_toward(k, t, amount)

func _turn_tip_toward(k: int, t: Vector3, amount: float) -> void:
	var to_tip := _pos[_n] - _pos[k]
	var to_target := t - _pos[k]
	if to_tip.length_squared() < 1e-6 or to_target.length_squared() < 1e-6:
		return
	var turn := Quaternion(to_tip.normalized(), to_target.normalized())
	if amount < 1.0:
		turn = Quaternion.IDENTITY.slerp(turn, amount)
	var turned := Basis(turn) * _frames[k]
	var before := _base if k == 0 else _frames[k - 1] * _rest_local[k]
	_bend[k] = _swing((before.transposed() * turned.y).normalized()).limit_length(_limit[k])
	_vel[k] *= 0.5
	_rebuild()

## Pose the bones from the joints' bends.
func apply_to_skeleton() -> void:
	for k in _n:
		skeleton.set_bone_pose_rotation(bones[k], (_rest_local[k] * _bend_basis(_bend[k])).get_rotation_quaternion())

## The swing that turns +Y onto dir, as a rotation vector (x, z).
static func _swing(dir: Vector3) -> Vector2:
	var axis := Vector3(dir.z, 0.0, -dir.x) # +Y cross dir
	var s := axis.length()
	if s < 1e-6:
		return Vector2.ZERO if dir.y > 0.0 else Vector2(PI, 0.0)
	return Vector2(axis.x, axis.z) / s * atan2(s, dir.y)

static func _bend_basis(b: Vector2) -> Basis:
	var angle := b.length()
	if angle < 1e-6:
		return Basis.IDENTITY
	return Basis(Vector3(b.x, 0.0, b.y) / angle, angle)
