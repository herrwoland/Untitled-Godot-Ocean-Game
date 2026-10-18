class_name Leviathan extends Node3D
## Something ancient and colossal, shaped like a basking shark, that swims half out of the sea with
## its mouth always open. It eats lit ships. LeviathanEncounter brings it: begin() places it deep
## below the surface (it never pops into view) and it plays out one encounter, then frees itself.
##
##  - RISE: swims up from the deep toward the ship, climbing like a swimmer, not a balloon. Shortly
##    before it breaks the surface its call is heard (call_lead s ahead), then silence, then it
##    surfaces ~surface_distance from the ship. Its WaterDeformers swell, break and calm the sea.
##  - APPROACH: comes on at the surface, half out of the water, until its mouth is judge_distance
##    from the ship. Then it judges her:
##      lit  -> HUNT: comes at her mouth first. Cut the power and it GLIDEs: holds its heading and
##              no longer steers for her (she is still eaten if she is in its way); power on again
##              and it hunts again. A lure (group "leviathan_lure") within lure_range draws a
##              gliding body to it instead.
##      dark -> TURN_AWAY (turn_time s), WANDER (wander_time s), LEAVE.
##  - LEAVE: sinks away to despawn_depth and is gone.
## Anything in its MouthZone is swallowed: the player can only look around while they are drawn
## down the gullet (the Gullet markers) for swallow_time s, the last fade_time s fading to black,
## then they die. The ship goes in with them, carried in the mouth.
##
## Body axes: the mouth points along -Z, the root is the middle of the body on its long axis.
## The scene is built at MODEL_LENGTH; body_length scales the whole creature.

enum State { RISE, APPROACH, HUNT, GLIDE, TURN_AWAY, WANDER, LEAVE, SWALLOW }

const MODEL_LENGTH := 500.0 # m: the length the scene is built at
const TAKEN_META := &'leviathan_taken' # on a ship it carried off: the encounter gives her back at dawn

## Length of the body (m). Everything (mouth, water, turns, gullet) scales with it.
@export_range(50.0, 2000.0, 1.0, 'or_greater') var body_length := 500.0
## Body axis height above sea level while at the surface (m). 0 = half out of the water.
@export var surface_offset := 0.0

@export_group('Rising')
## How deep it starts and ends (m below sea level, body middle).
@export var despawn_depth := 250.0
## Forward speed while rising (m/s).
@export var rise_speed := 12.0
## Fastest climb while rising (m/s). It eases off as it nears the surface.
@export var rise_climb := 5.0
## Seconds to ease out of the climb: higher = a slower, gentler surfacing.
@export var rise_ease := 6.0
## How far from the ship it breaks the surface (m). Used to place it.
@export var surface_distance := 1000.0
## Seconds before it breaks the surface that its call is heard (the call is ~5 s, then silence).
@export var call_lead := 10.0

@export_group('Swimming')
@export var cruise_speed := 9.0 # m/s at the surface, coming on
@export var hunt_speed := 13.0 # m/s mouth first at a lit ship
@export var acceleration := 0.6 # m/s² -- a body this size gathers way slowly
@export var vertical_acceleration := 1.0 # m/s² change of climb or sink
## Tightest circle it can swim (m, at body_length 500). Turn rate = speed / radius.
@export var turn_radius := 350.0
## Tighter, while hunting.
@export var hunt_turn_radius := 250.0
## Where the turns pivot, from the middle (0) to the mouth (1): the head goes where it is aimed and
## the body trails round behind.
@export_range(0.0, 1.0, 0.05) var turn_pivot := 0.6
## Most the body tilts nose up or down (degrees) as it climbs or sinks.
@export var max_pitch := 15.0
## Tail beat: degrees and seconds.
@export var tail_sway := 8.0
@export var tail_period := 9.0

@export_group('Judging the ship')
## Mouth to ship distance (m) at which it decides whether the ship is lit.
@export var judge_distance := 200.0
## Seconds it takes to turn away from a dark ship.
@export var turn_time := 15.0
@export var turn_speed := 3.0 # m/s while it turns away
## Seconds it swims off in a random direction after turning away.
@export var wander_time := 20.0
@export var wander_speed := 7.0
## Missed a lit ship: it comes round again, at most this many passes, then leaves.
@export var max_passes := 2
## The ship this far behind its mouth (m) counts as a miss.
@export var pass_distance := 150.0
## Gliding (power cut while hunting) this long at most before it leaves (s).
@export var glide_time := 40.0
## A lure (group "leviathan_lure") within this distance of its mouth draws it while the ship is dark.
@export var lure_range := 400.0
## Within this distance of its mouth a hunted ship is drawn in (m), at up to suction_accel m/s².
@export var suction_range := 120.0
@export var suction_accel := 1.5

