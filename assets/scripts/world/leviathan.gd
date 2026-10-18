class_name Leviathan extends Node3D
## Something ancient and colossal, shaped like a basking shark, that swims half out of the sea with
## its mouth always open. It eats lit ships. LeviathanEncounter brings it: begin() places it deep
## below the surface (it never pops into view) and it plays out one encounter, then frees itself.
## Too big to turn on the spot, it always swims on a curve (tuned in
## backups/leviathan_replays/leviathan_tuning.html, which these defaults come from):
##
##  - RISE: swims up from the deep on a gentle drifting curve. Shortly before it breaks the surface
##    its call is heard (call_lead s ahead), then silence; it surfaces ~surface_distance off. Its
##    WaterDeformers swell, break and calm the sea.
##  - DRIFT: the ship is dark, it does not know she is there. Its curve was aimed at spawn to pass
##    dark_gap_min..max off her flank; it passes, then goes down (PASSED, DIVE).
##  - HUNT: the ship is lit: it curves in on her at chase_speed. If she gets inside the circle it
##    can turn, it swims straight out (RUNUP) until she is run_up_margin outside it, then turns in
##    again. Within lunge_distance its head swings round as tight as lunge_turn_radius and the sea
##    flows into its mouth (suction_*), faster than she can sail.
##  - COMMIT: lit inside judge_distance: it comes for her at hunt_speed. Cut the power now and it
##    is too late: it holds its course.
##  - MISS: the power was cut before judge_distance: it carries on past her, cut_gap off its
##    flank, and goes down dive_after_min..max m past her. Lights on again before it goes down: it
##    comes round for her (return_multiplier faster, return_judge_distance, return_turn_radius);
##    cut again in time and it passes return_gap off. A lit ship it missed is hunted again.
##  - DIVE: sinks away to despawn_depth and is gone.
## A lure (group "leviathan_lure") within lure_range draws it while the ship is dark.
## Anything in its MouthZone is swallowed: the player can only look around while they are drawn
## down the gullet (the Gullet markers) for swallow_time s, the last fade_time s fading to black,
## then they die. The ship goes in with them, carried in the mouth.
##
## Body: the Head (mouth at the origin, the body toward +Z) is rigid; the Body's segments are laid
## along the path the head swam, so the long body bends through the curves behind it. The scene is
## built at MODEL_LENGTH; body_length scales the whole creature.

enum State { RISE, DRIFT, HUNT, RUNUP, COMMIT, MISS, PASSED, DIVE, SWALLOW }

const MODEL_LENGTH := 500.0 # m: the length the scene is built at
const TAKEN_META := &'leviathan_taken' # on a ship it carried off: the encounter gives her back at dawn
const TRAIL_STEP := 4.0 # m (model units) between remembered head positions
const MOUTH_REACH := 35.0 # m: the ship this far past the mouth has slipped by
const HEAD_LENGTH := 160.0 # m (model units) from the mouth to where the Body's segments begin

## Length of the body (m). Everything (mouth, turns, water, gullet) scales with it.
@export_range(50.0, 2000.0, 1.0, 'or_greater') var body_length := 500.0
## Body axis height above sea level while at the surface (m). 0 = half out of the water.
@export var surface_offset := 0.0

@export_group('Rising')
## How deep it starts and ends (m below sea level).
@export var despawn_depth := 250.0
@export var rise_speed := 12.0 # m/s forward while rising
@export var rise_climb := 5.0 # m/s fastest climb; it eases off near the surface
## Seconds to ease out of the climb: higher = a slower, gentler surfacing.
@export var rise_ease := 6.0
## How far from the ship it breaks the surface (m). Used to place it.
@export var surface_distance := 1000.0
## Seconds before it breaks the surface that its call is heard (the call is ~5 s, then silence).
@export var call_lead := 10.0

