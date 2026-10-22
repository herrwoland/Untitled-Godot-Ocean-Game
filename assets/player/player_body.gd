class_name PlayerBody extends Node3D
## The player's own body, only ever seen from inside it: look down and there are your legs, at the
## helm your hands are on the wheel, and the sun throws your whole shadow on the deck. Built from a
## rigged model and an animation library on the same rig (Quaternius' universal humanoid, CC0), so
## any clip in the library plays on it as it is, and a resculpted body keeps working as long as it
## keeps the rig.
##  - Its eyes are pinned to the camera, whatever the clip does (walking, swimming flat out, steering),
##    so the view is always from inside the head. It is scaled once so its eyes stand at the
##    camera's height, which also puts its feet on the ground.
##  - The head is cut out of the copy you see (from inside it would only block the view); a full copy
##    with the head casts the shadow and nothing else.
##  - It plays the clip for what the player is doing (see _pick()).
##  - It has a facing of its own: standing, the view can swing round some way before the feet follow,
##    the rest of the turn taken by the back and neck (see body_rig.gd); walking or swimming it turns
##    with the view; at the helm it faces the wheel with its hands on two spokes.

const BODY_SCENE := preload('res://assets/models/player/body/Superhero_Male_FullBody.gltf')
const ANIMATIONS := preload('res://assets/models/player/animations/UAL1_Standard.glb')
## Bones whose skin is cut from the visible copy (and everything below them).
const HEAD_BONES := ['Head']
const BodyRig := preload('res://assets/player/body_rig.gd')

## How far behind the eyes the camera sits (m): a little, so the inside of the face never shows at
## the edges of the view.
@export var eye_back := 0.08
## Seconds a clip takes to blend into the next.
@export var blend_time := 0.25
## Above 0, the clips move in steps at this many frames per second (the PS1's choppy animation);
## 0 = smooth.
@export_range(0.0, 60.0, 1.0) var anim_fps := 0.0
## Walking speed (m/s) at which the walk clip plays at its own pace (and so on for the others).
@export var walk_pace := 1.6
@export var jog_pace := 3.4
@export var sprint_pace := 6.0
@export var swim_pace := 1.5
## How far (degrees) the view can turn from where the body faces before the feet follow.
@export var free_look := 50.0
## How far (degrees) the back and neck turn toward the view; past that only the eyes go on.
@export var max_twist := 75.0

@export_group('Helm')
## How much farther back (m) than the helm's marker the feet stand from the wheel.
@export var helm_step_back := 0.15
## Where each hand likes to hold (degrees round from the wheel's top, as the helmsman sees it).
@export var hand_home := 35.0
## How far (degrees) a hand is carried round with its handle before it lets go and takes the handle
## nearest home: hand over hand, one hand always on the wheel.
@export var hand_reach := 100.0
## Seconds a hand takes to let go and take a new handle.
@export var regrip_time := 0.28
## The upper body riding the deck: how hard the deck's lurches push it (radians per m/s^2)...
@export var sway_push := 0.02
## ...how much of the deck's tilt it straightens up against (0 = tilts with her, 1 = stays upright)...
@export_range(0.0, 1.0, 0.01) var sway_upright := 0.6
## ...how quickly it swings back (Hz), how soon it settles (0..1), and how far it may lean (degrees).
@export var sway_hz := 1.1
@export_range(0.05, 1.0, 0.01) var sway_damping := 0.55
@export var sway_max := 14.0
@export_group('')

var player # the Player (player.gd): its state, Head and Camera3D
var _model: Node3D
var _skel: Skeleton3D
var _anim: AnimationPlayer
var _head_bone := -1
var _eye_in_head := Vector3.ZERO # the eyes, in the head bone's space
var _current := &''
var _step_left := 0.0
var _airborne := 0.0 # s off the ground
var _landing := 0.0 # s left of the landing clip
var _rig: BodyRig
var _yaw := NAN # where the body faces (the view's yaw convention), apart from the view
var _helm_ship: Node # the ship whose wheel we found
var _wheel: Node3D # her steering wheel, its axle and size (see _find_wheel())
var _wheel_axle := Vector3.RIGHT # in the wheel's own space
var _handles: Array[Node3D] = [] # the wheel's grip markers (Steering_*), round its rim
var _hold := [-1, -1] # per hand (left, right): the handle it holds
var _regrip := [-1.0, -1.0] # per hand: seconds into taking a new handle (< 0: holding)
var _regrip_from := [Vector3.ZERO, Vector3.ZERO] # where the hand let go (world)
var _lean := Vector2.ZERO # the upper body's lean on its spring, and how fast it swings
var _lean_v := Vector2.ZERO
var _stand_was := Vector3.INF # where the feet stood, and how fast they moved (the deck's lurch)
var _stand_v := Vector3.ZERO
var _lurch := Vector3.ZERO
const SWAY_SMOOTH := 0.12 # s: how long the deck's motion is smoothed over before the body feels it
var _arm_reach := 0.0 # m from the shoulder a hand can hold something (see _hands())
var _pivot: Node3D # what carries the camera (the camera shake's pivot, else the camera)
var _pivot_rest := Vector3.ZERO