@export_group('Leaving')
@export var leave_speed := 8.0 # m/s forward while it sinks away
## Sink speed while leaving (m/s): sized so the body is gone from the surface in about 20 s.
@export var leave_sink := 5.0

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

@onready var _model: Node3D = $Model
@onready var _tail: Node3D = get_node_or_null(^'Model/Tail')
@onready var _mouth_zone: Area3D = $MouthZone
@onready var _call_sound: AudioStreamPlayer3D = get_node_or_null(^'CallSound')
@onready var _surface_sound: AudioStreamPlayer3D = get_node_or_null(^'SurfaceSound')
@onready var _suction_sound: AudioStreamPlayer3D = get_node_or_null(^'SuctionSound')

var _k := 1.0 # body_length / MODEL_LENGTH
var _yaw := 0.0
var _pitch := 0.0
var _speed := 0.0
var _vy := 0.0
var _time := 0.0 # in the current state
var _called := false
var _surfaced := false
var _passes := 0
var _away_yaw := 0.0
var _from_yaw := 0.0
var _rng := RandomNumberGenerator.new()
var _gullet: Array[Node3D] = []
var _swallow_t := -1.0 # s since the player was swallowed (< 0: not yet)
var _path: Array[Vector3] = [] # the swallowed player's way down, in the body's (unscaled) space
var _ship_local := Transform3D.IDENTITY # a carried ship, in the body's (unscaled) space
var _ship_held := false
var _died := false
var _fade: ColorRect
var _tail_rest := Basis.IDENTITY

func _ready() -> void:
	_k = body_length / MODEL_LENGTH
	scale = Vector3.ONE * _k
	_rng.randomize()
	for name in ['Gullet0', 'Gullet1', 'Gullet2', 'Gullet3']:
		var m := get_node_or_null(NodePath(name)) as Node3D
		if m:
			_gullet.append(m)
	for d in find_children('*', 'WaterDeformer', true, false):
		_scale_deformer(d)
	if _tail:
		_tail_rest = _tail.basis
	_mouth_zone.body_entered.connect(_on_mouth_body_entered)
	_fill_sounds()
	EventBus.day_started.connect(_on_day_started)

## Places it despawn_depth under the sea, far enough off that it surfaces ~surface_distance from
## the ship, `bearing` (a flat direction from the ship), and starts it rising toward her.
func begin(p_ship: RigidBody3D, p_player: Node3D, p_water: Node3D, bearing: Vector3) -> void:
	ship = p_ship
	player = p_player
	water = p_water
	bearing.y = 0.0
	bearing = bearing.normalized()
	# the run it swims climbing up until its back breaks the surface (the mouth leads by half a body)
	var run := maxf(despawn_depth - _radius(), 0.0) / maxf(rise_climb, 0.1) * rise_speed
	var origin := ship.global_position + bearing * (surface_distance + run + body_length * 0.5)
	origin.y = _sea() - despawn_depth
	_yaw = _yaw_of(-bearing)
	_speed = rise_speed
	_vy = rise_climb
	global_transform = Transform3D(Basis.from_euler(Vector3(0.0, _yaw, 0.0)).scaled(Vector3.ONE * _k), origin)
	_set_state(State.RISE)

## Where its mouth is.
func mouth_position() -> Vector3:
	return _mouth_zone.global_position

func is_swallowing() -> bool:
	return state == State.SWALLOW

func _physics_process(delta: float) -> void:
	if ship == null or water == null:
		return
	_time += delta
	match state:
		State.RISE: _process_rise(delta)
		State.APPROACH: _process_approach(delta)
		State.HUNT: _process_hunt(delta)
		State.GLIDE: _process_glide(delta)
		State.TURN_AWAY: _process_turn_away(delta)
		State.WANDER: _process_wander(delta)
		State.LEAVE: _process_leave(delta)
		State.SWALLOW: _process_swallow(delta)
	_move(delta)
	_sway_tail()
	if _ship_held:
		_carry_ship(delta)

## ---- states --------------------------------------------------------------------

func _process_rise(delta: float) -> void:
	_steer_at(_ship_ahead(), turn_radius, delta)
	_speed_to(rise_speed, delta)
	var gap := _surface_y() - global_position.y
	_climb_to(clampf(gap / rise_ease, 0.0, rise_climb), delta)
	# the call, heard a little before it breaks the surface
	var top := mouth_position().y + _radius()
	var eta := (_sea() - top) / maxf(_vy, 0.5)
	if not _called and eta <= call_lead:
		_called = true
		_play(_call_sound)
	if not _surfaced and top > _sea():
		_surfaced = true
		_play(_surface_sound)
	if gap < 2.0:
		_set_state(State.APPROACH)

