extends Node3D
## A deep-water stalker. Idle drifting is driven by the CreatureDirector; when
## told to hunt it sneaks into the player's blind spot from behind and below,
## then circles there, creeping closer while unseen. It only strikes once the
## player has truly SEEN it — looked its way with nothing in between for a
## moment — (or backed into the teeth).
## Like a shark it can never stop, back up or slide sideways: it only swims
## forward and steers, head first, the long body trailing through the turn.
## It swims level, easing up or down to its depth, and only tilts its head
## toward the prey when it charges; the jaw gapes from the moment it commits.
## So an attack is a series of passes — peel away into the dark, turn back
## at a distance, and once lined up on where the prey is GOING, burst into a
## committed straight charge — and for the last strike_lock_distance meters
## it does not steer at all. A pass that misses sweeps on by, and the next
## run-up begins. After max_passes it slinks back to stalking; a catch is
## dragged into the deep for carry_time seconds before player_died fires and
## the day restages.
## All tuning lives here as exports so each instance can be balanced in the
## inspector. The model is ~150 m long: distances are mouth-relative.

enum State { LURK, SNEAK, ATTACK, CARRY, SEIZED } # SEIZED: in a kraken's arms, moved by it
enum Pass { PEEL, TURN_IN, CHARGE } # the three beats of one attack run

@export_group("Speeds")
@export var cruise_speed := 10.0 # m/s closing in from far away, and for attack run-ups
@export var sneak_speed := 3.0 # m/s slowest it ever swims — it never stops
@export var attack_speed := 14.0 # m/s charge — 4-5x the sneak
@export var carry_speed := 8.0 # m/s dragging the catch down
@export var acceleration := 5.0 # m/s² speed change: the charge visibly builds, a miss coasts off
@export var depth_change_speed := 2.0 # m/s it rises or sinks while swimming level (every beat but the charge)
@export var turn_radius := 100.0 # m — tightest circle it can swim, at any speed. A body this size carves wide
@export var charge_turn_radius := 500.0 # m — committed: only the gentlest corrections mid-charge
@export var max_pitch := 50.0 # degrees it will climb or dive; fish do not swim straight up
@export_range(0.0, 1.0) var turn_pivot := 0.9 # where the body turns: 0 = center, 1 = snout. Head leads, tail swings wide
@export var snatch_pull_time := 0.5 # seconds from the grab until the player sits in the mouth

@export_group("Not through rock")
@export_flags_3d_physics var avoid_mask := 1 # what it swims round: the world (rocks, the floor)
@export var avoid_radius := 16.0 # m it keeps from rock: its body's half-thickness plus room for the tail cutting the corner
@export var avoid_look_ahead := 40.0 # m it always looks ahead...
@export var avoid_look_seconds := 3.0 # ...plus how far it swims in this many seconds
@export var avoid_turn_radius := 40.0 # m, its tightest turn when rock is in the way

@export_group("Held (in a kraken's arms)")
## Not rigid: the body sags from where it is held and swings softly behind
## every move, keeping its shape.
@export var held_sag := 15.0 # m the tail hangs off a straight body while it still fights...
@export var held_dead_sag := 105.0 # ...and once it is still: with the snout tipped down (Kraken.fish_drape_tilt) the body drapes in an arch over the bite
@export var held_follow := 2.5 # 1/s how quickly the body catches up with the hold (lower = softer)
@export var held_thrash_frequency := 1.6 # tail beats per second at full fight: swimming flat out, going nowhere
@export var held_thrash_angle := 4.0 # how much wider than a cruising beat the tail swings at full fight

@export_group("Stalking")
@export var stalk_behind_distance := 50.0 # first hold point this far behind the player
@export var stalk_below_depth := 30.0 # and this far beneath them (sets the approach angle)
@export var creep_rate := 1.5 # m/s the hold distance shrinks while unseen
@export var min_stalk_distance := 20.0 # closest the mouth dares to circle, straight-line to the player

@export_group("Being seen")
@export var seen_distance := 60.0 # farther than this the murk hides it: no trigger
## The shape the player must catch sight of (the SightVolume child by default).
## Size it freely in the editor — bigger than the fish means a glimpse from the
## corner of the eye already counts. Anywhere on screen counts for this one.
@export var sight_volume: CollisionShape3D
@export var view_cone_angle := 30.0 # without a sight_volume: degrees off the center of view that still count
@export var glimpse_time := 0.25 # seconds it must stay seen before it strikes (a flicker past the eye is forgiven)
@export_flags_3d_physics var sight_blockers := 1 # layers that hide it: terrain, rocks, the hull