## Builds the body for `p` (the Player: its Head turns it, its Camera3D is the eyes).
func setup(p) -> void:
	player = p
	_model = BODY_SCENE.instantiate()
	add_child(_model)
	_skel = _model.find_children('*', 'Skeleton3D', true, false)[0]
	_head_bone = _skel.find_bone(HEAD_BONES[0])
	var eye_point := _rest_eyes()
	_eye_in_head = (_skel.global_transform * _skel.get_bone_global_rest(_head_bone)).affine_inverse() * eye_point
	# scaled so its eyes stand where the camera does above the feet
	var camera: Camera3D = player.camera
	var eye_height: float = camera.global_position.y - player.global_position.y
	var model_eyes := eye_point.y - _model.global_position.y
	_model.scale = Vector3.ONE * (eye_height / maxf(model_eyes, 0.1))
	_split_head()
	_anim = AnimationPlayer.new()
	_anim.name = &'AnimationPlayer'
	_model.add_child(_anim)
	_anim.root_node = _anim.get_path_to(_model)
	_anim.add_animation_library(&'', _library_for(_model.get_path_to(_skel)))
	_anim.playback_default_blend_time = blend_time
	_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_play(&'Idle')
	_rig = BodyRig.new()
	_rig.name = &'BodyRig'
	_skel.add_child(_rig) # runs after the clip has posed the skeleton
	_rig.fingers_l = _held_fingers(&'Driving', '_l')
	_rig.fingers_r = _held_fingers(&'Driving', '_r')
	var cam_parent: Node3D = player.camera.get_parent()
	_pivot = cam_parent if cam_parent.name == &'ShakePivot' else player.camera
	_pivot_rest = _pivot.position

## The finger bones' turns (bone -> local rotation) halfway through `clip`: a clip whose hands hold
## something, to close the hands with when they grip.
func _held_fingers(clip: StringName, side: String) -> Dictionary:
	var out := {}
	var a := _anim.get_animation(clip)
	if a == null:
		return out
	for t in a.get_track_count():
		if a.track_get_type(t) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := String(a.track_get_path(t).get_concatenated_subnames())
		if not bone.ends_with(side):
			continue
		for finger in ['index', 'middle', 'ring', 'pinky', 'thumb']:
			if bone.begins_with(finger):
				var b := _skel.find_bone(bone)
				if b >= 0:
					out[b] = a.rotation_track_interpolate(t, a.length * 0.5)
	return out

## Where its eyes are at rest, in world space: the middle of the eye mesh, or a guess off the head.
func _rest_eyes() -> Vector3:
	for m: MeshInstance3D in _model.find_children('*', 'MeshInstance3D', true, false):
		if m.name.to_lower().begins_with('eyes'):
			return (m.global_transform * m.get_aabb()).get_center()
	var head := _skel.global_transform * _skel.get_bone_global_rest(_head_bone)
	return head.origin + Vector3(0.0, 0.08, 0.1)

## The clips, with their tracks pointed at this model's skeleton (same rig, same bone names).
func _library_for(skel_path: NodePath) -> AnimationLibrary:
	var src: Node = ANIMATIONS.instantiate()
	var player_src: AnimationPlayer = src.find_children('*', 'AnimationPlayer', true, false)[0]
	var lib := AnimationLibrary.new()
	for clip in player_src.get_animation_list():
		var a := player_src.get_animation(clip).duplicate() as Animation
		for t in a.get_track_count():
			var path := a.track_get_path(t)
			if path.get_subname_count() > 0: # a bone: Skeleton3D:bone
				a.track_set_path(t, NodePath(str(skel_path) + ':' + path.get_concatenated_subnames()))
		lib.add_animation(clip, a)
	src.free()
	return lib

