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
## Where the hands hold the wheel: degrees either side of its top.
@export var grip_angle := 50.0
## How far (degrees) the hands go round with the wheel before they would have to let go.
@export var grip_follow := 40.0
## Where on the wheel the hands hold, from its middle (0) to the tips of its handles (1).
@export_range(0.3, 1.0, 0.01) var rim := 0.78

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
var _wheel_up := Vector3.UP # the wheel's top at rest, in its own space
var _wheel_radius := 0.4

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
	_face(yaw, delta)
	_model.global_basis = Basis(Vector3.UP, _yaw + PI).scaled(_model.scale)
	_rig.twist = clampf(angle_difference(_yaw, yaw), -deg_to_rad(max_twist), deg_to_rad(max_twist))
	_hands_on_wheel()
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
	if p.state == p.State.PILOT and _wheel_for(p.piloted_ship):
		var to := _wheel.global_position - (p.head as Node3D).global_position
		_yaw = lerp_angle(_yaw, atan2(-to.x, -to.z), 1.0 - exp(-12.0 * delta))
	elif p.state == p.State.SWIM or moving:
		_yaw = lerp_angle(_yaw, view_yaw, 1.0 - exp(-10.0 * delta))
	else:
		var off := angle_difference(_yaw, view_yaw)
		var limit := deg_to_rad(free_look)
		if absf(off) > limit:
			_yaw = wrapf(_yaw + off - signf(off) * limit, -PI, PI)

## The ship's wheel (the node the helm turns: her `steering_hinge`), found once per ship: its axle
## and its size, from the meshes on it.
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
		# its reach: the farthest of its points from the axle (the tips of the spoke handles); the
		# hands hold a little inside that, on the rim
		var to_local := _wheel.global_transform.affine_inverse()
		var reach := 0.0
		for m: MeshInstance3D in _wheel.find_children('*', 'MeshInstance3D', true, false):
			var xf := to_local * m.global_transform
			for s in m.mesh.get_surface_count():
				for v: Vector3 in m.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
					var q := xf * v
					reach = maxf(reach, (q - _wheel_axle * q.dot(_wheel_axle)).length())
		_wheel_radius = reach * _wheel.global_basis.get_scale().x * rim
		var up := _wheel.global_basis.inverse() * Vector3.UP
		_wheel_up = (up - _wheel_axle * up.dot(_wheel_axle)).normalized() # its top, now (at rest)
	return _wheel != null

## At the helm the hands hold two spokes near the top of the wheel and go round with it (a little:
## past grip_follow a real helmsman would let go and take a new hold).
func _hands_on_wheel() -> void:
	var p = player
	if p.state != p.State.PILOT or _wheel == null or not _wheel_for(p.piloted_ship):
		_rig.hand_l = Vector3.INF
		_rig.hand_r = Vector3.INF
		return
	var wb := _wheel.global_basis
	var axle := (wb * _wheel_axle).normalized()
	var top := Vector3.UP - axle * Vector3.UP.dot(axle) # the top of the wheel as it stands, upright
	top = top.normalized()
	var turned := top.signed_angle_to((wb * _wheel_up).normalized(), axle) # how far it has gone round
	var follow := clampf(turned, -deg_to_rad(grip_follow), deg_to_rad(grip_follow))
	var to_sk := _skel.global_transform.affine_inverse()
	var body_right: Vector3 = _model.global_basis.x.normalized() * -1.0 # the model faces +Z
	var grips: Array[Vector3] = []
	for sgn: float in [1.0, -1.0]:
		var spoke := Basis(axle, follow + sgn * deg_to_rad(grip_angle)) * top
		grips.append(_wheel.global_position + spoke * _wheel_radius)
	if (grips[0] - grips[1]).dot(body_right) > 0.0:
		grips.reverse() # [left hand's, right hand's]
	var down := Vector3.DOWN * 0.6
	_rig.hand_l = to_sk * grips[0]
	_rig.hand_r = to_sk * grips[1]
	_rig.pole_l = to_sk * (grips[0] + down - body_right * 0.5)
	_rig.pole_r = to_sk * (grips[1] + down + body_right * 0.5)

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
		return [&'Driving', 1.0]
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