@export_group("Attack")
@export var kill_distance := 12.0 # fallback bite range, used only if no mouth_area is set
@export var jaw_open_angle := 180 # degrees the jaw swings to when open (rest pose = closed)
@export var jaw_open_time := 1.0 # seconds for the jaw to swing fully open — it gapes as the charge begins
@export var jaw_close_time := 1.0 # seconds to clamp shut, on the bite or after a miss
@export var run_up_distance := 250.0 # after a miss (or when not lined up) it swims this far off before turning back — keep ≥ 2.5× turn_radius
@export var run_up_depth := 15.0 # and sinks this far below the prey, so the charge rises out of the dark
@export var charge_align_angle := 5.0 # degrees — must be lined up this well before it commits to a charge
@export var max_lead_time := 5.0 # seconds ahead it aims along the prey's swim path
@export var strike_lock_distance := 50.0 # the last meters of a charge: no more steering, dead straight
@export var max_passes := 3 # missed charges before it gives up and stalks again
@export var attack_give_up_time := 150.0 # safety net: longest an attack sequence lasts
@export var carry_time := 10.0 # seconds the catch is dragged down before the day resets

@export_group("Camera shake")
## One jolt the moment it commits to a charge: the warning.
@export_range(0.0, 1.0, 0.05) var charge_warning_shake := 0.5
## While charging, a rumble that builds as the snout closes in: it starts
## this many meters out...
@export var close_shake_range := 100.0
## ...at this strength, and grows to close_shake_max with the teeth on you.
@export_range(0.0, 1.0, 0.05) var close_shake_min := 0.35
@export_range(0.0, 1.0, 0.05) var close_shake_max := 1.0

@export_group("Body bend")
## The spine follows the path the head swam; on top of that the tail sways.
@export var tail_sway_angle := 8.0 # degrees at the tail tip
@export var tail_sway_frequency := 0.3 # beats per second when barely moving...
@export var tail_sway_frequency_per_speed := 0.01 # ...plus this much per m/s of speed
@export var max_joint_bend := 25.0 # degrees one joint may fold against the next
@export var max_joint_pitch := 2.0 # degrees one joint may tip up or down (the bend is sideways)
@export var bend_cull_distance := 450.0 # m from the camera beyond which the spine is left alone

@export_group("Body")
@export var jaw: Node3D # opens for the attack; found in the model if left unset
@export var mouth: Node3D # marker at the mouth; kills and carrying anchor here
@export var mouth_area: Area3D # the actual mouth volume; overlap with the player = caught
## Snout to tail tip (m), so a kraken knows how much of it there is to grab.
@export var body_length := 150.0
## Half its thickness amidships (m): how much water it moves breaking the surface.
@export var breach_radius := 9.0

@onready var _presence_loop: AudioStreamPlayer3D = get_node_or_null(^'PresenceLoop') # the whole hunt
@onready var _sneak_loop: AudioStreamPlayer3D = get_node_or_null(^'SneakLoop') # only while stalking
@onready var _detect_sound: AudioStreamPlayer3D = get_node_or_null(^'DetectSound') # the moment it knows it's seen
@onready var _charge_sound: AudioStreamPlayer3D = get_node_or_null(^'ChargeSound') # each committed charge
@onready var _bite_sound: AudioStreamPlayer3D = get_node_or_null(^'BiteSound')

var state := State.LURK
var player: Node3D = null
## Scales every hunting speed but the slow stalking creep, plus the
## acceleration; set by the CreatureDirector. Turn radii stay the same, so
## turns get quicker, not tighter.
var speed_multiplier := 1.0

var _jaw_closed_x := 0.0
var _jaw_tween: Tween
var _head_minus_z := true # which way the model's snout points along local Z
var _stalk_distance := 0.0
var _seen_time := 0.0 # how long the player has had it in plain sight
var _behind_dir := Vector3.FORWARD # last known horizontal "behind the player's view"
var _speed := 0.0 # current forward speed — the only way this body moves
var _pass := Pass.PEEL
var _passes_missed := 0
var _strike_locked := false # inside strike_lock_distance on this charge: steering is over
var _attack_left := 0.0
var _player_vel := Vector3.ZERO # smoothed, measured from the player's movement
var _player_last := Vector3.ZERO
var _jaw_opened := false # gape already triggered during this attack
var _carry_left := 0.0
var _pull_left := 0.0 # remaining seconds of the reel-in at carry start
var _died_emitted := false
var _struggle_time := 20.0 # SEIZED: how long it fights...
var _struggle_left := 0.0 # ...and how much fight is left
var _fighting := false # SEIZED: still at full fight (not yet at the kraken's mouth)
var _avoid_tick := 0 # frames until it looks ahead again
var _avoid_urgency := 0.0 # 0 = clear ahead .. 1 = rock right at the snout
var _avoid_normal := Vector3.UP # away from the rock it saw
var _avoid_shape := SphereShape3D.new()
var _player_in_mouth := false # kept current by the mouth_area overlap signals
var _spine: FishSpine # bends the skeleton along the swum path; null without a rig
var _breach: BreachSplash # splashes where the body goes through the surface
var _breach_points := PackedVector3Array()
var _breach_radii := PackedFloat32Array()
const BREACH_POINTS := 7
var _own_bodies: Array[RID] = [] # its own colliders, which must never hide it from view
var _sight_points: PackedVector3Array = [] # sample points on sight_volume, in its local space
var _sight_cursor := 0 # round-robin start, so capped ray checks cover every point over a few frames
const SIGHT_SPACING := 20.0 # m between sight_volume sample points
const MAX_SIGHT_RAYS := 8 # line-of-sight checks per frame at most