## The copy you see loses its head (and eyes, brows, hair); the full one only casts the shadow.
func _split_head() -> void:
	var cut := {}
	for name in HEAD_BONES:
		var b := _skel.find_bone(name)
		if b >= 0:
			_mark(b, cut)
	for m: MeshInstance3D in _model.find_children('*', 'MeshInstance3D', true, false):
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		if not _is_head_mesh(m):
			var seen := m.duplicate() as MeshInstance3D
			seen.name = StringName(m.name + '_Seen')
			seen.mesh = _without(m, cut)
			seen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			m.get_parent().add_child(seen)
			seen.skeleton = seen.get_path_to(_skel)

func _mark(bone: int, cut: Dictionary) -> void:
	cut[bone] = true
	for c in _skel.get_bone_children(bone):
		_mark(c, cut)

## Eyes, brows, hair: nothing but head.
static func _is_head_mesh(m: MeshInstance3D) -> bool:
	var n := String(m.name).to_lower()
	return n.begins_with('eye') or n.contains('brow') or n.contains('hair')

## `m`'s mesh with every triangle that moves mostly with the cut bones taken out.
func _without(m: MeshInstance3D, cut: Dictionary) -> ArrayMesh:
	var skin := m.skin
	var src := m.mesh
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var per := bones.size() / maxi(verts.size(), 1) # 4 or 8 influences
		var on_head := PackedByteArray()
		on_head.resize(verts.size())
		for v in verts.size():
			var w := 0.0
			for k in per:
				var bi := bones[v * per + k]
				var bone := bi
				if skin:
					bone = skin.get_bind_bone(bi)
					if bone < 0:
						bone = _skel.find_bone(skin.get_bind_name(bi))
				if cut.has(bone):
					w += weights[v * per + k]
			on_head[v] = 1 if w > 0.4 else 0
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var kept := PackedInt32Array()
		for t in range(0, idx.size(), 3):
			if on_head[idx[t]] or on_head[idx[t + 1]] or on_head[idx[t + 2]]:
				continue
			kept.append_array([idx[t], idx[t + 1], idx[t + 2]])
		arrays[Mesh.ARRAY_INDEX] = kept
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(s))
	return out

func _process(delta: float) -> void:
	if player == null:
		return
	_animate(delta)
	# its own facing (never pitched); the model faces +Z, the view -Z
	var yaw: float = (player.head as Node3D).global_rotation.y
	var p = player
	if p.state == p.State.PILOT and _wheel_for(p.piloted_ship):
		_rig.twist = _square_shoulders()
		_helm(yaw, delta)
		return
	_leave_helm()
	_face(yaw, delta)
	_model.global_basis = Basis(Vector3.UP, _yaw + PI).scaled(_model.scale)
	_rig.twist = clampf(angle_difference(_yaw, yaw), -deg_to_rad(max_twist), deg_to_rad(max_twist))
	# and moved so its eyes are at the camera, a touch behind it
	var camera: Camera3D = player.camera
	var eyes := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _eye_in_head
	var back := Basis(Vector3.UP, yaw) * Vector3(0.0, 0.0, eye_back)
	_model.global_position += camera.global_position + back - eyes

## Where the body faces: the wheel at the helm; with the view while walking or swimming (quickly);
## standing, it lets the view swing free_look either way before the feet shuffle round after it.
func _face(view_yaw: float, delta: float) -> void:
	if is_nan(_yaw):
		_yaw = view_yaw
	var p = player
	var moving := Vector2(p.velocity.x, p.velocity.z).length() > 0.3
	if p.state == p.State.SWIM or moving:
		_yaw = lerp_angle(_yaw, view_yaw, 1.0 - exp(-10.0 * delta))
	else:
		var off := angle_difference(_yaw, view_yaw)
		var limit := deg_to_rad(free_look)
		if absf(off) > limit:
			_yaw = wrapf(_yaw + off - signf(off) * limit, -PI, PI)

## The ship's wheel (the node the helm turns: her `steering_hinge`), found once per ship: its axle
## and the handles on it to hold.
func _wheel_for(ship: Node) -> bool:
	if ship == null:
		return false
	if ship != _helm_ship:
		_helm_ship = ship
		_wheel = ship.find_child('steering_hinge', true, false) as Node3D
		if _wheel == null:
			return false
		for n in ship.find_children('*', '', true, false):
			if n.get(&'wheel') == _wheel and n.get(&'wheel_axis') is Vector3:
				_wheel_axle = (n.get(&'wheel_axis') as Vector3).normalized()
			# where hands can hold it: the markers on it named Steering_* (one per spoke handle)
		_handles.clear()
		for m: Node3D in _wheel.find_children('Steering_*', 'Marker3D', true, false):
			_handles.append(m)
		_hold = [-1, -1]
		_regrip = [-1.0, -1.0]
	return _wheel != null and _handles.size() >= 2