@export_group('Swimming')
@export var cruise_speed := 9.0 # m/s when it is not after anything
@export var chase_speed := 17.0 # m/s chasing a lit ship
@export var hunt_speed := 20.0 # m/s inside the safe distance
## Speed (and safe distance, turn) once it came back for a ship that lit up again.
@export var return_multiplier := 1.5
@export var acceleration := 0.6 # m/s²
@export var vertical_acceleration := 1.0 # m/s²
## Its gentle drifting curve (m radius) when it is after nothing.
@export var drift_radius := 3000.0
@export var hunt_turn_radius := 500.0 # m, tightest whole-body turn while hunting
@export var return_turn_radius := 600.0 # m, ... coming back
## Seconds to go from straight to its tightest turn.
@export var steer_ease := 8.0
## Most the head tilts nose up or down (degrees) as it climbs or sinks.
@export var max_pitch := 15.0
@export var tail_sway := 8.0 # degrees
@export var tail_period := 9.0 # s

@export_group('Passing by')
## Gaps between its flank and the ship as it passes (m).
@export var dark_gap_min := 100.0 # dark from the start: it never knew she was there
@export var dark_gap_max := 200.0
@export var cut_gap := 50.0 # lights cut in time
@export var return_gap := 30.0 # cut again after it came back
## How far past the ship it goes down (m).
@export var dive_after_min := 200.0
@export var dive_after_max := 500.0
@export var sink_speed := 5.0 # m/s

@export_group('The lunge')
## Within this distance of the ship its head swings round tighter than the body can turn.
@export var lunge_distance := 450.0
@export var lunge_turn_radius := 100.0
## She is inside the circle it can turn: it swims straight until she is this far outside it (m).
@export var run_up_margin := 150.0
## Hunting, the sea flows into its mouth from up to suction_range m ahead (within ±suction_cone
## degrees), at up to suction_flow m/s at the mouth. The ship does 10 m/s flat out.
@export var suction_range := 250.0
@export var suction_flow := 20.0
@export var suction_cone := 60.0

@export_group('Judging the ship')
## Mouth to ship distance (m) inside which cutting the lights is too late.
@export var judge_distance := 200.0
@export var return_judge_distance := 300.0
## A lure (group "leviathan_lure") this close draws it while the ship is dark (m).
@export var lure_range := 400.0

@export_group('Swallowing')
## Seconds the swallowed player is drawn down the gullet before they die.
@export var swallow_time := 15.0
## The last seconds of it fade to black.
@export var fade_time := 3.0
@export var swallow_speed := 2.0 # m/s it swims on while swallowing
@export var swallow_shake := 0.3 # camera trauma held while swallowed

var state := State.RISE
var ship: RigidBody3D
var player: Node3D
var water: Node3D

@onready var _head: Node3D = $Head
@onready var _mouth_zone: Area3D = $Head/MouthZone
@onready var _call_sound: AudioStreamPlayer3D = get_node_or_null(^'Head/CallSound')
@onready var _surface_sound: AudioStreamPlayer3D = get_node_or_null(^'Head/SurfaceSound')
@onready var _suction_sound: AudioStreamPlayer3D = get_node_or_null(^'Head/SuctionSound')

var _k := 1.0 # body_length / MODEL_LENGTH
var _yaw := 0.0
var _pitch := 0.0
var _speed := 0.0
var _vy := 0.0
var _curve := 0.0 # its turn: yaw change per m swum (1 / radius); + = yaw increasing
var _curve_target := 0.0
var _lit := true
var _returned := false # came back for a ship that lit up again
var _called := false
var _surfaced := false
var _min_d := INF # closest it has been to her on this pass
var _swum := 0.0 # m swum so far
var _passed_at := 0.0
var _dive_after := 0.0
var _drift_passed := false
var _ship_vel := Vector3.ZERO # her velocity, averaged over a few seconds
var _drift := Vector3.ZERO # the current its suction moves her with
var _trail := PackedVector3Array() # where the head has been, newest first, TRAIL_STEP apart
var _segments: Array[Node3D] = []
var _seg_offsets: Array[float] = [] # m behind the mouth (model units)
var _tail: Node3D
var _tail_rest := Basis.IDENTITY
var _rng := RandomNumberGenerator.new()
var _gullet: Array[Node3D] = []
var _swallow_t := -1.0 # s since the player was swallowed (< 0: not yet)
var _path: Array[Vector3] = [] # the swallowed player's way down, in the head's (unscaled) space
var _ship_local := Transform3D.IDENTITY # a carried ship, in the head's (unscaled) space
var _ship_held := false
var _died := false
var _fade: ColorRect