func _ready() -> void:
	add_to_group(&'giant_fish') # so a kraken can find it (and keep idle fish out of its waters)
	if jaw == null:
		jaw = get_node_or_null(^'fish_01/jaw')
	if jaw:
		_jaw_closed_x = jaw.rotation.x # the authored rest pose is the closed jaw
	if mouth == null:
		for candidate: NodePath in [^'Mouth', ^'mouth', ^'MouthMarker', ^'fish_01/Mouth']:
			mouth = get_node_or_null(candidate)
			if mouth:
				break
	_head_minus_z = to_local(mouth_position()).z <= 0.0
	if mouth_area == null:
		mouth_area = get_node_or_null(^'Area3D')
	if mouth_area:
		mouth_area.set_collision_mask_value(2, true) # the player body lives on layer 2
		mouth_area.body_entered.connect(_on_mouth_body_entered)
		mouth_area.body_exited.connect(_on_mouth_body_exited)
	var skeletons := find_children("*", "Skeleton3D", true, false)
	if not skeletons.is_empty():
		_spine = FishSpine.new(skeletons[0])
	for body: CollisionObject3D in find_children("*", "CollisionObject3D", true, false):
		_own_bodies.append(body.get_rid())
	if sight_volume == null:
		sight_volume = get_node_or_null(^'SightVolume/CollisionShape3D')
	if sight_volume and sight_volume.shape:
		_sight_points = _sample_points(sight_volume.shape.get_debug_mesh().get_aabb())
	# a BreachSplash child of its own (to tune in the editor), else a default one
	_breach = get_node_or_null(^'BreachSplash') as BreachSplash
	if _breach == null:
		_breach = BreachSplash.new()
		_breach.name = &'BreachSplash'
		add_child(_breach)

func _on_mouth_body_entered(body: Node3D) -> void:
	if body.is_in_group(&'player'):
		_player_in_mouth = true

func _on_mouth_body_exited(body: Node3D) -> void:
	if body.is_in_group(&'player'):
		_player_in_mouth = false

## True while the player is physically inside the mouth volume. Falls back to
## a distance check for instances without a mouth_area.
func _player_caught() -> bool:
	if mouth_area:
		return _player_in_mouth
	return _mouth_to_player() < kill_distance

## ---- API for the CreatureDirector ------------------------------------------

func begin_hunt(target: Node3D) -> void:
	if state != State.LURK:
		return
	player = target
	_player_last = player.global_position
	_player_vel = Vector3.ZERO
	_speed = cruise_speed * speed_multiplier
	_start_stalk()
	state = State.SNEAK
	_play(_presence_loop) # the low throb of something below, for as long as it hunts
	_play(_sneak_loop)

## Prey escaped (surfaced, climbed out, reached safe water). Ignored while
## carrying: the drag into the deep always ends in the day reset.
func end_hunt() -> void:
	if state == State.CARRY or state == State.LURK or state == State.SEIZED:
		return
	set_jaw_open(false)
	state = State.LURK
	_stop(_presence_loop)
	_stop(_sneak_loop)

## Hard reset for the morning restage: drop everything, close the jaw.
func abort_hunt() -> void:
	set_jaw_open(false)
	state = State.LURK
	player = null
	_stop(_presence_loop)
	_stop(_sneak_loop)

func is_busy() -> bool:
	return state != State.LURK

func is_carrying() -> bool:
	return state == State.CARRY

## ---- API for a Kraken -------------------------------------------------------

## Caught in a kraken's arms: from now on it is posed by the kraken and only
## fights — its tail beating as if it could swim free — at full strength until
## fade_struggle(), then weaker and weaker over struggle_time seconds, then limp. A catch of its own in its mouth is let go. The morning's abort_hunt
## sets it free again.
func seize(struggle_time: float) -> void:
	if state == State.CARRY and player and player.has_method(&'set_captured'):
		player.set_captured(false)
	_stop(_presence_loop)
	_stop(_sneak_loop)
	_stop(_charge_sound)
	state = State.SEIZED
	player = null
	_speed = 0.0
	_struggle_time = maxf(struggle_time, 0.01)
	_struggle_left = _struggle_time
	_fighting = true # full fight until the kraken has it at its mouth (fade_struggle)
	# the jaw shuts once, gently, and then stays as it is
	set_jaw_open(false)
	_jaw_opened = false