## At the helm. The feet stand helm_step_back behind the helm's marker, square to the wheel, on her
## deck as it tilts; the upper body rides her lurches and rolls on a soft spring (leaning back into
## a sudden stop, keeping itself fairly upright as she rolls), and the eyes, the camera, go with it.
## The hands hold the wheel's handles hand over hand (see _hands()).
func _helm(view_yaw: float, delta: float) -> void:
	var p = player
	var ship: Node3D = p.piloted_ship
	var marker: Node3D = p.helm_marker
	var wheel_at := _wheel.global_position
	var deck_up: Vector3 = ship.global_basis.y.normalized()
	# square to the wheel's face: on its axle, on the marker's side, at the marker's distance (a
	# marker a little off to one side of the axle would have us see the wheel at a slant, the far
	# side's handles out of reach)
	var to_marker := marker.global_position - wheel_at
	var flat_to_marker := to_marker - deck_up * to_marker.dot(deck_up)
	var away := _wheel.global_basis * _wheel_axle
	away = away - deck_up * away.dot(deck_up)
	away = away.normalized() if away.length() > 0.001 else flat_to_marker.normalized()
	if away.dot(flat_to_marker) < 0.0:
		away = -away
	var stand: Vector3 = wheel_at + deck_up * to_marker.dot(deck_up) + away * (flat_to_marker.length() + helm_step_back)
	# square to the wheel, standing on her deck
	var fwd := -away
	_yaw = atan2(-fwd.x, -fwd.z)
	var right := fwd.cross(deck_up).normalized()
	_model.global_transform = Transform3D(Basis(-right, deck_up, fwd).scaled(_model.scale), stand)
	# the upper body on its spring: pushed by how her deck lurches under the feet, and straightening
	# up against her tilt
	if _stand_was != Vector3.INF and delta > 0.0:
		# the deck's speed and lurch, smoothed: she moves in physics steps that don't line up with
		# drawn frames, so taken raw, frame to frame, they are mostly that stepping, and the body
		# shook with it
		var v := (stand - _stand_was) / delta
		var was_v := _stand_v
		_stand_v = _stand_v.lerp(v, 1.0 - exp(-delta / SWAY_SMOOTH))
		_lurch = _lurch.lerp((_stand_v - was_v) / delta, 1.0 - exp(-delta / SWAY_SMOOTH))
		var lurch := _lurch
		var tilt_fwd := asin(clampf(Vector3.UP.dot(fwd), -1.0, 1.0)) # world up leans this way off her deck
		var tilt_right := asin(clampf(Vector3.UP.dot(right), -1.0, 1.0))
		var target := Vector2(-lurch.dot(fwd) * sway_push + tilt_fwd * sway_upright,
				-lurch.dot(right) * sway_push + tilt_right * sway_upright)
		var limit := deg_to_rad(sway_max)
		target = Vector2(clampf(target.x, -limit, limit), clampf(target.y, -limit, limit))
		var w := TAU * sway_hz
		_lean_v += (w * w * (target - _lean) - 2.0 * sway_damping * w * _lean_v) * delta
		_lean += _lean_v * delta
	_stand_was = stand
	_rig.lean = _lean
	_hands(right, delta)
	# the eyes carry the camera now (it turns as the player looks; the body stays square)
	var eyes := _skel.global_transform * _skel.get_bone_global_pose(_head_bone) * _eye_in_head
	_pivot.global_position = eyes + Basis(Vector3.UP, view_yaw) * Vector3(0.0, 0.0, -eye_back)

## The turn that squares the shoulders to the way the body faces: the standing clip carries its
## torso a little turned (the right shoulder back), which at the wheel leaves one hand short.
func _square_shoulders() -> float:
	var l := _skel.get_bone_global_pose(_skel.find_bone('upperarm_l')).origin
	var r := _skel.get_bone_global_pose(_skel.find_bone('upperarm_r')).origin
	var across := l - r # the body's left, in the skeleton's space (it faces +Z)
	# the spine below the shoulders takes only part of the twist (the neck the rest; see body_rig.gd)
	return atan2(across.z, across.x) / BodyRig.SHOULDER_SHARE