func _ready() -> void:
	_k = body_length / MODEL_LENGTH
	scale = Vector3.ONE * _k
	_rng.randomize()
	for name in ['Gullet0', 'Gullet1', 'Gullet2', 'Gullet3']:
		var m := _head.get_node_or_null(NodePath(name)) as Node3D
		if m:
			_gullet.append(m)
	var body := get_node_or_null(^'Body')
	if body:
		for seg in body.get_children():
			if seg is Node3D:
				_segments.append(seg)
				_seg_offsets.append(seg.position.z)
				seg.top_level = true # laid on the path by _place_body
	_head.top_level = true # so is the head
	_tail = find_child('Tail', true, false) as Node3D
	if _tail:
		_tail_rest = _tail.basis
	for d in find_children('*', 'WaterDeformer', true, false):
		_scale_deformer(d)
	_mouth_zone.body_entered.connect(_on_mouth_body_entered)
	_fill_sounds()
	EventBus.day_started.connect(_on_day_started)

## Places it despawn_depth under the sea, far enough off that it surfaces ~surface_distance from
## the ship along `bearing` (a flat direction from the ship), on a curve that would carry it past
## her dark_gap off its flank.
func begin(p_ship: RigidBody3D, p_player: Node3D, p_water: Node3D, bearing: Vector3) -> void:
	ship = p_ship
	player = p_player
	water = p_water
	bearing.y = 0.0
	bearing = bearing.normalized()
	# the run it swims climbing up until its back breaks the surface
	var run := maxf(despawn_depth - _radius(), 0.0) / maxf(rise_climb, 0.1) * rise_speed
	var origin := ship.global_position + bearing * (surface_distance + run)
	origin.y = _sea() - despawn_depth
	_curve = (1.0 if _rng.randf() < 0.5 else -1.0) / (drift_radius * _k)
	_curve_target = _curve
	# aim the drifting curve so that, unseen, it passes her dark_gap off its flank
	var gap := _rng.randf_range(dark_gap_min, dark_gap_max)
	var at := Vector2(origin.x, origin.z)
	var toward := _yaw_of(-bearing)
	var best_err := INF
	_yaw = toward
	for i in range(-60, 61):
		var yaw := toward + deg_to_rad(i)
		var c := _closest(at, yaw, _curve, _ship2(), 9000.0)
		var err := absf(c.x - (gap + _radius()))
		if c.y > run and err < best_err:
			best_err = err
			_yaw = yaw
	_speed = rise_speed
	_vy = rise_climb
	global_transform = Transform3D(_basis(), origin)
	_lit = _ship_lit()
	# the body lies straight out behind the head
	_trail.clear()
	var back := -_flat_dir(_yaw) * TRAIL_STEP * _k
	for i in int(ceil(_trail_length() / (TRAIL_STEP * _k))) + 2:
		_trail.append(origin + back * i)
	_place_body()
	_set_state(State.RISE)

## Where its mouth is.
func mouth_position() -> Vector3:
	return global_position

func is_swallowing() -> bool:
	return state == State.SWALLOW