## At the kraken's mouth: from here its fight ebbs away over seconds.
func fade_struggle(seconds: float) -> void:
	if _fighting:
		_fighting = false
		_struggle_time = maxf(seconds, 0.01)
		_struggle_left = _struggle_time

func is_fading() -> bool:
	return state == State.SEIZED and not _fighting

func is_seized() -> bool:
	return state == State.SEIZED

## How hard it still fights, 1 at the catch down to 0 (dead).
func struggle() -> float:
	return _struggle_left / _struggle_time if state == State.SEIZED else 0.0

## Its body for whoever must grip it: snout and tail tip, in the world.
func body_ends() -> PackedVector3Array:
	var head := mouth_position()
	return PackedVector3Array([head, head - _heading() * body_length])

## Where its body really is (0 = head .. 1 = tail tip), bent as it is now:
## along its spine bones. Without a rig, along its straight body.
func body_point(t: float) -> Vector3:
	if _spine == null:
		var ends := body_ends()
		return ends[0].lerp(ends[1], t)
	var sk := _spine.skeleton
	var f := clampf(t, 0.0, 1.0) * (sk.get_bone_count() - 1)
	var i := mini(int(f), sk.get_bone_count() - 2)
	var xf := sk.global_transform
	return (xf * sk.get_bone_global_pose(i).origin).lerp(xf * sk.get_bone_global_pose(i + 1).origin, f - i)

## Its fight ebbs once the kraken has it at its mouth. The jaw stays still.
func _process_seized(delta: float) -> void:
	if not _fighting:
		_struggle_left = maxf(_struggle_left - delta, 0.0)

## Idle drifting for the director: swim (forward only) after a moving point,
## faster the farther behind it falls.
func cruise_toward(point: Vector3, delta: float) -> void:
	var to_point := point - mouth_position()
	_steer_level(to_point, point.y, turn_radius, delta)
	_swim(clampf(to_point.length() * 0.3, sneak_speed, 30.0), delta)

## ---- behaviour ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_update_spine(delta) # idle drifting and scripted passes bend too
	_track_breach(delta)
	if state == State.SEIZED:
		_process_seized(delta)
		return
	_sense_ahead() # rock in the way? (the steering bends round it)
	if state == State.LURK or player == null:
		return
	_track_player(delta)
	match state:
		State.SNEAK: _process_sneak(delta)
		State.ATTACK: _process_attack(delta)
		State.CARRY: _process_carry(delta)

## Slip into the blind spot behind the player's view, well below, then circle
## there — it cannot hover — edging closer while they are not looking. Stalk
## distances position the MOUTH, not the origin: the snout reaches ~46 m
## ahead of the body's center, so measuring from the origin would park the
## teeth on top of the player.
func _process_sneak(delta: float) -> void:
	var cam := _player_camera()
	if cam:
		var back: Vector3 = cam.global_transform.basis.z # camera backward
		back.y = 0.0
		if back.length() > 0.1:
			_behind_dir = back.normalized()
	var offset_dir := (_behind_dir * stalk_behind_distance + Vector3.DOWN * stalk_below_depth).normalized()
	var stalk_point := player.global_position + offset_dir * _stalk_distance

	# Chasing a point it can never stop on makes it overshoot and come round
	# again: at sneak speed that is a slow, wide circle in the dark beneath.
	var to_point := stalk_point - mouth_position()
	var steer_dir := to_point
	var hold_y := stalk_point.y
	if _mouth_to_player() < min_stalk_distance:
		# It cannot stop, so a prey slower than its creep gets overtaken and
		# the wide circle sweeps the snout in close. Veer off and sink to
		# pass underneath, rather than blunder into a bite it never chose.
		steer_dir = mouth_position() - player.global_position
		hold_y = minf(hold_y, player.global_position.y - min_stalk_distance)
	_steer_level(steer_dir, hold_y, turn_radius, delta)
	# The multiplier speeds up the long approach but never the final creep:
	# any faster and its wide turns would carry it out in front of the prey.
	_swim(cruise_speed * speed_multiplier if to_point.length() > 80.0 else sneak_speed, delta)
	if to_point.length() < turn_radius: # circling the hold: dare a little closer
		_stalk_distance = maxf(_stalk_distance - creep_rate * delta, min_stalk_distance)

	_seen_time = _seen_time + delta if _is_seen() else 0.0
	if _seen_time >= glimpse_time or _player_caught():
		_begin_attack() # spotted — or the prey backed straight into the teeth

## Spotted. Already lined up on the prey: charge straight away. Otherwise it
## cannot swing its head round on the spot — it peels off for a run-up.
func _begin_attack() -> void:
	state = State.ATTACK
	_stop(_sneak_loop)
	_play(_detect_sound)
	_attack_left = attack_give_up_time
	_passes_missed = 0
	_jaw_opened = false
	if _aim_error() < charge_align_angle:
		_begin_charge()
	else:
		_pass = Pass.PEEL