func _process_approach(delta: float) -> void:
	_hold_surface(delta)
	_steer_at(_ship_ahead(), turn_radius, delta)
	_speed_to(cruise_speed, delta)
	if _mouth_to_ship() <= judge_distance:
		if _ship_lit():
			_set_state(State.HUNT)
		elif _lure():
			_set_state(State.GLIDE)
		else:
			_begin_turn_away()

func _process_hunt(delta: float) -> void:
	_hold_surface(delta)
	if not _ship_lit():
		_set_state(State.GLIDE)
		return
	_steer_at(_ship_ahead(), hunt_turn_radius, delta)
	_speed_to(hunt_speed, delta)
	_suck_ship()
	_shake_with_closeness()
	if _missed():
		_passes += 1
		if _passes >= max_passes:
			_set_state(State.LEAVE)

func _process_glide(delta: float) -> void:
	_hold_surface(delta)
	if _ship_lit():
		_set_state(State.HUNT)
		return
	var lure := _lure()
	if lure:
		_steer_at(lure.global_position, hunt_turn_radius, delta)
	if _time > glide_time or (lure == null and _missed()):
		_set_state(State.LEAVE)

func _begin_turn_away() -> void:
	var away := mouth_position() - ship.global_position
	away.y = 0.0
	_from_yaw = _yaw
	_away_yaw = _from_yaw + wrapf(_yaw_of(away) + _rng.randf_range(-0.5, 0.5) - _from_yaw, -PI, PI)
	_set_state(State.TURN_AWAY)

## A slow, heavy turn about its middle, away from the dark ship.
func _process_turn_away(delta: float) -> void:
	_hold_surface(delta)
	_speed_to(turn_speed, delta)
	var t := clampf(_time / turn_time, 0.0, 1.0)
	var target := lerpf(_from_yaw, _away_yaw, smoothstep(0.0, 1.0, t))
	_turn_about(target - _yaw, 0.0)
	if t >= 1.0:
		_away_yaw = _yaw + _rng.randf_range(-1.0, 1.0)
		_set_state(State.WANDER)

func _process_wander(delta: float) -> void:
	_hold_surface(delta)
	_speed_to(wander_speed, delta)
	_steer_at(global_position + _flat_dir(_away_yaw) * 1000.0, turn_radius, delta)
	if _time > wander_time:
		_set_state(State.LEAVE)

func _process_leave(delta: float) -> void:
	_speed_to(leave_speed, delta)
	_climb_to(-leave_sink, delta)
	_set_suction(false)
	if global_position.y < _sea() - despawn_depth:
		if _ship_held:
			# she stays down there with it, out of sight, until the morning gives her back
			ship.visible = false
			ship.set_meta(TAKEN_META, true)
		queue_free()

func _process_swallow(delta: float) -> void:
	_hold_surface(delta)
	_speed_to(swallow_speed, delta)
	_swallow_t += delta
	var t := clampf(_swallow_t / swallow_time, 0.0, 1.0)
	player.global_position = _frame() * _along_path(smoothstep(0.0, 1.0, t))
	EventBus.camera_shake_requested.emit(swallow_shake * (1.0 - t * 0.5))
	if _fade:
		_fade.modulate.a = smoothstep(swallow_time - fade_time, swallow_time, _swallow_t)
	if t >= 1.0 and not _died:
		_died = true
		EventBus.player_died.emit() # the mission controller restages the morning

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
	ship.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	ship.freeze = true
	ship.linear_velocity = Vector3.ZERO
	ship.angular_velocity = Vector3.ZERO
	_ship_local = _frame().affine_inverse() * ship.global_transform
	_set_suction(true)
	if player.has_method(&'ship_aboard') and player.ship_aboard() == ship and _swallow_t < 0.0:
		_swallow_player()
	elif state != State.SWALLOW:
		_set_state(State.LEAVE)

func _carry_ship(delta: float) -> void:
	if not is_instance_valid(ship):
		_ship_held = false
		return
	if _gullet.size() > 1:
		var goal := _frame().affine_inverse() * _gullet[1].global_position
		goal.y = _ship_local.origin.y # she floats in on the water it takes in
		_ship_local.origin = _ship_local.origin.move_toward(goal, delta * maxf(body_length * 0.01, 1.0))
	ship.global_transform = _frame() * _ship_local

## A point along the swallowed player's way down, t 0..1, in body space.
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