func _physics_process(delta: float) -> void:
	if ship == null or water == null or delta <= 0.0:
		return
	var d := _mouth_to_ship()
	var flat_vel := Vector3(ship.linear_velocity.x, 0.0, ship.linear_velocity.z)
	_ship_vel = _ship_vel.lerp(flat_vel, minf(1.0, delta / 5.0))
	var lit := _ship_lit()
	if lit != _lit:
		_lit = lit
		_on_lights()
	var target_speed := cruise_speed * _mult()
	match state:
		State.RISE: target_speed = _process_rise(delta)
		State.DRIFT: _process_drift(d)
		State.HUNT, State.COMMIT: target_speed = _process_hunt(d)
		State.RUNUP: target_speed = _process_runup()
		State.MISS: _process_miss(d)
		State.PASSED: _process_passed()
		State.DIVE:
			if _process_dive(delta):
				return
		State.SWALLOW: target_speed = _process_swallow(delta)
	if state != State.RISE and state != State.DIVE:
		_hold_surface(delta)
	# its turn eases toward the one it wants
	var mk := _max_curve()
	_curve += clampf(_curve_target - _curve, -mk * delta / steer_ease, mk * delta / steer_ease)
	_speed = move_toward(_speed, target_speed, acceleration * delta)
	_move(delta)
	if state != State.RISE:
		_min_d = minf(_min_d, _mouth_to_ship())
	_suck(d, delta)
	_place_body()
	_sway_tail()
	if _ship_held:
		_carry_ship(delta)

## ---- states --------------------------------------------------------------------

func _process_rise(delta: float) -> float:
	var gap := _surface_y() - global_position.y
	_climb_to(clampf(gap / rise_ease, 0.0, rise_climb), delta)
	# the call, heard a little before it breaks the surface
	var top := global_position.y + _radius()
	var eta := (_sea() - top) / maxf(_vy, 0.5)
	if not _called and eta <= call_lead:
		_called = true
		_play(_call_sound)
	if not _surfaced and top > _sea():
		_surfaced = true
		_play(_surface_sound)
	if gap < 2.0:
		_set_state(State.HUNT if _lit else State.DRIFT)
	return rise_speed

## Never knowing she is there, it holds its curve and passes her.
func _process_drift(d: float) -> void:
	_steer_at_lure()
	if not _drift_passed and not _ahead() and d > _min_d + 2.0:
		_drift_passed = true
		_begin_passed()

func _process_hunt(d: float) -> float:
	var speed := (hunt_speed if state == State.COMMIT else chase_speed) * _mult()
	if not _lit:
		return maxf(_speed * 0.999, cruise_speed * _mult()) # too late: it holds its course
	# she is inside the circle it can turn: out, then back at her in a line
	if state == State.HUNT and d > lunge_distance and _facing() > PI / 6.0 and _turn_circle_gap() < 0.0:
		_set_state(State.RUNUP)
		return speed
	# steer for where she will be by the time it gets there
	var t := minf(d / maxf(_speed, 1.0), 20.0)
	var to := ship.global_position + _ship_vel * t - global_position
	var angle := wrapf(_yaw_of(to) - _yaw, -PI, PI)
	var mk := _max_curve()
	_curve_target = clampf(angle / (4.0 * maxf(_speed, 1.0)), -mk, mk)
	var jd := return_judge_distance if _returned else judge_distance
	if state == State.HUNT and d <= jd and _facing() < PI / 4.0:
		_set_state(State.COMMIT)
	elif state == State.COMMIT and not _ahead() and d > MOUTH_REACH * 3.0:
		_min_d = d
		_begin_passed() # she slipped past its mouth: while lit it comes round for her
	_shake_with_closeness(d)
	return speed

func _process_runup() -> float:
	_curve_target = 0.0
	if _turn_circle_gap() > run_up_margin * _k:
		_set_state(State.HUNT)
	return chase_speed * _mult()

func _process_miss(d: float) -> void:
	_steer_at_lure()
	if not _ahead() and d > _min_d + 2.0:
		_begin_passed()

func _process_passed() -> void:
	if _lit:
		_returned = true # lit after it went by: it comes round for her
		_set_state(State.HUNT)
	elif _swum - _passed_at >= _dive_after:
		_set_state(State.DIVE)
	else:
		_steer_at_lure()

## Returns true once it is gone.
func _process_dive(delta: float) -> bool:
	_climb_to(-sink_speed, delta, 0.6)
	_set_suction(false)
	if global_position.y < _sea() - despawn_depth:
		if _ship_held:
			# she stays down there with it, out of sight, until the morning gives her back
			ship.visible = false
			ship.set_meta(TAKEN_META, true)
		queue_free()
		return true
	return false