func _begin_charge() -> void:
	_pass = Pass.CHARGE
	_strike_locked = false
	_play(_charge_sound) # the rush itself
	EventBus.camera_shake_requested.emit(charge_warning_shake)
	if not _jaw_opened:
		_jaw_opened = true
		set_jaw_open(true) # it comes with the mouth already opening

func _process_attack(delta: float) -> void:
	var to_player := player.global_position - mouth_position()
	match _pass:
		Pass.PEEL:
			# Swim on, away from the prey and down into the dark, until there
			# is room for a proper run at it.
			var away := -to_player
			away.y = 0.0
			if away.length() < 0.1:
				away = _heading()
			_steer_level(away, player.global_position.y - run_up_depth, turn_radius, delta)
			_swim(cruise_speed * speed_multiplier, delta)
			if to_player.length() >= run_up_distance and not _inside_turn_circle(_aim_point(), 1.1):
				_pass = Pass.TURN_IN
		Pass.TURN_IN:
			# The wide turn back, onto the line of where the prey is heading.
			# Still level and deep: only the compass heading has to line up,
			# the charge itself tilts up at the prey.
			_steer_level(_aim_point() - mouth_position(), player.global_position.y - run_up_depth, turn_radius, delta)
			_swim(cruise_speed * speed_multiplier, delta)
			if _aim_error(true) < charge_align_angle:
				_begin_charge()
			elif _inside_turn_circle(_aim_point(), 0.85): # margin: no flip-flopping on the edge
				_pass = Pass.PEEL # too close to ever line up: swim on and make more room
		Pass.CHARGE:
			# Committed: builds to full speed, barely corrects, cannot stop.
			# The last meters are dead straight — no swerving after a dodge;
			# the mouth is wide enough that a near-miss is still a catch.
			if to_player.length() < strike_lock_distance:
				_strike_locked = true
			if _strike_locked and _avoid_urgency > 0.3:
				_strike_locked = false # rock ahead: it breaks off rather than ram it
			if not _strike_locked:
				_steer_toward(_aim_point() - mouth_position(), charge_turn_radius, delta)
			_swim(attack_speed * speed_multiplier, delta)
			_shake_with_closeness(to_player.length())
			# Swept past: the prey is well behind the snout and not in the mouth.
			if to_player.dot(_heading()) < -10.0 and not _player_caught():
				_miss()
				return

	# Backing into the teeth works in any beat; the jaw still has to open.
	if _player_caught() and not _jaw_opened:
		_jaw_opened = true
		set_jaw_open(true)
	# The bite only lands once the jaw has visibly swung open — a point-blank
	# trigger must still show the mouth opening before the grab.
	if _player_caught() and _jaw_open_fraction() > 0.7:
		_begin_carry()
		return
	_attack_left -= delta
	if _attack_left <= 0.0 and _pass != Pass.CHARGE: # never break off mid-charge
		_give_up()

## Missed pass: the jaw shuts and it simply keeps swimming — straight into
## the next run-up, until max_passes have failed.
func _miss() -> void:
	set_jaw_open(false)
	_jaw_opened = false
	_passes_missed += 1
	if _passes_missed >= max_passes:
		_give_up()
	else:
		_pass = Pass.PEEL

## Slink back into the blind spot and stalk from a respectful distance again.
func _give_up() -> void:
	set_jaw_open(false)
	_jaw_opened = false
	_start_stalk()
	state = State.SNEAK
	_play(_sneak_loop)

## The bite does not kill outright: the jaws clamp shut and the catch rides in
## the mouth, dragged down and away while the light fades above.
func _begin_carry() -> void:
	state = State.CARRY
	_stop(_charge_sound)
	_carry_left = carry_time
	_pull_left = snatch_pull_time
	_died_emitted = false
	set_jaw_open(false)
	_play(_bite_sound)
	if player.has_method(&'set_captured'):
		player.set_captured(true)

func _process_carry(delta: float) -> void:
	var horiz := _heading()
	horiz.y = 0.0
	horiz = horiz.normalized() if horiz.length() > 0.05 else Vector3.RIGHT
	if global_position.x < -45.0:
		horiz = Vector3.RIGHT # never drag the catch back toward the cove
	var dive := (horiz * 0.5 + Vector3.DOWN).normalized()
	_steer_toward(dive, turn_radius, delta)
	_swim(carry_speed * speed_multiplier, delta)
	# Reel the catch into the (moving) mouth over exactly snatch_pull_time
	# seconds, then keep it glued there for the rest of the dive.
	if _pull_left > delta:
		player.global_position = player.global_position.lerp(
			mouth_position(), clampf(delta / _pull_left, 0.0, 1.0))
		_pull_left -= delta
	else:
		player.global_position = mouth_position()

	_carry_left -= delta
	if _carry_left <= 0.0 and not _died_emitted:
		_died_emitted = true
		EventBus.player_died.emit() # the mission controller fades out and restages