## Draws a hunted ship toward the mouth once she is close.
func _suck_ship() -> void:
	if _ship_held or ship.freeze:
		return
	var to_mouth := mouth_position() - ship.global_position
	to_mouth.y = 0.0
	var d := to_mouth.length()
	var reach := suction_range * _k
	_set_suction(d < reach * 2.0)
	if d < reach and d > 0.1:
		var pull := suction_accel * (1.0 - d / reach)
		ship.apply_central_force(to_mouth / d * pull * ship.mass)

## A new morning puts everything back: the ship, the player's body, the view.
func _on_day_started(_day: int) -> void:
	if _ship_held and is_instance_valid(ship):
		ship.freeze = false
		ship.visible = true
	if _swallow_t >= 0.0 and player and player.has_method(&'set_captured'):
		player.set_captured(false)
	queue_free()

## ---- movement ------------------------------------------------------------------

## Forward along its heading, plus its climb or sink; the body tilts with the climb.
func _move(delta: float) -> void:
	var fwd := _flat_dir(_yaw)
	global_position += fwd * _speed * delta + Vector3.UP * _vy * delta
	var climb := atan2(_vy, maxf(_speed, 1.0))
	var limit := deg_to_rad(max_pitch)
	_pitch = lerpf(_pitch, clampf(climb, -limit, limit), 1.0 - exp(-0.5 * delta))
	global_basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0)).scaled(Vector3.ONE * _k)

## Radius-limited turn toward a point: turn rate = speed / radius.
func _steer_at(point: Vector3, radius_m: float, delta: float) -> void:
	var to := point - _pivot(turn_pivot)
	to.y = 0.0
	if to.length() < 1.0:
		return
	var want := wrapf(_yaw_of(to) - _yaw, -PI, PI)
	var rate := maxf(_speed, 1.0) / maxf(radius_m * _k, 1.0)
	_turn_about(clampf(want, -rate * delta, rate * delta), turn_pivot)

## Turns the heading by `angle`, pivoting at `pivot` (0 middle .. 1 mouth).
func _turn_about(angle: float, pivot: float) -> void:
	if absf(angle) < 0.00001:
		return
	var p := _pivot(pivot)
	global_position = p + (global_position - p).rotated(Vector3.UP, angle)
	_yaw += angle

func _pivot(f: float) -> Vector3:
	return global_position + _flat_dir(_yaw) * body_length * 0.5 * f

func _speed_to(target: float, delta: float) -> void:
	_speed = move_toward(_speed, target, acceleration * delta)

func _climb_to(target: float, delta: float) -> void:
	_vy = move_toward(_vy, target, vertical_acceleration * delta)

func _hold_surface(delta: float) -> void:
	_climb_to(clampf((_surface_y() - global_position.y) / 4.0, -2.0, 2.0), delta)

func _sway_tail() -> void:
	if _tail:
		var a := deg_to_rad(tail_sway) * sin(TAU * Time.get_ticks_msec() / 1000.0 / tail_period)
		_tail.basis = _tail_rest.rotated(Vector3.UP, a)

## ---- reading the world ---------------------------------------------------------

func _sea() -> float:
	return water.global_position.y

func _surface_y() -> float:
	return _sea() + surface_offset * _k

func _radius() -> float:
	return body_length * 0.11

## The body's own frame, without its scale: what carried things are held in.
func _frame() -> Transform3D:
	return Transform3D(global_basis.orthonormalized(), global_position)

func _ship_lit() -> bool:
	return ship.get(&'powered') != false

func _mouth_to_ship() -> float:
	var d := ship.global_position - mouth_position()
	d.y = 0.0
	return d.length()

## Where the ship will be by the time the mouth gets there (her velocity, a few seconds ahead).
func _ship_ahead() -> Vector3:
	var t := minf(_mouth_to_ship() / maxf(_speed, 1.0), 20.0)
	return ship.global_position + ship.linear_velocity * t

## The ship is behind the mouth and well clear of it.
func _missed() -> bool:
	var to := ship.global_position - mouth_position()
	to.y = 0.0
	return to.dot(_flat_dir(_yaw)) < 0.0 and to.length() > pass_distance * _k

func _lure() -> Node3D:
	var best: Node3D = null
	var best_d := lure_range * _k
	for n in get_tree().get_nodes_in_group(&'leviathan_lure'):
		var d := (n as Node3D).global_position.distance_to(mouth_position())
		if d < best_d:
			best_d = d
			best = n
	return best

func _shake_with_closeness() -> void:
	var d := _mouth_to_ship()
	var reach := judge_distance
	if d < reach:
		EventBus.camera_shake_requested.emit(lerpf(0.05, 0.4, 1.0 - d / reach))

static func _yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)

static func _flat_dir(yaw: float) -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

func _set_state(s: State) -> void:
	state = s
	_time = 0.0

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