## Off the helm: the camera goes back where the Head carries it, the hands let go, the back unbends.
func _leave_helm() -> void:
	if _pivot and _pivot.position != _pivot_rest:
		_pivot.position = _pivot_rest
	_rig.hand_l = Vector3.INF
	_rig.hand_r = Vector3.INF
	_rig.wheel_center = Vector3.INF
	_rig.grip_l = 0.0
	_rig.grip_r = 0.0
	_rig.lean = Vector2.ZERO
	_lean = Vector2.ZERO
	_lean_v = Vector2.ZERO
	_stand_was = Vector3.INF
	_stand_v = Vector3.ZERO
	_lurch = Vector3.ZERO
	_hold = [-1, -1]
	_regrip = [-1.0, -1.0]

## Each hand holds a handle near its home (hand_home either side of the top), and is carried round
## with it as the wheel turns. Carried hand_reach past home, it lets go and takes the free handle
## nearest home again, in a short lifted reach (one hand at a time: the other keeps the wheel), the
## way a helmsman goes hand over hand on a big turn.
func _hands(right: Vector3, delta: float) -> void:
	var axle := (_wheel.global_basis * _wheel_axle).normalized()
	var top := Vector3.UP - axle * Vector3.UP.dot(axle)
	top = top.normalized()
	var side := (right - axle * right.dot(axle)).normalized() # the helmsman's right, on the wheel
	var clock := func(h: Node3D) -> float: # degrees round from the top, clockwise as he sees it
		var d := h.global_position - _wheel.global_position
		return rad_to_deg(atan2(d.dot(side), d.dot(top)))
	var home := [-hand_home, hand_home]
	# how far each hand can reach from its shoulder (an arm and a palm, a little short of straight)
	var shoulders: Array[Vector3] = []
	for k in 2:
		var b := _skel.find_bone('upperarm_l' if k == 0 else 'upperarm_r')
		shoulders.append(_skel.global_transform * _skel.get_bone_global_pose(b).origin)
	if _arm_reach <= 0.0:
		var sc := _skel.global_transform.basis.get_scale().x
		var r := func(a: String, b: String) -> float:
			return _skel.get_bone_global_rest(_skel.find_bone(a)).origin.distance_to(_skel.get_bone_global_rest(_skel.find_bone(b)).origin)
		_arm_reach = (r.call('upperarm_l', 'lowerarm_l') + r.call('lowerarm_l', 'hand_l') + r.call('hand_l', 'middle_01_l') * 0.6) * sc * 0.97
	var reachable := func(i: int, k: int) -> bool:
		return shoulders[k].distance_to(_handles[i].global_position) < _arm_reach
	for k in 2:
		if _hold[k] < 0: # just took the helm: the handle nearest home
			_hold[k] = _nearest(clock, home[k], _hold[1 - k], reachable.bind(k))
	for k in 2:
		var other := 1 - k
		if _regrip[k] < 0.0 and _regrip[other] < 0.0:
			var off := angle_difference(deg_to_rad(home[k]), deg_to_rad(clock.call(_handles[_hold[k]])))
			# carried too far round, or out of the arm's reach: let go and take a better handle
			if absf(off) > deg_to_rad(hand_reach) or not reachable.call(_hold[k], k):
				var next := _nearest(clock, home[k], _hold[other], reachable.bind(k))
				if next != _hold[k]:
					_regrip_from[k] = _handles[_hold[k]].global_position
					_hold[k] = next
					_regrip[k] = 0.0
	var to_sk := _skel.global_transform.affine_inverse()
	var toward_me: Vector3 = -_model.global_basis.z.normalized() # the body faces the wheel along +Z
	var targets: Array[Vector3] = []
	var grips: Array[float] = []
	for k in 2:
		var at: Vector3 = _handles[_hold[k]].global_position
		var grip := 1.0
		if _regrip[k] >= 0.0:
			_regrip[k] += delta
			var t := clampf(_regrip[k] / maxf(regrip_time, 0.01), 0.0, 1.0)
			var arc := sin(t * PI)
			# let go, lift off toward the chest a little, and take the new handle
			at = (_regrip_from[k] as Vector3).lerp(at, smoothstep(0.0, 1.0, t)) + toward_me * arc * 0.12 + Vector3.UP * arc * 0.06
			grip = maxf(1.0 - arc, 0.2) # opens to let go and take the next handle
			if t >= 1.0:
				_regrip[k] = -1.0
		targets.append(at)
		grips.append(grip)
	var down := Vector3.DOWN * 0.6
	_rig.hand_l = to_sk * targets[0]
	_rig.hand_r = to_sk * targets[1]
	_rig.pole_l = to_sk * (targets[0] + down - right * 0.5)
	_rig.pole_r = to_sk * (targets[1] + down + right * 0.5)
	# how the hands hold: the sliders on the Player (its 'Body at the Helm' group), read live
	var p = player
	_rig.grip_l = grips[0] * p.grip_closure
	_rig.grip_r = grips[1] * p.grip_closure
	_rig.grip_depth = p.grip_depth
	_rig.wrist = Vector3(deg_to_rad(p.wrist_bend), deg_to_rad(p.wrist_twist), deg_to_rad(p.wrist_tilt))
	_rig.thumb = Vector2(deg_to_rad(p.thumb_pitch), deg_to_rad(p.thumb_turn))
	_rig.lock_wrist = Vector3(deg_to_rad(p.lock_wrist_bend), deg_to_rad(p.lock_wrist_twist), deg_to_rad(p.lock_wrist_tilt))
	# the wheel, for the hands to stay locked to their spokes as it turns
	_rig.wheel_center = to_sk * _wheel.global_position
	_rig.wheel_axle = to_sk.basis * axle
	for k in 2:
		var c := deg_to_rad(home[k]) # home[k] degrees round from the top, as clock() counts
		var home_dir := top * cos(c) + side * sin(c)
		if k == 0:
			_rig.home_l = to_sk.basis * home_dir
		else:
			_rig.home_r = to_sk.basis * home_dir