## ---- helpers -----------------------------------------------------------------

## The water it throws up wherever its body goes through the surface: snout
## to tail, thinner toward the ends.
func _track_breach(delta: float) -> void:
	if _breach == null:
		return
	if _breach_points.size() != BREACH_POINTS:
		_breach_points.resize(BREACH_POINTS)
		_breach_radii.resize(BREACH_POINTS)
	for i in BREACH_POINTS:
		var t := i / float(BREACH_POINTS - 1)
		_breach_points[i] = body_point(t)
		_breach_radii[i] = breach_radius * lerpf(1.0, 0.35, smoothstep(0.4, 1.0, t)) * lerpf(0.6, 1.0, smoothstep(0.0, 0.2, t))
	_breach.track(_breach_points, _breach_radii, delta)

## Keep the body curving along its path. Skipped far from the camera, where
## nobody could see it anyway.
func _update_spine(delta: float) -> void:
	if _spine == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam and cam.global_position.distance_to(global_position) > bend_cull_distance:
		return
	_spine.sway_angle = tail_sway_angle
	_spine.sway_frequency = tail_sway_frequency
	if state == State.SEIZED: # thrashing in the arms: wild, fast tail beats fading to nothing
		var fight := struggle()
		# beating its tail as if it could swim free, slower and weaker as it fades
		_spine.sway_angle = tail_sway_angle * held_thrash_angle * fight
		_spine.sway_frequency = held_thrash_frequency * fight
		# held, not swimming: a soft weight in the arms, sagging more once dead
		_spine.soft = true
		_spine.soft_sag = lerpf(held_dead_sag, held_sag, fight)
		_spine.soft_follow = held_follow
	elif _spine.soft:
		_spine.end_soft()
	_spine.sway_frequency_per_speed = tail_sway_frequency_per_speed
	_spine.max_joint_bend = max_joint_bend
	_spine.max_joint_pitch = max_joint_pitch
	_spine.update(delta, _speed)

## The charge's rumble: held every frame while the snout is within
## close_shake_range, from close_shake_min out there to close_shake_max at
## the mouth. Stops being sent once the charge ends, so it fades away.
func _shake_with_closeness(distance: float) -> void:
	if distance > close_shake_range:
		return
	var closeness := 1.0 - clampf((distance - kill_distance) / (close_shake_range - kill_distance), 0.0, 1.0)
	EventBus.camera_shake_requested.emit(lerpf(close_shake_min, close_shake_max, closeness))

## Forward is the only way this body moves. Speed eases toward the target
## instead of snapping, so charges build and misses coast.
func _swim(target_speed: float, delta: float) -> void:
	_speed = move_toward(_speed, target_speed, acceleration * speed_multiplier * delta)
	global_position += _heading() * _speed * delta
	if _avoid_urgency > 0.0:
		_push_snout_out() # the last resort, should the turn not have been enough

## Smoothed player velocity from frame-to-frame movement, so the charge can
## aim where the prey is going. Big jumps (teleports, restage) are ignored.
func _track_player(delta: float) -> void:
	var pos := player.global_position
	var vel := (pos - _player_last) / maxf(delta, 0.0001)
	_player_last = pos
	if vel.length() > 30.0:
		return
	_player_vel = _player_vel.lerp(vel, minf(delta * 3.0, 1.0))

## Where to aim a charge: along the prey's swim path, as far ahead as the
## charge will take to get there (capped at max_lead_time). Time-to-reach
## uses the average of the current and full charge speed, since a charge
## launched from a slow circle is still building up.
func _aim_point() -> Vector3:
	var closing := maxf((_speed + attack_speed * speed_multiplier) * 0.5, 1.0)
	var lead := minf(_mouth_to_player() / closing, max_lead_time)
	return player.global_position + _player_vel * lead

## Degrees between where it is heading and where a charge must go — measured
## against the pitch-limited direction, so a prey straight overhead cannot
## leave it circling forever waiting to line up. compass_only ignores the
## climb/dive, for lining up while still swimming level.
func _aim_error(compass_only := false) -> float:
	var to := _aim_point() - mouth_position()
	var fwd := _heading()
	if compass_only:
		to.y = 0.0
		fwd.y = 0.0
		if to.length() < 0.01 or fwd.length() < 0.01:
			return 180.0
	return rad_to_deg(fwd.angle_to(_limit_pitch(to)))

## True when the point sits inside the circle it would swim turning toward
## it — no amount of turning will ever point the snout at it from here.
## margin scales the circle, so entering and leaving can use different sizes.
func _inside_turn_circle(point: Vector3, margin := 1.0) -> bool:
	var fwd := Vector3(_heading().x, 0.0, _heading().z)
	var to := point - mouth_position()
	to.y = 0.0
	if fwd.length() < 0.01:
		return false
	var side := Vector3.UP.cross(fwd.normalized())
	if side.dot(to) < 0.0:
		side = -side
	return (to - side * turn_radius).length() < turn_radius * margin