func _process_swallow(delta: float) -> float:
	_curve_target = 0.0
	_swallow_t += delta
	var t := clampf(_swallow_t / swallow_time, 0.0, 1.0)
	player.global_position = _frame() * _along_path(smoothstep(0.0, 1.0, t))
	EventBus.camera_shake_requested.emit(swallow_shake * (1.0 - t * 0.5))
	if _fade:
		_fade.modulate.a = smoothstep(swallow_time - fade_time, swallow_time, _swallow_t)
	if t >= 1.0 and not _died:
		_died = true
		EventBus.player_died.emit() # the mission controller restages the morning
	return swallow_speed

## The ship's power changed.
func _on_lights() -> void:
	if not _lit and (state == State.HUNT or state == State.RUNUP):
		# in time: it no longer steers for her and carries on past
		_curve_target = _plan_pass(return_gap if _returned else cut_gap)
		_min_d = INF
		_set_state(State.MISS)
	elif _lit and (state == State.DRIFT or state == State.MISS or state == State.PASSED):
		if state != State.DRIFT:
			_returned = true # it had gone by her: it comes round faster
		_set_state(State.HUNT)

func _begin_passed() -> void:
	_passed_at = _swum
	_dive_after = _rng.randf_range(dive_after_min, dive_after_max)
	_set_state(State.PASSED)

func _steer_at_lure() -> void:
	var lure := _lure()
	if lure:
		var angle := wrapf(_yaw_of(lure.global_position - global_position) - _yaw, -PI, PI)
		var mk := _max_curve()
		_curve_target = clampf(angle / (4.0 * maxf(_speed, 1.0)), -mk, mk)

## ---- swallowing ----------------------------------------------------------------

func _on_mouth_body_entered(body: Node3D) -> void:
	if body == player and _swallow_t < 0.0:
		_swallow_player()
	elif body == ship and not _ship_held and not ship.freeze:
		_take_ship()

func _swallow_player() -> void:
	if player.has_method(&'release_controls'):
		player.release_controls()
	if player.has_method(&'set_captured'):
		player.set_captured(true)
	_swallow_t = 0.0
	var inv := _frame().affine_inverse()
	_path = [inv * player.global_position]
	for m in _gullet:
		_path.append(inv * m.global_position)
	_make_fade()
	_set_suction(true)
	_set_state(State.SWALLOW)

## Carried in the mouth from now on, drawn in toward the gullet. Fed, it goes back down -- with
## anyone still aboard her swallowed along with her.
func _take_ship() -> void:
	_ship_held = true
	_drift = Vector3.ZERO
	ship.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	ship.freeze = true
	ship.linear_velocity = Vector3.ZERO
	ship.angular_velocity = Vector3.ZERO
	_ship_local = _frame().affine_inverse() * ship.global_transform
	_set_suction(true)
	if player.has_method(&'ship_aboard') and player.ship_aboard() == ship and _swallow_t < 0.0:
		_swallow_player()
	elif state != State.SWALLOW:
		_set_state(State.DIVE)

func _carry_ship(delta: float) -> void:
	if not is_instance_valid(ship):
		_ship_held = false
		return
	if _gullet.size() > 1:
		var goal := _frame().affine_inverse() * _gullet[1].global_position
		goal.y = _ship_local.origin.y # she floats in on the water it takes in
		_ship_local.origin = _ship_local.origin.move_toward(goal, delta * maxf(body_length * 0.01, 1.0))
	ship.global_transform = _frame() * _ship_local