## The handle nearest `home` degrees round, other than `taken`; one in reach (`reachable`) if any is.
func _nearest(clock: Callable, home: float, taken: int, reachable: Callable) -> int:
	var best := -1
	var best_off := INF
	for i in _handles.size():
		if i == taken:
			continue
		var off := absf(angle_difference(deg_to_rad(home), deg_to_rad(clock.call(_handles[i]))))
		if not reachable.call(i):
			off += 1000.0 # only if nothing in reach
		if off < best_off:
			best_off = off
			best = i
	return best

## Picks the clip and moves it on (in steps, if anim_fps is set).
func _animate(delta: float) -> void:
	var pick := _pick(delta)
	if pick[0] != _current:
		_play(pick[0])
	_anim.speed_scale = pick[1]
	if anim_fps > 0.0:
		_step_left -= delta
		if _step_left <= 0.0:
			var step := 1.0 / anim_fps
			_anim.advance(step - _step_left)
			_step_left += step
	else:
		_anim.advance(delta)

func _play(clip: StringName) -> void:
	if _anim.has_animation(clip):
		_anim.play(clip)
		_current = clip

## [clip, speed] for what the player is doing now.
func _pick(delta: float) -> Array:
	var p = player
	var flat := Vector2(p.velocity.x, p.velocity.z)
	var facing := -(p.head as Node3D).global_basis.z
	var ahead := flat.dot(Vector2(facing.x, facing.z)) # forward speed, < 0 backing off
	var speed := flat.length()
	var dir := -1.0 if ahead < -0.1 else 1.0 # walk the clip backwards when backing up
	if p.state == p.State.PILOT:
		return [&'Idle', 1.0] # standing at the wheel; the hands and back are posed by the rig
	if p.state == p.State.SWIM:
		if speed > 0.3:
			return [&'Swim_Fwd', clampf(speed / swim_pace, 0.5, 2.0)]
		return [&'Swim_Idle', 1.0]
	if p.state != p.State.WALK:
		return [&'Idle', 1.0] # at a station, on a ladder
	if p.is_on_floor():
		if _airborne > 0.35:
			_landing = 0.35 # came down from a real fall or jump
		_airborne = 0.0
	else:
		_airborne += delta
	if _airborne > 0.15:
		return [&'Jump', 1.0]
	if _landing > 0.0:
		_landing -= delta
		return [&'Jump_Land', 1.0]
	if speed < 0.3:
		return [&'Idle', 1.0]
	if speed > p.walk_speed + 0.5:
		return [&'Sprint', dir * clampf(speed / sprint_pace, 0.6, 2.0)]
	if speed > walk_pace * 1.6:
		return [&'Jog_Fwd', dir * clampf(speed / jog_pace, 0.6, 2.0)]
	return [&'Walk', dir * clampf(speed / walk_pace, 0.5, 2.0)]