## Fresh stalk from the far hold point, with no lingering glimpse.
func _start_stalk() -> void:
	_stalk_distance = Vector2(stalk_behind_distance, stalk_below_depth).length()
	_seen_time = 0.0

## The jaw swings open to jaw_open_angle for the attack and clamps back to
## its rest pose on the bite or when the prey escapes.
func set_jaw_open(open: bool) -> void:
	if jaw == null:
		return
	if _jaw_tween:
		_jaw_tween.kill()
	_jaw_tween = create_tween()
	_jaw_tween.tween_property(jaw, "rotation:x",
		deg_to_rad(jaw_open_angle) if open else _jaw_closed_x, jaw_open_time if open else jaw_close_time) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

## 0 = clenched at the rest pose, 1 = fully open at jaw_open_angle.
func _jaw_open_fraction() -> float:
	var open_x := deg_to_rad(jaw_open_angle)
	if jaw == null or absf(open_x - _jaw_closed_x) < 0.001:
		return 1.0
	return clampf((jaw.rotation.x - _jaw_closed_x) / (open_x - _jaw_closed_x), 0.0, 1.0)

## World position of the mouth — kills and carrying anchor here, because the
## body's origin sits a long way behind the snout on this model.
func mouth_position() -> Vector3:
	if mouth:
		return mouth.global_position
	if jaw:
		return jaw.global_position
	return global_position

func _mouth_to_player() -> float:
	return mouth_position().distance_to(player.global_position)

## Play helper that stays silent (and harmless) until a stream is assigned.
func _play(sound: AudioStreamPlayer3D) -> void:
	if sound and sound.stream:
		sound.play()

func _stop(sound: AudioStreamPlayer3D) -> void:
	if sound:
		sound.stop()

func _player_camera() -> Camera3D:
	return player.camera if &'camera' in player else null

## Seen = some sample point is near enough that the murk does not cover it,
## on screen, and in clear line of sight — no terrain or hull in between (its
## own colliders never count). With a sight_volume the points are spread over
## that shape and anywhere on screen will do; without one they are the snout,
## mid-body and body center, and must sit within view_cone_angle of the
## center of view. Rays are only cast for points that pass the cheap tests.
func _is_seen() -> bool:
	var cam := _player_camera()
	if cam == null:
		return false
	var eye := cam.global_position
	var look := -cam.global_basis.z
	var min_dot := cos(deg_to_rad(view_cone_angle))
	var space := get_world_3d().direct_space_state
	var points: PackedVector3Array
	if _sight_points.is_empty():
		var mouth_pos := mouth_position()
		points = [mouth_pos, mouth_pos.lerp(global_position, 0.5), global_position]
	else:
		min_dot = -1.0 # the volume's size is the dial: anywhere on screen counts
		var xf := sight_volume.global_transform
		var n := _sight_points.size()
		_sight_cursor = (_sight_cursor + 1) % n
		for i in n:
			points.append(xf * _sight_points[(_sight_cursor + i) % n])
	var rays := 0
	for point in points:
		var to_point := point - eye
		var dist := to_point.length()
		if dist > seen_distance or dist < 0.01 or look.dot(to_point / dist) < min_dot:
			continue
		if not cam.is_position_in_frustum(point):
			continue
		rays += 1
		if rays > MAX_SIGHT_RAYS:
			return false
		var ray := PhysicsRayQueryParameters3D.create(eye, point, sight_blockers)
		var exclude := _own_bodies.duplicate()
		if player is CollisionObject3D:
			exclude.append(player.get_rid())
		ray.exclude = exclude
		if space.intersect_ray(ray).is_empty():
			return true
	return false

## A grid of points about every SIGHT_SPACING meters through the shape's
## bounds, keeping those inside the inscribed ellipsoid so a round shape is
## not sampled out in empty air. Any of them on screen can give it away.
static func _sample_points(box: AABB) -> PackedVector3Array:
	var c := box.get_center()
	var h := box.size * 0.5
	var counts := Vector3i.ONE
	for axis in 3:
		counts[axis] = clampi(ceili(box.size[axis] / SIGHT_SPACING) + 1, 2, 12)
	var points: PackedVector3Array = [c]
	for i in counts.x:
		for j in counts.y:
			for k in counts.z:
				var n := Vector3(i / float(counts.x - 1), j / float(counts.y - 1), k / float(counts.z - 1)) * 2.0 - Vector3.ONE
				if n.length_squared() <= 1.05:
					points.append(c + n * h)
	return points

## ---- not through rock ------------------------------------------------------