## A point along the swallowed player's way down, t 0..1, in head space.
func _along_path(t: float) -> Vector3:
	if _path.size() < 2:
		return _path[0] if _path.size() > 0 else Vector3.ZERO
	var lengths: Array[float] = []
	var total := 0.0
	for i in _path.size() - 1:
		var l := _path[i].distance_to(_path[i + 1])
		lengths.append(l)
		total += l
	var d := t * total
	for i in lengths.size():
		if d <= lengths[i] or i == lengths.size() - 1:
			return _path[i].lerp(_path[i + 1], clampf(d / maxf(lengths[i], 0.001), 0.0, 1.0))
		d -= lengths[i]
	return _path[-1]

func _make_fade() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 90
	_fade = ColorRect.new()
	_fade.color = Color.BLACK
	_fade.modulate.a = 0.0
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)
	add_child(layer)

## Hunting, the sea runs into its mouth: a current that carries her toward it, faster than she can
## sail near the mouth.
func _suck(d: float, delta: float) -> void:
	var flow := Vector3.ZERO
	var reach := suction_range * _k
	var hunting := state == State.HUNT or state == State.COMMIT
	if _lit and hunting and not _ship_held and not ship.freeze and d < reach and d > 1.0 \
			and global_position.y > _sea() - _radius() and _facing() < deg_to_rad(suction_cone):
		var to := global_position - ship.global_position
		to.y = 0.0
		flow = to.normalized() * suction_flow * (1.0 - d / reach)
	_drift = _drift.lerp(flow, minf(1.0, delta / 1.5))
	if _drift.length() > 0.01 and not ship.freeze:
		ship.global_position += _drift * delta
	_set_suction(flow.length() > 0.5 or state == State.SWALLOW)

## A new morning puts everything back: the ship, the player's body, the view.
func _on_day_started(_day: int) -> void:
	if _ship_held and is_instance_valid(ship):
		ship.freeze = false
		ship.visible = true
	if _swallow_t >= 0.0 and player and player.has_method(&'set_captured'):
		player.set_captured(false)
	queue_free()

## ---- movement ------------------------------------------------------------------

## Forward along its heading, turning by its curve, plus its climb or sink. The head is laid down
## on the trail the body follows.
func _move(delta: float) -> void:
	_yaw += _curve * _speed * delta
	global_position += _flat_dir(_yaw) * _speed * delta + Vector3.UP * _vy * delta
	_swum += _speed * delta
	var climb := atan2(_vy, maxf(_speed, 1.0))
	var limit := deg_to_rad(max_pitch)
	_pitch = lerpf(_pitch, clampf(climb, -limit, limit), 1.0 - exp(-0.5 * delta))
	global_basis = _basis()
	if _trail.is_empty() or _trail[0].distance_to(global_position) >= TRAIL_STEP * _k:
		_trail.insert(0, global_position)
		var keep := int(ceil(_trail_length() / (TRAIL_STEP * _k))) + 3
		if _trail.size() > keep:
			_trail.resize(keep)

## Each body segment where the head was, that far back along its path, facing along it.
func _place_body() -> void:
	# for each segment: a little ahead of it, where it is, a little behind it (all in order down the
	# body, so one walk along the trail finds them all)
	var wants := PackedFloat32Array([HEAD_LENGTH * _k])
	for o in _seg_offsets:
		var back := o * _k
		wants.append(maxf(back - 6.0 * _k, 0.0))
		wants.append(back)
		wants.append(back + 6.0 * _k)
	var pts := _trail_points(wants)
	var s := Vector3.ONE * _k
	# the head lies from the mouth back to its neck on the path, so it meets the body on a bend
	var head_dir := global_position - pts[0]
	if head_dir.length() > 0.01:
		_head.global_transform = Transform3D(Basis.looking_at(head_dir.normalized(), Vector3.UP).scaled(s), global_position)
	for i in _segments.size():
		var dir := pts[1 + i * 3] - pts[1 + i * 3 + 2]
		if dir.length() < 0.01:
			dir = _flat_dir(_yaw)
		_segments[i].global_transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP).scaled(s), pts[1 + i * 3 + 1])