## Looks ahead along its heading a few times a second — a sphere as thick as
## its head swept as far as it will swim in a few seconds — for the world
## (layer 1: rocks, the floor). What it finds sets how hard the steering
## bends away (_avoid_urgency, 0 = clear) and which way (_avoid_normal). The
## body trails the head's path, so where the head goes round, all of it does.
func _sense_ahead() -> void:
	_avoid_tick -= 1
	if _avoid_tick > 0:
		return
	_avoid_tick = 3
	var look := avoid_look_ahead + _speed * avoid_look_seconds
	var from := mouth_position()
	var space := get_world_3d().direct_space_state
	_avoid_shape.radius = avoid_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _avoid_shape
	query.collision_mask = avoid_mask
	query.exclude = _own_bodies
	query.transform = Transform3D(Basis.IDENTITY, from)
	query.motion = _heading() * look
	var fractions := space.cast_motion(query)
	if fractions[1] >= 1.0:
		_avoid_urgency = 0.0
		return
	query.motion = Vector3.ZERO
	query.transform = Transform3D(Basis.IDENTITY, from + _heading() * look * fractions[1])
	var hit := space.get_rest_info(query)
	_avoid_normal = hit.normal if not hit.is_empty() else -_heading()
	_avoid_urgency = 1.0 - fractions[0]

## Should the snout still end up in rock, it is pushed back out.
func _push_snout_out() -> void:
	var query := PhysicsShapeQueryParameters3D.new()
	_avoid_shape.radius = avoid_radius
	query.shape = _avoid_shape
	query.collision_mask = avoid_mask
	query.exclude = _own_bodies
	var mouth_pos := mouth_position()
	query.transform = Transform3D(Basis.IDENTITY, mouth_pos)
	var hit := get_world_3d().direct_space_state.get_rest_info(query)
	if hit.is_empty():
		return
	var n: Vector3 = hit.normal
	var hit_point: Vector3 = hit.point
	var depth := avoid_radius - (mouth_pos - hit_point).dot(n)
	if depth > 0.0:
		global_position += n * (depth + 0.1)

## Current mouth-first travel direction.
func _heading() -> Vector3:
	var fwd := -global_basis.z if _head_minus_z else global_basis.z
	return fwd.normalized()

## Swim level: steer only the compass heading toward dir (the head flattens
## out if it was tilted) and ease the depth toward target_y at
## depth_change_speed — no nodding at the prey's every rise and fall.
func _steer_level(dir: Vector3, target_y: float, radius_m: float, delta: float) -> void:
	_steer_toward(Vector3(dir.x, 0.0, dir.z), radius_m, delta)
	var step := depth_change_speed * speed_multiplier * delta
	global_position.y += clampf(target_y - mouth_position().y, -step, step)

## Clamp a direction's climb/dive to max_pitch, keeping its compass heading.
func _limit_pitch(dir: Vector3) -> Vector3:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() < 0.01:
		flat = _heading()
		flat.y = 0.0
		if flat.length() < 0.01:
			flat = Vector3.FORWARD
	var max_y := flat.length() * tan(deg_to_rad(max_pitch))
	return Vector3(flat.x, clampf(dir.y, -max_y, max_y), flat.z).normalized()

## Radius-limited steering: rotates the body toward dir no faster than
## swimming a circle of radius_m allows (turn rate = speed / radius), so the
## bulk carves the same wide arcs at any speed instead of snapping. The
## turn pivots near the head (turn_pivot), not the body's center: the snout
## goes where it is aimed and the long body trails round behind it, instead
## of the head sweeping sideways as the whole length spins in place.
func _steer_toward(dir: Vector3, radius_m: float, delta: float) -> void:
	if dir.length() < 0.01:
		return
	if _avoid_urgency > 0.0:
		# rock ahead: bend along it and away from it, the nearer the harder,
		# turning as tightly as it can for once
		var heading := _heading()
		var along := heading - _avoid_normal * heading.dot(_avoid_normal)
		along = along.normalized() if along.length() > 0.05 else heading.cross(Vector3.UP).normalized()
		var away := (along + _avoid_normal * 0.6).normalized()
		dir = dir.normalized().slerp(away, clampf(_avoid_urgency * 1.5, 0.0, 1.0))
		radius_m = minf(radius_m, lerpf(radius_m, avoid_turn_radius, _avoid_urgency))
	var turn_rate := maxf(_speed, 0.5) / maxf(radius_m, 1.0) # rad/s
	dir = _limit_pitch(dir)
	var look_dir := dir if _head_minus_z else -dir
	var up := Vector3.UP if absf(look_dir.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
	var desired := Basis.looking_at(look_dir, up).get_rotation_quaternion()
	var current := global_basis.get_rotation_quaternion()
	var angle := current.angle_to(desired)
	if angle < 0.001:
		return
	var pivot := global_position.lerp(mouth_position(), turn_pivot)
	var pivot_local := pivot - global_position
	var turned := current.slerp(desired, minf(1.0, turn_rate * delta / angle))
	global_basis = Basis(turned)
	global_position = pivot - (turned * current.inverse()) * pivot_local