## The points `wants` m (ascending) behind the mouth along the path it swam.
func _trail_points(wants: PackedFloat32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var prev := global_position
	var walked := 0.0
	var j := 0
	var w := 0
	while w < wants.size():
		if j < _trail.size():
			var l := prev.distance_to(_trail[j])
			if walked + l >= wants[w] and l > 0.0001:
				out.append(prev.lerp(_trail[j], (wants[w] - walked) / l))
				w += 1
				continue
			walked += l
			prev = _trail[j]
			j += 1
		else:
			out.append(prev - _flat_dir(_yaw) * (wants[w] - walked)) # past the end: straight on
			w += 1
	return out

func _trail_length() -> float:
	var longest := MODEL_LENGTH
	for o in _seg_offsets:
		longest = maxf(longest, o + 40.0)
	return longest * _k

func _basis() -> Basis:
	return Basis.from_euler(Vector3(_pitch, _yaw, 0.0)).scaled(Vector3.ONE * _k)

func _climb_to(target: float, delta: float, accel := -1.0) -> void:
	_vy = move_toward(_vy, target, (vertical_acceleration if accel < 0.0 else accel) * delta)

func _hold_surface(delta: float) -> void:
	_climb_to(clampf((_surface_y() - global_position.y) / 4.0, -2.0, 2.0), delta)

func _sway_tail() -> void:
	if _tail:
		var a := deg_to_rad(tail_sway) * sin(TAU * Time.get_ticks_msec() / 1000.0 / tail_period)
		_tail.basis = _tail_rest.rotated(Vector3.UP, a)

## Tightest turn it can make right now, as a curve (1 / radius).
func _max_curve() -> float:
	var r := (return_turn_radius if _returned else hunt_turn_radius) * _k
	var hunting := state == State.HUNT or state == State.COMMIT
	if _lit and hunting and _mouth_to_ship() < lunge_distance:
		r = minf(r, lunge_turn_radius * _k)
	return 1.0 / maxf(r, 1.0)

## How far she is outside the circle it can turn toward her (m; negative = inside: it cannot reach
## her by turning).
func _turn_circle_gap() -> float:
	var r := 1.0 / _max_curve()
	var to := _ship2() - _pos2()
	var f := _flat2(_yaw)
	var n := to - f * to.dot(f)
	n = n.normalized() if n.length() > 0.01 else Vector2(-f.y, f.x)
	return _ship2().distance_to(_pos2() + n * r) - r

## Closest a path of constant curve passes `target`: (distance, m along the path to it).
func _closest(at: Vector2, yaw: float, curve: float, target: Vector2, max_s: float) -> Vector2:
	var best := INF
	var best_s := 0.0
	var s := 0.0
	var step := 16.0
	while s < max_s:
		var d := at.distance_to(target)
		if d < best:
			best = d
			best_s = s
		elif d > best + 400.0:
			break
		if absf(curve * s) > PI * 1.2:
			break
		yaw += curve * step
		at += _flat2(yaw) * step
		s += step
	return Vector2(best, best_s)

## A curve (within its tightest turn) that carries it past her `gap` m off its flank, changing its
## turn as little as it can.
func _plan_pass(gap: float) -> float:
	var want := gap + _radius()
	var mk := _max_curve()
	var best := _curve
	var best_err := INF
	for i in range(-40, 41):
		var c := mk * i / 40.0
		var r := _closest(_pos2(), _yaw, c, _ship2(), 6000.0)
		if r.y < 1.0:
			continue
		var err := absf(r.x - want) + absf(c - _curve) * 2000.0
		if err < best_err:
			best_err = err
			best = c
	return best

## ---- reading the world ---------------------------------------------------------

func _sea() -> float:
	return water.global_position.y

func _surface_y() -> float:
	return _sea() + surface_offset * _k

func _radius() -> float:
	return body_length * 0.1

func _mult() -> float:
	return return_multiplier if _returned else 1.0

## The head's own frame, without its scale: what carried things are held in.
func _frame() -> Transform3D:
	return Transform3D(_head.global_basis.orthonormalized(), _head.global_position)

func _ship_lit() -> bool:
	return ship.get(&'powered') != false

func _pos2() -> Vector2:
	return Vector2(global_position.x, global_position.z)

func _ship2() -> Vector2:
	return Vector2(ship.global_position.x, ship.global_position.z)

func _mouth_to_ship() -> float:
	return _pos2().distance_to(_ship2())

## She is in front of its mouth.
func _ahead() -> bool:
	return (_ship2() - _pos2()).dot(_flat2(_yaw)) > 0.0

## Angle between its heading and the way to her (radians).
func _facing() -> float:
	var to := _ship2() - _pos2()
	return absf(wrapf(_yaw_of(Vector3(to.x, 0.0, to.y)) - _yaw, -PI, PI))

func _lure() -> Node3D:
	var best: Node3D = null
	var best_d := lure_range
	for n in get_tree().get_nodes_in_group(&'leviathan_lure'):
		var d := (n as Node3D).global_position.distance_to(global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

func _shake_with_closeness(d: float) -> void:
	var reach := return_judge_distance if _returned else judge_distance
	if d < reach:
		EventBus.camera_shake_requested.emit(lerpf(0.05, 0.4, 1.0 - d / reach))

static func _yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)

static func _flat_dir(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

static func _flat2(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))

func _set_state(s: State) -> void:
	state = s

## ---- set-up --------------------------------------------------------------------

## The water shapes are in world meters: grow them with the body.
func _scale_deformer(d: WaterDeformer) -> void:
	d.radius *= _k
	d.max_lift *= _k
	d.influence_depth *= _k
	d.max_drawdown *= _k
	d.rebound_height *= _k
	d.ring_amplitude *= _k
	d.ring_width *= _k
	d.ring_speed *= sqrt(_k)

func _set_suction(on: bool) -> void:
	if _suction_sound == null or _suction_sound.stream == null:
		return
	if on and not _suction_sound.playing:
		_suction_sound.play()
	elif not on and _suction_sound.playing and state != State.SWALLOW:
		_suction_sound.stop()

func _play(p: AudioStreamPlayer3D) -> void:
	if p and p.stream:
		p.play()

## Placeholder sounds, made here, for any player still without a stream (see SOUNDS.md).
func _fill_sounds() -> void:
	if _call_sound and _call_sound.stream == null:
		_call_sound.stream = _make_call()
	if _surface_sound and _surface_sound.stream == null:
		_surface_sound.stream = _make_noise(7.0, 0.02, false)
	if _suction_sound and _suction_sound.stream == null:
		_suction_sound.stream = _make_noise(4.0, 0.05, true)

const RATE := 22050

## A long, low moan, falling and rising, like something singing very far down.
func _make_call() -> AudioStreamWAV:
	var seconds := 5.0
	var frames := int(RATE * seconds)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var phase := 0.0
	for i in frames:
		var t := float(i) / RATE
		var env := smoothstep(0.0, 0.8, t) * (1.0 - smoothstep(3.6, 5.0, t))
		var freq := 55.0 + 18.0 * sin(t * 1.3) - 8.0 * t
		phase += TAU * freq / RATE
		var s := sin(phase) * 0.6 + sin(phase * 2.01) * 0.25 + sin(phase * 3.03) * 0.12
		s *= env * (0.85 + 0.15 * sin(t * 23.0))
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 22000.0))
	return _wav(data, false)

## Low rushing water: filtered noise (`smooth` = one-pole filter weight; lower = deeper).
func _make_noise(seconds: float, smooth: float, loop: bool) -> AudioStreamWAV:
	var frames := int(RATE * seconds)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var y := 0.0
	for i in frames:
		var t := float(i) / RATE
		y = lerpf(y, rng.randf_range(-1.0, 1.0), smooth)
		var env := 1.0 if loop else smoothstep(0.0, 0.3, t) * (1.0 - smoothstep(2.0, seconds, t))
		data.encode_s16(i * 2, int(clampf(y * 6.0 * env, -1.0, 1.0) * 20000.0))
	return _wav(data, loop)

func _wav(data: PackedByteArray, loop: bool) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = data.size() / 2
	return wav
