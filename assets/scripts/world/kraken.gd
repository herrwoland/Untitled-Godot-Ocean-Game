class_name Kraken extends Node3D
## Something very old that guards a rock. It clings to the rock (or lies on
## the floor) with its arms wrapped round it, barely moving, until the player
## comes into its guard_area — swimming or sailing. Then it uncoils and comes.
##
## Swimming, it reaches: one arm first, two more a few seconds later. A caught
## player is coiled, swung about and dragged down to drown: the arms never
## kill, the held breath does (OxygenController). Mashing jump / swim_up
## (Space) fights the grip loose, harder for every arm that holds on.
## A player on a ship gets the ship: it rises beneath her, grips the hull,
## shakes her for shake_time, rolls her over (the player is thrown off and an
## arm goes for them), then drags her down and home to its rock and keeps her.
## While it has the ship it no longer cares for the player — anyone who
## fought free of that grip is left alone.
## It gives up once the player is leash_distance from its perch, swims home
## and wraps itself round the rock again. A new morning puts everything back.
##
## Huge and slow: every movement is a slow jet stroke (the arms open, then
## snap shut and push), turns are gradual, and the arms are simulated
## (KrakenArm) so they trail, lag and settle on their own.
##
## Body axes: the mantle points along -Z (it swims mantle first), the arms
## grow from the crown at the origin toward +Z, the eyes are on +Y.

enum State { PERCHED, WAKING, HUNT, BOAT, RETURN, FISH }
enum BoatPhase { REACH, SHAKE, FLIP, DRAG }
enum Jet { GATHER, PUSH, GLIDE } # the stroke that carries it home
enum FishPhase { CHASE, REEL, DRAG, SETTLE, FEED } # a giant fish in its waters: lash, reel it in, drag home, feed

@export_group("Territory")
## Where it clings. On a column: put the marker on the column's center line at
## the clinging height, its Y along the column, its +Z (blue) toward the side
## it sits on. On a flat surface (perch_column_radius 0): on the surface, Y
## along the surface normal.
@export var perch: Node3D
## Radius of the column at the perch (m). 0 = no column: it lies on a flat
## surface, arms spread across it, instead of wrapping round.
@export var perch_column_radius := 10.0
## It wakes when the player enters this area (the shapes under it count:
## box, sphere, cylinder, capsule). Size and move it freely in the editor.
@export var guard_area: Area3D
## Player farther than this from the perch: it gives up and goes home.
@export var leash_distance := 200.0
## Seconds it takes to uncoil from the rock once woken.
@export var wake_time := 3.0
## Seconds to settle back onto the rock after swimming home.
@export var settle_time := 5.0

@export_group("Going home")
## Home is one jet stroke: arms opened wide while it turns mantle-first to
## home, snapped shut together, then a long glide. More strokes only if home
## is farther than one can carry it.
@export var jet_open_time := 2.5 # s the arms take to open (it turns toward home meanwhile)
@export var jet_close_time := 1.0 # s for the arms to snap shut: the push
@export var jet_open_spread := 1.1 # how wide the umbrella opens (0 = arms together)
@export var jet_max_speed := 6.0 # m/s the push can give at most: about its usual cruise — the stroke is the look, not a dash
## 1/s the water slows the glide. The push is sized so the glide coasts to a
## stop at home: lower = a longer, gentler coast from a softer push.
@export var jet_glide_drag := 0.08

@export_group("Swimming")
@export var cruise_speed := 4.0 # m/s going home, idle travel
@export var chase_speed := 6.5 # m/s after the prey — slower than a ship at speed
@export var acceleration := 1.2 # m/s² — a body this size gathers way slowly
@export var turn_rate := 0.45 # rad/s at most
## One jet stroke every this many seconds: the arms open slowly, then snap
## shut and push the body on.
@export var stroke_period := 7.0
@export_range(0.0, 2.0, 0.05) var jet_boost := 0.8 # extra speed at the push, as a fraction
## Within this distance of the prey it rears up for the attack (otherwise it
## swims mantle first with the arms trailing).
@export var face_range := 90.0
## Reared up for the attack: degrees the crown tilts down from level (90 =
## upright, mantle straight up). The bottom arms swim it forward meanwhile.
@export var attack_tilt := 55.0
## The swimming arms' stroke, degrees below straight back: where the power
## sweep ends (nearly straight back)...
@export var swim_power_angle := 10.0
## ...and where the slow recovery brings them (forward and down under the body).
@export var swim_recovery_angle := 70.0
@export var hover_distance := 30.0 # m crown to prey it closes to
@export var approach_below := 12.0 # m it keeps beneath the prey while closing in
@export var surface_clearance := 10.0 # m the body stays below the waves
@export var floor_clearance := 10.0 # m above the sea floor (layer 1 under it)
## The body is solid against the world (layer 1: its rock, the floor): a
## sphere round its head and mantle, in the model's own (unscaled) units.
@export var body_center := Vector3(0.0, 0.5, -8.0)
@export var body_radius := 6.0

@export_group("Arms")
@export var arm_root_radius := 1.35 # m, matches the model, so wraps sit on the rock's skin
@export var arm_tip_radius := 0.12
## How quickly the arms follow their shapes (rad/s, the joints' spring frequency):
## about 1 = a change takes 3-4 s to settle. Each role scales it (below).
@export var arm_response := 0.7
@export var reach_response := 1.6 # x arm_response while reaching
@export var hold_response := 1.0 # x while holding the prey
@export var ship_response := 4.0 # x while gripping the ship (a rolling hull is quick)
## Bend limits per joint (degrees): small near the body, large at the tip —
## the base stays long and straight, the distal part curls.
@export var arm_swing_limit := 40.0 # how far the whole arm swings at the crown
@export var arm_bend_root := 4.0 # per joint next to the body...
@export var arm_bend_tip := 50.0 # ...rising to this at the tip
## Fastest any arm joint turns (degrees/s). Joint motions add up toward the tip,
## so this is the real "slow giant" dial.
@export var arm_max_joint_speed := 18.0
@export var arm_max_tip_speed := 14.0 # m/s the tip may travel relative to the body, at most
## Water holding a loose arm back as the body turns (0..1): it trails.
@export_range(0.0, 0.95, 0.05) var arm_drag := 0.5
@export var reach_range := 48.0 # m crown to prey: close enough to send an arm
@export var reach_time := 4.5 # s for the reaching bend to travel from the base out to the tip
@export var reach_speed := 4.0 # m/s a tip closes on a moving hull
@export var reach_seek := 1.2 # 1/s how keenly the tip homes in at the end of a reach
@export var grab_radius := 3.5 # m tip to prey that counts as caught (the coil then pulls them in)
@export var reinforce_delay := 3.0 # s after the first arm reaches, before the next one does (and again)
@export var reinforcements := 2 # extra arms that join the first
@export var reinforcements_with_ship := 0 # ...while it also has the ship in its arms (busy with her)
@export var regrab_cooldown := 5.0 # s after the prey fights free before an arm reaches again
@export var recoil_time := 2.5 # s an arm that lost its grip flails before settling
@export var arm_cull_distance := 450.0 # m from the camera beyond which the arms are left still

@export_group("Holding the player")
## Where the prey is held, in the body's space: in front of the crown.
@export var hold_offset := Vector3(0.0, 0.0, 22.0)
## Same, while it also has the ship in its arms (off to one side of her).
@export var hold_offset_with_ship := Vector3(20.0, 0.0, 12.0)
@export var hold_sway := 4.0 # m the arm swings the prey about
@export var hold_sway_period := 7.0 # s
@export var dive_speed := 3.0 # m/s it sinks with the catch...
@export var dive_depth := 25.0 # ...until the catch is this deep (m under the waves)...
@export var dive_time := 10.0 # ...or for this long at most; then it hangs there while the air runs out
## Looking at the catch: it turns its head so the prey is in front of its eyes.
@export var look_turn_rate := 0.2 # rad/s at most: a slow, heavy turn
@export var eye_center := Vector3(0.0, 1.5, -2.4) # between the eyes, in the model's own (unscaled) space
@export var gaze_direction := Vector3(0.0, 0.8, 0.6) # the way the eyes look together: up from the head, toward the arms
@export var gaze_hold_distance := 18.0 # m in front of the eyes the prey is held
@export var hold_min_depth := 3.0 # m under the surface the catch is always held, at least: it must drown
@export var struggle_per_press := 0.05 # grip loosened by one press, with one arm holding (divided by sqrt of the arms holding)
@export var grip_regain := 0.12 # grip won back per second, per arm holding: at 8 presses/s one arm takes ~3.5 s, two need 10+ presses/s, three cannot be beaten
@export var throw_speed := 6.0 # m/s the prey is flung clear when it fights free
@export var coil_radius := 1.4 # m the tip coils round the body (loosens as they struggle)
@export var coil_length := 6.0 # m of the tip that coils round it

@export_group("The ship")
@export var ship_arms := 5 # arms that grip the hull
@export var ship_grab_depth := 24.0 # m its crown waits beneath the hull
## m/s rising after a ship — its one burst of real speed; it aims where she is going
@export var ship_chase_speed := 9.0
@export var ship_brake := 0.6 # 1/s: once an arm grips, her speed is dragged down this fast
@export var ship_all_arms_wait := 4.0 # s after the first grip it starts shaking, even if not all arms got hold
@export var shake_time := 12.0 # s it shakes her before rolling her over
@export var shake_roll := Vector2(6.0, 35.0) # degrees of roll, at the start and at the end of the shaking
@export var shake_frequency := 0.45 # rocks per second
@export var shake_heave := 1.5 # m it yanks her down on each rock
@export var flip_time := 3.5 # s to roll her over
@export var drag_depth := 70.0 # m below the surface it drags her
@export var drag_speed := 2.5 # m/s
## Where it keeps the ship once home, from the perch: out from the rock and down.
@export var kept_ship_offset := Vector3(0.0, -18.0, 32.0)

@export_group("Idle")
@export var breath_period := 7.0 # s, the mantle swelling and emptying
@export_range(0.0, 0.2, 0.005) var breath_amount := 0.05
@export var idle_drift := 0.08 # radians the wrapped arms creep along the rock
@export var loose_arms := 2 # arms that never quite settle on the rock, drifting
@export var loose_swap_time := 25.0 # s before another arm is the restless one

@export_group("Giant fish")
## A giant fish in its waters comes before the player. Too quick to chase, so
## the arms lash at it; one landing seizes it, and it is dragged home and eaten.
@export var fish_lash_time := 1.4 # s for a lashing arm to strike out its length
@export var fish_lash_interval := 0.6 # s before another arm lashes
@export var fish_arms := 4 # arms that coil round a caught fish
@export var fish_grab_radius := 8.0 # m from its skin that a lashing tip counts as a hit
@export var fish_radius := 10.0 # m, half the fish's thickness: coils sit on it
@export var fish_chase_speed := 8.0 # m/s it closes on a fish
@export var fish_pounce_speed := 14.0 # m/s it lunges behind a lash: the one burst it has
@export var fish_lose_time := 6.0 # s a fish may be out of the waters before it gives up on it
@export var fish_struggle_time := 45.0 # s its fight ebbs away once it is at the mouth, before it goes still
## Seized, it turns away and swims flat out for this long (random in range) —
## about as long as a fish's burst muscles last before they tire — going nowhere: the arms reel it in, tail first, to within fish_reel_stop m
## (model units) of the crown. Then it is brought to the beak.
@export var fish_reel_time := Vector2(12.0, 18.0)
@export var fish_reel_stop := 22.0
@export_range(0.0, 1.0, 0.05) var fish_bite_point := 0.4 # where the beak goes in, from snout (0) to tail (1)
@export var feed_lean := 35.0 # degrees it leans out from its rock to feed, so the fish lies clear of the stone
@export var carry_tilt := 60.0 # degrees its arms point up while it carries a catch home on top of them (90 = straight up)
@export var fish_under_distance := 30.0 # m (model units) it keeps beneath a fish it hunts, arms up at it
@export var fish_hold_gap := 5.0 # m between its mouth and the fish's skin while it holds and eats it
@export var fish_anchor_arms := 2 # free arms that grab the rock while it wrestles a fish, if they can reach it
## While it hunts and hauls in a fish its arms point up at it, but only so far:
## between nearly level and steeply up (degrees above level), never down, never
## straight up — it stays beneath the catch.
@export var fish_arms_elevation := Vector2(10.0, 80.0)
@export var fish_drape_tilt := 32.0 # degrees the dead fish's snout tips down from the bite: with its sag it drapes in an arch
@export var munch_period := 3.0 # s, one slow press of the beak into the fish and back
@export var munch_depth := 0.8 # m it presses in (grows with the model's scale)
@export var munch_twist := 3.0 # degrees each bite twists the fish round the bite: its soft body sways after
## While it also has a fish, the player it holds fights free this many times
## more easily (each press counts more, the grip comes back slower).
@export var struggle_with_fish := 4.0
@export var keep_out_margin := 40.0 # m beyond its waters that idle fish keep to

@export_group("Camera shake")
## The jolt when it wakes and turns on the player (felt within wake_shake_reach m)...
@export_range(0.0, 1.0, 0.05) var wake_shake := 0.75
## ...then a rumble while it uncoils from the rock, fading out over wake_time.
@export_range(0.0, 1.0, 0.05) var wake_rumble := 0.4
@export var wake_shake_reach := 400.0
## The hit when an arm closes on the player.
@export_range(0.0, 1.0, 0.05) var catch_shake := 1.0
## A steady, smaller shake for as long as the player is held (stops once drowned).
@export_range(0.0, 1.0, 0.05) var held_shake := 0.35
## Each struggle press: a little above the held rumble, so it is felt.
@export_range(0.0, 1.0, 0.05) var struggle_shake := 0.45
@export_range(0.0, 1.0, 0.05) var ship_shake := 0.55 # rumble while it shakes her, at the end of the shaking

@onready var _presence_loop: AudioStreamPlayer3D = get_node_or_null(^'PresenceLoop') # while awake
@onready var _wake_sound: AudioStreamPlayer3D = get_node_or_null(^'WakeSound')
@onready var _grab_sound: AudioStreamPlayer3D = get_node_or_null(^'GrabSound') # an arm closes on the prey
@onready var _struggle_sound: AudioStreamPlayer3D = get_node_or_null(^'StruggleSound') # the grip breaks
@onready var _hull_sound: AudioStreamPlayer3D = get_node_or_null(^'HullSound') # creaking hull, the shaking

var state := State.PERCHED
var boat_phase := BoatPhase.REACH

var _skeleton: Skeleton3D
var _scale := 1.0 # the model's scale in this scene: body-size distances are multiplied by it
var _attacking := false # reared up and closing on a swimming prey
var _jet := Jet.GATHER
var _jet_time := 0.0
var _settle_duration := 5.0 # s this settle onto the rock takes (longer from farther)
var _jet_speed := 0.0 # m/s the push gives
var _jet_spread := 0.2 # how open the arms are through the stroke
var _top_arms: Array[int] = [] # arms on the top half of the crown (the eye side): they reach; the rest swim
var _mantle_bone := -1
var _arms: Array[KrakenArm] = []
var _player: Node3D
var _water: Node
var _time := 0.0
var _state_time := 0.0
var _stroke := 0.0 # 0..1 through the current jet stroke
var _velocity := Vector3.ZERO
var _floor_y := -INF
var _floor_check := 0.0
var _settle_from: Transform3D
var _loose: Array[int] = []
var _loose_timer := 0.0

# The prey in its arms.
var _holding := false
var _hold_start := 0.0
var _catch_from := Vector3.ZERO
var _hold_blend := 0.0
var _carrier: KrakenArm # the arm whose coil the prey rides in
var _hold_point := Vector3.ZERO # where the carrier swings the prey to
var _hold_dir := Vector3.UP # from its eyes to where it holds the prey, set at the catch
var _struggle := 0.0 # 0 = gripped tight, 1 = free
var _reach_start := -1.0 # when the first arm of this attempt reached, -1 = none
var _reinforced := 0
var _cooldown := 0.0
var _player_ignored := false # fought free while it had the ship: left alone

# The ship.
var _ship: RigidBody3D
var _ship_kept := false # it has her, for the rest of the day
var _ship_base: Transform3D # her pose when the shaking began
var _ship_draft := 0.0 # her height over the wave at that moment
var _ship_roll := 0.0 # radians, applied about her long axis
var _ship_roll_sign := 1.0
var _ship_offset: Transform3D # her pose in the body's space while dragged
var _ship_disabled: Array[Node] = [] # her dry volumes / wave blockers, off while under
var _thrown := false
var _first_grip := -1.0 # when the first arm got hold of her, -1 = none yet
var _hull_shapes := {} # ship instance id -> HullShape, measured on the first grab
var _fish: Node3D # the giant fish it is after or holding
var _fish_phase := FishPhase.CHASE
var _fish_out_time := 0.0 # s the chased fish has been out of the waters
var _fish_last_pos := Vector3.ZERO
var _fish_vel := Vector3.ZERO # measured, for leading the lashes
var _fish_from: Transform3D # its pose when the settle began
var _lash_wait := 0.0
var _bite_bend := Vector3.ZERO # how far its bent body moves the bite point, in its own space
var _reel_left := 0.0 # s the fish still fights to swim free before it is at the mouth
var _reel_speed := 0.0 # m/s the arms reel it in meanwhile
var _drag_time := 0.0
var _sated := false # fed today: the player may pass
var _guard_r := -1.0 # cached reach of the guard area from the perch
var _anchor_arms: Array[int] = [] # free arms holding the rock while it wrestles a fish
var _body_shape := SphereShape3D.new()
var _fish_rids: Array[RID] = []

# The rock's measured shape (see _measure_rock).
const ROCK_LEVELS := 26
const ROCK_PUSH_SPEED := 35.0 # m/s a held fish is moved out of the rock at most
const ROCK_ANGLES := 16
const ROCK_STEP := 4.0 # m between measured heights...
const ROCK_BELOW := -70.0 # ...from this far below the perch (arms mostly wind downward)
var _rock_measured := false
var _rock_grid := PackedFloat32Array()
var _rock_e1 := Vector3.RIGHT
var _rock_e2 := Vector3.BACK
var _rock_radius: Callable = func(_h: float, _a: float) -> float: return perch_column_radius

## ---- setup -----------------------------------------------------------------

func _ready() -> void:
	add_to_group(&'kraken')
	var skeletons := find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_warning("Kraken '%s': no Skeleton3D in the model, nothing will move." % name)
		return
	_skeleton = skeletons[0]
	_mantle_bone = _skeleton.find_bone("mantle")
	# The model may be scaled in the scene: body distances grow with it.
	_scale = _skeleton.global_basis.get_scale().x / maxf(global_basis.get_scale().x, 0.0001)
	_build_arms()
	if guard_area:
		guard_area.monitoring = false # containment is tested directly (a piloting player has no collider)
		guard_area.monitorable = false
	EventBus.day_started.connect(_on_day_started)
	_reset()

## Arms are found by bone name: arm_<arm>_<joint>, joint 0 at the root.
func _build_arms() -> void:
	var chains := {}
	for b in _skeleton.get_bone_count():
		var parts := _skeleton.get_bone_name(b).split("_")
		if parts.size() == 3 and parts[0] == "arm" and parts[1].is_valid_int() and parts[2].is_valid_int():
			var a := parts[1].to_int()
			if not chains.has(a):
				chains[a] = {}
			chains[a][parts[2].to_int()] = b
	var keys := chains.keys()
	keys.sort()
	for a: int in keys:
		var joints: Dictionary = chains[a]
		var order := joints.keys()
		order.sort()
		var chain := PackedInt32Array()
		for k: int in order:
			chain.append(joints[k])
		var arm := KrakenArm.new(_skeleton, a, chain)
		arm.root_radius = arm_root_radius * _scale
		arm.tip_radius = arm_tip_radius * _scale
		arm.swing_limit = deg_to_rad(arm_swing_limit)
		arm.bend_root = deg_to_rad(arm_bend_root)
		arm.bend_tip = deg_to_rad(arm_bend_tip)
		arm.max_joint_speed = deg_to_rad(arm_max_joint_speed)
		arm.max_tip_speed = arm_max_tip_speed
		arm.configure()
		_arms.append(arm)
	# The top half of the crown ring (the eye side, +Y) reaches in an attack,
	# the bottom half swims.
	var by_height := _arms.duplicate()
	by_height.sort_custom(func(a: KrakenArm, b: KrakenArm) -> bool:
		return _skeleton.get_bone_global_rest(a.bones[0]).origin.y > _skeleton.get_bone_global_rest(b.bones[0]).origin.y)
	for i in by_height.size() / 2:
		_top_arms.append(by_height[i].index)

func _on_day_started(_day: int) -> void:
	_reset()

## The morning: back on the rock, arms wrapped, the ship given back.
func _reset() -> void:
	_release_ship()
	_release_fish()
	_first_grip = -1.0
	if _holding and is_instance_valid(_player):
		_player.set_captured(false)
	_holding = false
	_carrier = null
	_player_ignored = false
	_reach_start = -1.0
	_cooldown = 0.0
	_velocity = Vector3.ZERO
	_thrown = false
	for arm in _arms:
		arm.set_role(KrakenArm.Role.FREE)
	_stop(_presence_loop)
	if perch:
		global_transform = _perch_pose()
	state = State.PERCHED
	_state_time = 0.0
	_pick_loose_arms()
	_set_arm_goals(0.0)
	for arm in _arms:
		arm.snap_to_goals()
		arm.apply_to_skeleton()

## ---- public ------------------------------------------------------------------

## Awake and after someone (the CreatureDirector keeps the hunters off).
func is_awake() -> bool:
	return state == State.WAKING or state == State.HUNT or state == State.BOAT or state == State.FISH

func is_holding_player() -> bool:
	return _holding

## ---- main loop ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _skeleton == null or perch == null:
		return
	if _player == null:
		_player = get_tree().get_first_node_in_group(&'player') as Node3D
	if _water == null:
		_water = get_tree().get_first_node_in_group(&'water')
	if _player == null:
		return
	if not _rock_measured and perch_column_radius > 0.0:
		_measure_rock() # the physics world is ready now, not in _ready
		if state == State.PERCHED:
			_reset()
	_time += delta
	_state_time += delta
	_stroke = fmod(_stroke + delta / maxf(stroke_period, 0.5), 1.0)
	_cooldown = maxf(_cooldown - delta, 0.0)

	match state:
		State.PERCHED: _process_perched(delta)
		State.WAKING: _process_waking(delta)
		State.HUNT: _process_hunt(delta)
		State.BOAT: _process_boat(delta)
		State.RETURN: _process_return(delta)
		State.FISH: _process_fish(delta)

	if state == State.HUNT or state == State.BOAT:
		_update_reaching(delta)
	if _holding:
		_update_hold(delta)
	_update_arms(delta)
	_breathe()

func _set_state(new_state: State) -> void:
	state = new_state
	if new_state == State.RETURN:
		_jet = Jet.GATHER
		_jet_time = 0.0
	_attacking = false
	_state_time = 0.0

## ---- states ------------------------------------------------------------------

func _process_perched(_delta: float) -> void:
	# A slow heave against the rock, not stillness.
	var pose := _perch_pose()
	var bob := sin(_time * TAU / (breath_period * 1.7)) * 0.35
	global_transform = Transform3D(pose.basis.rotated(pose.basis.x, sin(_time * 0.21) * 0.025), pose.origin + pose.basis.y * bob)
	if _ship_kept:
		_carry_kept_ship()
		return # it has what it wanted
	if _in_guard_area(_player.global_position) or (not _sated and _fish_in_area() != null):
		_set_state(State.WAKING)
		_play(_wake_sound)
		_play(_presence_loop)
		_shake_near(wake_shake, wake_shake_reach)

## Uncoiling: the arms let go of the rock and it eases away from it.
func _process_waking(delta: float) -> void:
	# A giant fish swimming through will not wait: it uncoils at once for that.
	if not _sated:
		var fish := _fish_in_area()
		if fish:
			_begin_fish(fish)
			return
	_shake_near(wake_rumble * (1.0 - clampf(_state_time / maxf(wake_time, 0.1), 0.0, 1.0)), wake_shake_reach)
	var away := perch.global_basis.z.normalized() if perch_column_radius > 0.0 else perch.global_basis.y.normalized()
	_velocity = _velocity.move_toward(away * 1.2, acceleration * delta)
	_move_body(global_position + _velocity * delta)
	if _state_time >= wake_time:
		_set_state(State.HUNT)

func _process_hunt(delta: float) -> void:
	# A giant fish in its waters is the bigger meal: it goes for that first.
	if not _sated:
		var fish := _fish_in_area()
		if fish:
			_begin_fish(fish)
			return
	if not _holding and _player_beyond_leash():
		_give_up()
		return
	var ship := _ship_under_player()
	if ship and not _holding and not _player_ignored:
		_ship = ship
		boat_phase = BoatPhase.REACH
		_first_grip = -1.0
		_set_state(State.BOAT)
		for arm in _arms:
			if arm.role == KrakenArm.Role.REACH:
				arm.set_role(KrakenArm.Role.FREE) # the arms go for the hull instead
		_reach_start = -1.0
		return

	if _holding:
		_attacking = false
		# Down with the catch, then hang there in the dark.
		var deep_enough := _player.global_position.y < _surface_y(_player.global_position) - dive_depth
		if not deep_enough and _state_hold_time() < dive_time:
			_swim_toward(global_position + Vector3.DOWN * 50.0, dive_speed, false, delta, 3.0)
		else:
			_swim_toward(global_position, 0.0, false, delta)
		_look_at_prey(delta) # it turns, slowly, to see what it has caught
		return

	var prey := _prey_point()
	var to_prey := prey - global_position
	var dist := to_prey.length()
	var flat := Vector3(to_prey.x, 0.0, to_prey.z)
	flat = flat.normalized() if flat.length() > 0.1 else -global_basis.z
	# Close to hover_distance from the prey, a little below it.
	var goal := prey - flat * hover_distance * _scale + Vector3.DOWN * approach_below * _scale
	# Close in: it rears up — mantle up and back, crown tilted forward-down —
	# the top arms opening toward the prey and the bottom arms swimming behind.
	_attacking = dist < face_range * _scale
	var face: Variant = null
	if _attacking:
		var tilt := deg_to_rad(attack_tilt)
		face = (flat * cos(tilt) + Vector3.DOWN * sin(tilt)).normalized()
	_swim_toward(goal, chase_speed, face, delta)

## Going after the ship the player is on: rise beneath her, grip, shake,
## roll her, drag her down and home.
func _process_boat(delta: float) -> void:
	if not is_instance_valid(_ship):
		_give_up()
		return
	match boat_phase:
		BoatPhase.REACH:
			if _ship_under_player() != _ship and _first_grip < 0.0:
				# They jumped off before it got hold of her: go for them instead.
				_release_ship_arms()
				_set_state(State.HUNT)
				return
			if _player_beyond_leash() and _first_grip < 0.0: # once it has hold of her, it does not let go
				_give_up()
				return
			# Rise to where she is going to be, beneath her.
			var ship_vel := _ship.linear_velocity
			var lead := minf(global_position.distance_to(_ship.global_position) / maxf(ship_chase_speed, 1.0), 4.0)
			var below := _ship.global_position + ship_vel * lead + Vector3.DOWN * ship_grab_depth * _scale
			_swim_toward(below, ship_chase_speed, Vector3.UP, delta)
			if global_position.distance_to(_ship.global_position) < (reach_range + ship_grab_depth) * _scale:
				_assign_ship_arms()
			var gripping := 0
			var assigned := 0
			for arm in _arms:
				if arm.role != KrakenArm.Role.BOAT:
					continue
				assigned += 1
				var attach := _ship.to_global(arm.hull_path[0])
				if arm.gripped:
					arm.tip_target = _clamp_reach(arm, attach)
					gripping += 1
					continue
				# reaching for a moving hull: carried along with her, closing in on top
				var reach := arm.tip_target + ship_vel * delta
				arm.tip_target = _clamp_reach(arm, reach.move_toward(attach, reach_speed * delta))
				if arm.tip().distance_to(attach) < 2.0:
					arm.gripped = true
					if _first_grip < 0.0:
						_first_grip = _time
						_play(_hull_sound)
						_shake_near(catch_shake, 80.0)
			if gripping > 0:
				# one arm on her is an anchor: she is dragged to a stop, engine or not
				_ship.apply_central_force(-ship_vel * _ship.mass * ship_brake)
			if assigned > 0 and (gripping == assigned or (_first_grip >= 0.0 and _time - _first_grip > ship_all_arms_wait)):
				_begin_shake()
		BoatPhase.SHAKE:
			_hold_ship_arms()
			var t := clampf(_state_time / maxf(shake_time, 0.1), 0.0, 1.0)
			var amp := deg_to_rad(lerpf(shake_roll.x, shake_roll.y, t))
			var rock := sin(_state_time * TAU * shake_frequency)
			_ship_roll = amp * rock
			_ship_roll_sign = signf(rock) if absf(rock) > 0.2 else _ship_roll_sign
			var heave := shake_heave * maxf(0.0, -cos(_state_time * TAU * shake_frequency * 2.0)) * (0.4 + t)
			_pose_ship(heave)
			_swim_toward(_ship.global_position + Vector3.DOWN * ship_grab_depth * _scale, chase_speed, Vector3.UP, delta)
			_shake_near(lerpf(ship_shake * 0.3, ship_shake, t), 80.0)
			if _state_time >= shake_time:
				boat_phase = BoatPhase.FLIP
				_state_time = 0.0
				_play(_hull_sound)
		BoatPhase.FLIP:
			_hold_ship_arms()
			var t := clampf(_state_time / maxf(flip_time, 0.1), 0.0, 1.0)
			var start := deg_to_rad(shake_roll.y) * _ship_roll_sign
			_ship_roll = lerpf(start, PI * _ship_roll_sign, t * t * (3.0 - 2.0 * t))
			_pose_ship(t * 4.0)
			_swim_toward(_ship.global_position + Vector3.DOWN * ship_grab_depth * _scale, chase_speed, Vector3.UP, delta)
			_shake_near(ship_shake, 80.0)
			if absf(_ship_roll) > deg_to_rad(65.0) and not _thrown:
				_throw_player_off()
			if _state_time >= flip_time:
				boat_phase = BoatPhase.DRAG
				_state_time = 0.0
				_ship_offset = global_transform.affine_inverse() * _ship.global_transform
				_submerge_ship(true)
		BoatPhase.DRAG:
			_hold_ship_arms()
			# Straight down first, then home along the bottom of the dark.
			var deep_y := _surface_y(global_position) - drag_depth
			var home := _perch_pose().origin + _perch_out() * 25.0 * _scale
			if global_position.y > deep_y + 3.0 and _state_time < 30.0:
				_swim_toward(Vector3(global_position.x, deep_y, global_position.z), drag_speed, Vector3.UP, delta)
			else:
				_swim_toward(home, drag_speed, null, delta)
			_follow_with_ship(delta)
			if global_position.distance_to(home) < 8.0:
				_ship_kept = true
				_player_ignored = true
				_settle_from = global_transform
				_settle_duration = settle_time
				_set_state(State.RETURN)
				_state_time = 0.0

## Swim home, then ease back onto the rock.
func _process_return(delta: float) -> void:
	var pose := _perch_pose()
	# the stroke aims at its place on the rock itself, just off the surface:
	# the settle then only has the last few meters to ease in
	var approach := pose.origin + _perch_out() * 6.0 * _scale
	if _ship_kept:
		_carry_kept_ship()
	if _settle_from == Transform3D():
		_jet_home(approach, delta)
		if global_position.distance_to(approach) < 10.0 * _scale:
			_settle_from = global_transform
			# never faster than ~2 m/s onto the rock (smoothstep peaks at 1.5x the average)
			_settle_duration = maxf(settle_time, global_position.distance_to(pose.origin) * 0.75)
			_state_time = 0.0
		return
	var t := clampf(_state_time / maxf(_settle_duration, 0.1), 0.0, 1.0)
	var s := t * t * (3.0 - 2.0 * t)
	global_transform = Transform3D(
		Basis(_settle_from.basis.get_rotation_quaternion().slerp(pose.basis.get_rotation_quaternion(), s)),
		_settle_from.origin.lerp(pose.origin, s))
	if t >= 1.0:
		_velocity = Vector3.ZERO
		_settle_from = Transform3D()
		_stop(_presence_loop)
		_set_state(State.PERCHED)

## Home the way an octopus travels: one jet stroke. It turns its mantle
## toward home while the arms open wide (the umbrella opening), then snaps
## them shut together — the water squeezed out drives it off mantle first —
## and glides with the arms trailing in a tight bundle, slowing in the water.
## The push is sized so the glide ends at home; if home is farther than one
## push can carry it (jet_max_speed), it simply strokes again.
func _jet_home(home: Vector3, delta: float) -> void:
	_jet_time += delta
	var to_home := home - global_position
	var dir := to_home.normalized() if to_home.length() > 0.01 else -global_basis.z
	match _jet:
		Jet.GATHER:
			_velocity *= exp(-jet_glide_drag * 3.0 * delta) # it brakes as it gathers
			_glide(delta)
			_turn_crown_toward(-dir, delta) # mantle toward home: arms toward the push
			_jet_spread = lerpf(0.2, jet_open_spread, smoothstep(0.0, jet_open_time, _jet_time))
			var aligned := (-global_basis.z).angle_to(dir) < deg_to_rad(25.0)
			if (_jet_time >= jet_open_time and aligned) or _jet_time >= jet_open_time * 2.5:
				_jet = Jet.PUSH
				_jet_time = 0.0
				# speed for a glide that coasts to a stop right at home
				_jet_speed = minf(to_home.length() * jet_glide_drag * 1.15, jet_max_speed) # a little extra: the glide carries it all the way in
		Jet.PUSH:
			var t := smoothstep(0.0, jet_close_time, _jet_time)
			_jet_spread = lerpf(jet_open_spread, 0.02, t)
			_velocity = -global_basis.z * _jet_speed * t # the surge builds as the arms close
			_glide(delta)
			if _jet_time >= jet_close_time:
				_jet = Jet.GLIDE
				_jet_time = 0.0
		Jet.GLIDE:
			# coast, bending gently onto home, the bundle trailing behind
			var speed := _velocity.length() * exp(-jet_glide_drag * delta)
			var heading := _velocity.normalized() if speed > 0.01 else dir
			heading = heading.slerp(dir, minf(1.0, 0.4 * delta)).normalized()
			_velocity = heading * speed
			_glide(delta)
			_turn_crown_toward(-heading, delta)
			_jet_spread = lerpf(0.02, 0.15, smoothstep(jet_max_speed * 0.3, 1.0, speed))
			if speed < 1.0:
				_jet = Jet.GATHER # not home yet: another stroke
				_jet_time = 0.0

## Move the body toward a position without passing through the world (layer
## 1: its rock, the sea floor, other rocks). A sphere round its head and mantle
## is swept along the move; if it would hit, it stops at the surface and slides
## along it with what is left. Already touching (uncoiling from the perch), it
## may move away or along, never deeper in. The arms are not tested.
func _move_body(target: Vector3) -> void:
	var motion := target - global_position
	if motion.length_squared() < 1e-10:
		return
	var space := get_world_3d().direct_space_state
	_body_shape.radius = body_radius * _scale
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _body_shape
	query.collision_mask = 1
	query.exclude = _fish_bodies() # fish are bodies to grab, not walls
	var center := _skeleton.global_transform * body_center # in the model's units
	query.transform = Transform3D(Basis.IDENTITY, center)
	var touching := space.get_rest_info(query)
	if not touching.is_empty():
		var n: Vector3 = touching.normal
		var into := motion.dot(n)
		if into < 0.0:
			motion -= n * into # along the rock, not into it
		global_position += motion
		return
	query.motion = motion
	var fractions := space.cast_motion(query)
	if fractions[0] >= 1.0:
		global_position += motion
		return
	global_position += motion * fractions[0]
	# slide the rest of the move along the surface it met
	query.motion = Vector3.ZERO
	query.transform = Transform3D(Basis.IDENTITY, center + motion * fractions[1])
	var hit := space.get_rest_info(query)
	if not hit.is_empty():
		var n: Vector3 = hit.normal
		var rest := motion * (1.0 - fractions[0])
		global_position += rest - n * minf(rest.dot(n), 0.0)

## Turning swings its head and mantle round the crown, which no move check
## sees: if that has left them in rock, they are eased back out.
func _push_body_out(delta: float) -> void:
	_body_shape.radius = body_radius * _scale
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _body_shape
	query.collision_mask = 1
	query.exclude = _fish_bodies()
	var center := _skeleton.global_transform * body_center
	query.transform = Transform3D(Basis.IDENTITY, center)
	var hit := get_world_3d().direct_space_state.get_rest_info(query)
	if hit.is_empty():
		return
	var n: Vector3 = hit.normal
	var hit_point: Vector3 = hit.point
	var depth := _body_shape.radius - (center - hit_point).dot(n)
	if depth > 0.0:
		global_position += n * minf(depth, 15.0 * delta)

## The giant fishes' own colliders (they sit on the world layer too).
func _fish_bodies() -> Array[RID]:
	if _fish_rids.is_empty():
		for fish in get_tree().get_nodes_in_group(&'giant_fish'):
			for body: CollisionObject3D in fish.find_children("*", "CollisionObject3D", true, false):
				_fish_rids.append(body.get_rid())
	return _fish_rids

## Move by the current velocity, kept under the waves and over the floor.
func _glide(delta: float) -> void:
	var pos := global_position + _velocity * delta
	pos.y = minf(pos.y, _surface_y(pos) - surface_clearance * _scale)
	pos.y = maxf(pos.y, _floor_height(delta) + floor_clearance * _scale)
	_move_body(pos)

## ---- a giant fish ------------------------------------------------------------
## A giant fish in its waters is a far bigger meal than the player: it goes
## for the fish first. The fish is much faster than it, so instead of the slow
## reach the arms LASH — a fast strike at the nearest part of the passing body.
## One that lands seizes it: the arms coil round the fish, the kraken drags it
## home to its rock and settles there with its beak in the fish's flank,
## munching, the fish thrashing for fish_struggle_time seconds and then still.
## Fed, it wants nothing more today: the player may pass. A player it is
## already holding stays held, but its grip on them is far weaker now.

## A giant fish (any of group "giant_fish") with any part of it in the waters.
func _fish_in_area() -> Node3D:
	for fish in get_tree().get_nodes_in_group(&'giant_fish'):
		if not fish.is_visible_in_tree() or fish.is_seized():
			continue
		var ends: PackedVector3Array = fish.body_ends()
		if _in_guard_area(ends[0]) or _in_guard_area(fish.global_position) or _in_guard_area(ends[1]):
			return fish
	return null

func _begin_fish(fish: Node3D) -> void:
	_fish = fish
	_fish_phase = FishPhase.CHASE
	_fish_out_time = 0.0
	_fish_last_pos = fish.global_position
	_fish_vel = Vector3.ZERO
	_set_state(State.FISH)
	for arm in _arms:
		if arm.role == KrakenArm.Role.REACH:
			arm.set_role(KrakenArm.Role.RECOIL) # forget the small one
	_reach_start = -1.0

func _process_fish(delta: float) -> void:
	if not is_instance_valid(_fish):
		_set_state(State.HUNT)
		return
	match _fish_phase:
		FishPhase.CHASE: _fish_chase(delta)
		FishPhase.REEL: _fish_reel(delta)
		FishPhase.DRAG: _fish_drag(delta)
		FishPhase.SETTLE: _fish_settle()
		FishPhase.FEED: _fish_feed()

## After the fish: close on the nearest part of it, lashing whenever it is in reach.
func _fish_chase(delta: float) -> void:
	if _fish.is_seized(): # something else got it
		_set_state(State.HUNT)
		return
	_fish_vel = _fish_vel.lerp((_fish.global_position - _fish_last_pos) / maxf(delta, 0.001), minf(delta * 3.0, 1.0))
	_fish_last_pos = _fish.global_position
	var ends: PackedVector3Array = _fish.body_ends()
	var inside := _in_guard_area(ends[0]) or _in_guard_area(_fish.global_position) or _in_guard_area(ends[1])
	_fish_out_time = 0.0 if inside else _fish_out_time + delta
	if _fish_out_time > fish_lose_time:
		_release_fish_arms()
		_set_state(State.HUNT) # it got away: back to the small one (or home, past the leash)
		return
	var near := _nearest_on_fish(global_position)
	var to_fish := near - global_position
	var pouncing := false
	for arm in _arms:
		if arm.role == KrakenArm.Role.FISH:
			pouncing = true
	# from beneath: it keeps under the fish, arms up at it
	var below := near + Vector3.DOWN * fish_under_distance * _scale
	if pouncing: # it throws itself up at the fish behind the lash
		_swim_toward(near + _fish_vel * 0.8 + Vector3.DOWN * fish_radius * 2.0, fish_pounce_speed, _arms_up_at(to_fish), delta, 5.0)
	else:
		_swim_toward(below + _fish_vel * 1.5, fish_chase_speed, _arms_up_at(to_fish), delta)
	# Lash: one more arm every fish_lash_interval while the body is within reach.
	var lashing := 0
	for arm in _arms:
		if arm.role != KrakenArm.Role.FISH:
			continue
		lashing += 1
		# aim where the fish WILL be when the tip gets there, not where it is
		var lead := maxf(fish_lash_time - arm.timer, 0.0) + 0.25
		var ahead := _fish_vel * lead
		arm.tip_target = _clamp_reach(arm, _nearest_on_fish(arm.root() - ahead) + ahead)
		arm.reach_front = smoothstep(0.0, fish_lash_time, arm.timer)
		arm.seek_tip = 4.0 * smoothstep(0.5, 1.0, arm.reach_front)
		if _distance_to_fish(arm.tip()) < fish_grab_radius:
			_seize_fish()
			return
		if arm.timer > fish_lash_time * 2.5:
			arm.set_role(KrakenArm.Role.RECOIL) # missed
	_lash_wait = maxf(_lash_wait - delta, 0.0)
	if lashing < fish_arms and _lash_wait <= 0.0:
		var best: KrakenArm = null
		var best_d := INF
		for arm in _arms:
			# only an arm the fish is truly within reach of strikes
			if arm.role == KrakenArm.Role.FREE and _distance_to_fish(arm.root() - _fish_vel * fish_lash_time) < arm.length * 0.9:
				var d := _distance_to_fish(arm.points[arm.points.size() / 2])
				if d < best_d:
					best_d = d
					best = arm
		if best:
			best.set_role(KrakenArm.Role.FISH)
			_lash_wait = fish_lash_interval

## Got it: the arms coil round the fish, and it fights to swim free.
func _seize_fish() -> void:
	_bite_bend = Vector3.ZERO
	_fish.seize(fish_struggle_time)
	_sated = true
	_player_ignored = not _holding # fed: the player may pass (one already held stays held)
	_fish_phase = FishPhase.REEL
	_reel_left = randf_range(fish_reel_time.x, fish_reel_time.y)
	# reeled in from where it was caught to within fish_reel_stop of the crown
	var gap := _nearest_on_fish(global_position).distance_to(global_position)
	_reel_speed = maxf(gap - fish_reel_stop * _scale, 0.0) / _reel_left
	_play(_grab_sound)
	_shake_near(catch_shake, 150.0 * _scale)
	var stations := [0.25, 0.4, 0.55, 0.7]
	var count := 0
	for arm in _arms:
		if arm.role == KrakenArm.Role.FISH:
			arm.gripped = true
			arm.reach_front = 1.0
			arm.seek_tip = 0.0
			count += 1
	while count < fish_arms:
		var best: KrakenArm = null
		var best_d := INF
		for arm in _arms:
			if arm.role == KrakenArm.Role.FREE or arm.role == KrakenArm.Role.RECOIL:
				var d := _distance_to_fish(arm.points[arm.points.size() / 2])
				if d < best_d:
					best_d = d
					best = arm
		if best == null:
			break
		best.set_role(KrakenArm.Role.FISH)
		best.gripped = true
		count += 1
	var i := 0
	for arm in _arms:
		if arm.role == KrakenArm.Role.FISH:
			arm.fish_station = stations[i % stations.size()]
			i += 1

## Trapped: the fish turns away and swims flat out — and goes nowhere. The arms
## reel it in, tail first, slowly, while the kraken holds still, facing it.
func _fish_reel(delta: float) -> void:
	var ends: PackedVector3Array = _fish.body_ends()
	var mid: Vector3 = ends[0].lerp(ends[1], 0.5)
	var away := mid - global_position
	away = away.normalized() if away.length() > 0.01 else -global_basis.z
	# its underside — arms and beak — turns to the catch (keeping its back as
	# near up as that allows) while it hauls it in
	var to_catch := _nearest_on_fish(global_position) - global_position
	_swim_toward(global_position, 0.0, _arms_up_at(to_catch if to_catch.length() > 0.01 else away), delta)
	# it points its snout away from the kraken, as if to flee
	var flat := Vector3(away.x, away.y * 0.3, away.z).normalized()
	var head_minus_z: bool = _fish.get(&'_head_minus_z') != false
	var look := Basis.looking_at(flat if head_minus_z else -flat, Vector3.UP)
	var k := 1.0 - exp(-0.7 * delta) # a heavy turn: a 150 m body cannot whip round
	var rot := _fish.global_basis.get_rotation_quaternion().slerp(look.get_rotation_quaternion(), k)
	# dragged backwards toward its beak, a little jolt with every beat of its tail
	var beak := global_position + global_basis.z.normalized() * (2.0 * _scale + fish_radius + fish_hold_gap)
	var to_beak := beak - mid
	to_beak = to_beak.normalized() if to_beak.length() > 0.01 else -away
	var beat := 0.75 + 0.25 * sin(_time * TAU * 1.6)
	_fish.global_transform = Transform3D(Basis(rot), _fish.global_position + to_beak * _reel_speed * beat * delta)
	_keep_fish_under()
	_clear_fish_of_rock()
	_clear_fish_of_body()
	_reel_left -= delta
	if _reel_left <= 0.0:
		_fish_phase = FishPhase.DRAG
		_drag_time = 0.0

## Arms toward dir, but kept between nearly level and steeply up
## (fish_arms_elevation): beneath a fish, never over it, never on its back.
func _arms_up_at(dir: Vector3) -> Vector3:
	var flat := Vector3(dir.x, 0.0, dir.z)
	flat = flat.normalized() if flat.length() > 0.01 else -global_basis.z
	var elevation := asin(clampf(dir.normalized().y, -1.0, 1.0))
	elevation = clampf(elevation, deg_to_rad(fish_arms_elevation.x), deg_to_rad(fish_arms_elevation.y))
	return (flat * cos(elevation) + Vector3.UP * sin(elevation)).normalized()

## Its posture while it carries a catch home: arms and beak up, the catch held
## on top of them, tipped forward toward dir (flat) — it came from beneath and
## keeps the catch above it.
func _carry_face(dir: Vector3) -> Vector3:
	var flat := Vector3(dir.x, 0.0, dir.z)
	flat = flat.normalized() if flat.length() > 0.01 else -global_basis.z
	var tilt := deg_to_rad(carry_tilt)
	return (flat * cos(tilt) + Vector3.UP * sin(tilt)).normalized()

## The held fish never passes through its head and mantle: wherever its body
## is closer than both their thicknesses, it is eased away (no jolt).
func _clear_fish_of_body() -> void:
	var c := _skeleton.global_transform * body_center
	var keep := body_radius * _scale + fish_radius
	var worst := 0.0
	var push := Vector3.ZERO
	for i in 13:
		var p: Vector3 = _fish.body_point(i / 12.0)
		var deficit := keep - p.distance_to(c)
		if deficit > worst:
			worst = deficit
			push = (p - c).normalized() if p.distance_to(c) > 0.01 else global_basis.z
	if worst > 0.0:
		_fish.global_position += push * minf(worst, ROCK_PUSH_SPEED * get_physics_process_delta_time())

## Home with it, bringing it round to its mouth: its flank to the beak. Once
## there, the fish still beats its tail, but slower and slower (fade_struggle).
func _fish_drag(delta: float) -> void:
	var home := _perch_pose().origin + _perch_out() * 6.0 * _scale # right to its place on the rock
	_drag_time += delta
	# a few seconds to bring it to the beak before it heads home with it
	# upright the whole way, crown down and forward with the catch under it
	var travel := home - global_position
	travel.y = 0.0
	var face := _carry_face(travel if travel.length() > 1.0 else -global_basis.z)
	if _drag_time > 3.0:
		_swim_toward(home, cruise_speed, face, delta)
	else:
		_swim_toward(global_position, 0.0, face, delta)
	_pose_fish(_held_pose(global_transform), 1.2, delta)
	_hold_bite(delta, global_transform)
	_clear_fish_of_rock()
	_clear_fish_of_body()
	if not _fish.is_fading():
		var beak := global_position + global_basis.z.normalized() * (2.0 * _scale + fish_radius + fish_hold_gap)
		if _fish.body_point(fish_bite_point).distance_to(beak) < 6.0 * _scale or _drag_time > 8.0:
			_fish.fade_struggle(fish_struggle_time) # at its mouth: the fight starts to ebb
	if global_position.distance_to(home) < 10.0 * _scale:
		_fish_phase = FishPhase.SETTLE
		_settle_from = global_transform
		_settle_duration = clampf(global_position.distance_to(_perch_pose().origin) * 0.75, settle_time, 12.0)
		_state_time = 0.0
		_fish_from = _fish.global_transform

## Onto the rock, bringing the fish round under its beak.
func _fish_settle() -> void:
	if not _fish.is_fading():
		_fish.fade_struggle(fish_struggle_time) # home before it reached the beak: still, it starts to ebb
	var pose := _feed_body_pose()
	var t := clampf(_state_time / maxf(_settle_duration, 0.1), 0.0, 1.0)
	var s := t * t * (3.0 - 2.0 * t)
	global_transform = Transform3D(
		Basis(_settle_from.basis.get_rotation_quaternion().slerp(pose.basis.get_rotation_quaternion(), s)),
		_settle_from.origin.lerp(pose.origin, s))
	var feed := _feed_pose()
	_fish.global_transform = Transform3D(
		Basis(_fish_from.basis.get_rotation_quaternion().slerp(feed.basis.get_rotation_quaternion(), s)),
		_fish_from.origin.lerp(feed.origin, s))
	_keep_fish_under()
	_clear_fish_of_rock()
	_hold_bite(get_physics_process_delta_time())
	_clear_fish_of_body()
	if t >= 1.0:
		_fish_phase = FishPhase.FEED
		_settle_from = Transform3D()
		_velocity = Vector3.ZERO

## On its rock, beak in the fish's flank, munching: the body presses in and
## eases back, slowly; the fish jerks in its arms while it still can.
func _fish_feed() -> void:
	var pose := _feed_body_pose()
	var munch := (0.5 - 0.5 * cos(_time * TAU / maxf(munch_period, 0.5))) * munch_depth * _scale
	var wobble := sin(_time * TAU / (munch_period * 1.7)) * 0.03
	global_transform = Transform3D(pose.basis.rotated(pose.basis.x, wobble), pose.origin + pose.basis.z * munch)
	# each press of the beak shoves the fish a little; its soft body sways after
	var feed := _feed_pose()
	var beak := pose.origin + pose.basis.z * (2.0 * _scale + fish_radius + fish_hold_gap)
	var tug := Basis(pose.basis.z.normalized(), deg_to_rad(munch_twist) * (munch / maxf(munch_depth * _scale, 0.01) - 0.5))
	feed = Transform3D(tug * feed.basis, beak + tug * (feed.origin - beak)) # a twisting tug round the bite
	feed.origin += pose.basis.z * munch * 0.7
	_pose_fish(feed, 4.0, get_physics_process_delta_time())
	_hold_bite(get_physics_process_delta_time())
	_clear_fish_of_rock()

## Its pose while it feeds: on its rock, but leaning out from it (pivoting at
## the head, so the mantle stays against the rock) to bring its beak to a fish
## held clear of the stone.
func _feed_body_pose() -> Transform3D:
	var pose := _perch_pose()
	var lean := deg_to_rad(feed_lean)
	var out := pose.basis.y.normalized()
	var down := pose.basis.z.normalized()
	var z := (down * cos(lean) + out * sin(lean)).normalized()
	var y := (out * cos(lean) - down * sin(lean)).normalized()
	var basis := Basis(pose.basis.x.normalized(), y, z)
	var pivot := pose.origin - down * 8.0 * _scale # the head
	return Transform3D(basis, pivot + basis * (pose.basis.inverse() * (pose.origin - pivot)))

## Where the fish lies while it is eaten: under the crown, on its side, its
## flank up against the beak at fish_bite_point of the way from its snout,
## lying along the rock.
func _feed_pose() -> Transform3D:
	return _held_pose(_feed_body_pose())

## The fish held at the beak of a body in pose (its flank to the crown, along
## the body's side axis), wherever the body is: in open water or on the rock.
func _held_pose(pose: Transform3D) -> Transform3D:
	var crown_dir := pose.basis.z.normalized() # down the rock, out of the crown
	var beak := pose.origin + crown_dir * 2.0 * _scale
	var lie := pose.basis.x.normalized() # along the rock's face
	var head_minus_z: bool = _fish.get(&'_head_minus_z') != false
	# draped: the snout tipped down from the bite, so with its soft sag the body
	# hangs over the hold in an arch, head and tail both falling away
	var fight: float = _fish.struggle()
	var tilt := deg_to_rad(lerpf(fish_drape_tilt, fish_drape_tilt * 0.4, fight))
	var snout_dir := (lie * cos(tilt) + Vector3.DOWN * sin(tilt)).normalized()
	var z := -snout_dir if head_minus_z else snout_dir
	var x := (-crown_dir - snout_dir * (-crown_dir).dot(snout_dir)).normalized() # its flank faces the beak
	var y := z.cross(x).normalized()
	var basis := Basis(x, y, z).orthonormalized()
	# the bite point on its body line, in its own space
	var snout_local: Vector3 = _fish.to_local(_fish.mouth_position())
	var heading_local := Vector3(0, 0, -1) if head_minus_z else Vector3(0, 0, 1)
	var fish_length: float = _fish.body_length
	var bite_local: Vector3 = snout_local - heading_local * fish_length * fish_bite_point
	var contact := beak + crown_dir * (fish_radius + fish_hold_gap) # held a little off the mouth
	# its body is bent (soft, sagging): where its REAL bite point sits, in its own
	# space, is measured (_bite_bend) — that point goes onto the beak
	return Transform3D(basis, contact - basis * (bite_local + _bite_bend))

## Measure how far its bent body has carried the bite point from where a
## straight body would have it, in the fish's own space, smoothed. A plain
## measurement, never an accumulated error: it cannot run away and shake.
func _hold_bite(delta: float, _pose: Transform3D = Transform3D()) -> void:
	var head_minus_z: bool = _fish.get(&'_head_minus_z') != false
	var snout_local: Vector3 = _fish.to_local(_fish.mouth_position())
	var heading_local := Vector3(0, 0, -1) if head_minus_z else Vector3(0, 0, 1)
	var fish_length: float = _fish.body_length
	var straight: Vector3 = snout_local - heading_local * fish_length * fish_bite_point
	var bent: Vector3 = _fish.to_local(_fish.body_point(fish_bite_point))
	_bite_bend = _bite_bend.lerp(bent - straight, 1.0 - exp(-2.0 * delta))

## Move the held fish toward a pose (softly, at rate 1/s) and add its thrashing.
func _pose_fish(target: Transform3D, rate: float, delta: float) -> void:
	var k := 1.0 - exp(-rate * delta)
	var current := _fish.global_transform
	var fight: float = _fish.struggle()
	# heavy lurches with its tail beats while it fights: slow and small, a body
	# this size cannot shiver
	var lurch := Basis.from_euler(Vector3(sin(_time * TAU * 0.8) * 0.03, sin(_time * TAU * 0.55 + 1.0) * 0.02, sin(_time * TAU * 0.8 + 2.0) * 0.035) * fight)
	var rot := current.basis.get_rotation_quaternion().slerp((target.basis * lurch).get_rotation_quaternion(), k)
	_fish.global_transform = Transform3D(Basis(rot), current.origin.lerp(target.origin, k))
	_keep_fish_under()

## Nothing of a held fish goes into its rock: points along its body are
## checked against the rock's measured shape, and where one lies closer to the
## column than its surface plus the fish's thickness, the whole fish is moved
## out, away from the column.
func _clear_fish_of_rock() -> void:
	if perch == null or perch_column_radius <= 0.0 or not _rock_measured:
		return
	var up := perch.global_basis.y.normalized()
	for _pass in 2:
		var worst := 0.0
		var push := Vector3.ZERO
		for i in 9:
			var rel: Vector3 = _fish.body_point(i / 8.0) - perch.global_position
			var h := rel.dot(up)
			var flat := rel - up * h
			var a := atan2(flat.dot(_rock_e2), flat.dot(_rock_e1))
			var deficit: float = float(_rock_radius.call(h, a)) + fish_radius + 1.0 - flat.length()
			if deficit > worst:
				worst = deficit
				push = flat.normalized() if flat.length() > 0.01 else _perch_out()
		if worst <= 0.0:
			return
		# out smoothly over a few frames, never a jolt
		_fish.global_position += push * minf(worst, ROCK_PUSH_SPEED * get_physics_process_delta_time())

## A held fish stays under the waves: never more of it above than below.
func _keep_fish_under() -> void:
	var top := -INF
	for i in 5:
		top = maxf(top, _fish.body_point(i / 4.0).y)
	var limit := _surface_y(_fish.global_position) - fish_radius - 4.0
	if top > limit: # eased down, never a jolt
		_fish.global_position.y -= minf(top - limit, ROCK_PUSH_SPEED * get_physics_process_delta_time())

## The point on the fish's body line nearest to p.
func _nearest_on_fish(p: Vector3) -> Vector3:
	var ends: PackedVector3Array = _fish.body_ends()
	return Geometry3D.get_closest_point_to_segment(p, ends[0], ends[1])

## How far p is from the fish's skin (its body line minus its thickness).
func _distance_to_fish(p: Vector3) -> float:
	return maxf(p.distance_to(_nearest_on_fish(p)) - fish_radius, 0.0)

## An arm's coil round the fish: a ring round its body at the arm's station,
## from the side facing the crown round 300 degrees, tip end first.
func _fish_ring(arm: KrakenArm) -> PackedVector3Array:
	# on its real, bent body
	var center: Vector3 = _fish.body_point(arm.fish_station)
	var axis: Vector3 = (_fish.body_point(arm.fish_station + 0.04) - _fish.body_point(arm.fish_station - 0.04)).normalized()
	var toward := arm.root() - center
	toward = (toward - axis * toward.dot(axis))
	toward = toward.normalized() if toward.length() > 0.01 else axis.cross(Vector3.UP).normalized()
	var side := axis.cross(toward)
	var r := fish_radius + 1.0 * _scale
	var turn := 1.0 if arm.index % 2 == 0 else -1.0
	var ring := PackedVector3Array()
	for j in range(13, -1, -1): # tip end first
		var a := turn * deg_to_rad(300.0) * j / 13.0
		ring.append(center + (toward * cos(a) + side * sin(a)) * r)
	return ring

func _release_fish_arms() -> void:
	for arm in _arms:
		if arm.role == KrakenArm.Role.FISH:
			arm.set_role(KrakenArm.Role.RECOIL)

## With a fish in its arms too, its grip on the player is far weaker.
func _fish_grip_bonus() -> float:
	return struggle_with_fish if state == State.FISH and _fish_phase != FishPhase.CHASE else 1.0

## The morning: the fish goes free (its own abort_hunt does the rest).
func _release_fish() -> void:
	if is_instance_valid(_fish) and _fish.is_seized():
		_fish.abort_hunt()
	_fish = null
	_sated = false

## The idle swim of a giant fish (CreatureDirector) never enters these waters:
## a point inside is pushed out past their edge. Only a hunt leads one in.
func keep_out(point: Vector3) -> Vector3:
	if guard_area == null or perch == null:
		return point
	var c := perch.global_position
	var r := _guard_radius() + keep_out_margin
	var d := Vector2(point.x - c.x, point.z - c.z)
	if d.length() >= r:
		return point
	d = (d.normalized() if d.length() > 0.01 else Vector2.RIGHT) * r
	return Vector3(c.x + d.x, point.y, c.z + d.y)

## How far the guard area reaches from the perch, flat (its shapes' outer edge).
func _guard_radius() -> float:
	if _guard_r >= 0.0:
		return _guard_r
	_guard_r = 0.0
	for shape: CollisionShape3D in guard_area.find_children("*", "CollisionShape3D", false, false):
		var s := shape.shape
		var extent := 0.0
		var scale := shape.global_basis.get_scale()
		if s is CylinderShape3D or s is SphereShape3D or s is CapsuleShape3D:
			extent = s.radius * maxf(scale.x, scale.z)
		elif s is BoxShape3D:
			extent = Vector2(s.size.x * scale.x, s.size.z * scale.z).length() * 0.5
		var off := shape.global_position - perch.global_position
		_guard_r = maxf(_guard_r, Vector2(off.x, off.z).length() + extent)
	return _guard_r

## Lost interest: everything lets go, home it goes.
func _give_up() -> void:
	_release_ship_arms()
	if _ship and not _ship_kept:
		_release_ship()
	for arm in _arms:
		if arm.role != KrakenArm.Role.BOAT:
			arm.set_role(KrakenArm.Role.FREE)
	_reach_start = -1.0
	_settle_from = Transform3D()
	_set_state(State.RETURN)

## ---- the prey ----------------------------------------------------------------

## Arms go for the player whenever they are in the water within reach: one
## first, then reinforcements, one every reinforce_delay.
func _update_reaching(delta: float) -> void:
	var prey := _prey_point()
	var can_reach := _prey_reachable()
	var reaching := 0
	for arm in _arms:
		if arm.role == KrakenArm.Role.REACH:
			reaching += 1
			if not can_reach and not _holding:
				arm.set_role(KrakenArm.Role.RECOIL)
				continue
			# The reach is a bend travelling from the base to the tip, easing in
			# and out; behind it the arm is aimed, ahead of it the tip stays rolled.
			arm.tip_target = _clamp_reach(arm, prey)
			arm.reach_front = smoothstep(0.0, reach_time, arm.timer)
			arm.seek_tip = reach_seek * smoothstep(0.7, 1.0, arm.reach_front) # the light tip finishes the reach, easing in
			if arm.tip().distance_to(prey) < grab_radius:
				arm.set_role(KrakenArm.Role.HOLD)
				_coil(arm)
				if not _holding:
					_carrier = arm
					_catch()
				else:
					_play(_grab_sound)
	if not can_reach:
		if not _holding:
			_reach_start = -1.0
		return
	if _reach_start < 0.0:
		if prey.distance_to(global_position) <= reach_range * _scale and _start_reach(prey):
			_reach_start = _time
			_reinforced = 0
	elif _reinforced < (reinforcements_with_ship if state == State.BOAT else reinforcements) and _time - _reach_start >= reinforce_delay * (_reinforced + 1):
		if _start_reach(prey):
			_reinforced += 1

func _start_reach(prey: Vector3) -> bool:
	var best: KrakenArm = null
	var best_d := INF
	for arm in _arms:
		if arm.role != KrakenArm.Role.FREE:
			continue
		var d := arm.points[arm.points.size() / 3].distance_to(prey)
		if _attacking and not _top_arms.has(arm.index):
			d += 1000.0 # the bottom arms are swimming: the top ones reach
		if d < best_d:
			best_d = d
			best = arm
	if best == null:
		return false
	best.set_role(KrakenArm.Role.REACH)
	return true

func _prey_reachable() -> bool:
	if _player_ignored or _cooldown > 0.0 or not is_instance_valid(_player):
		return false
	if _holding:
		return true
	if _player.get(&'captured'): # something else has them
		return false
	if _ship_under_player(): # aboard: it is the ship it goes for
		return false
	return not _player_beyond_leash()

func _catch() -> void:
	_holding = true
	_hold_dir = (_prey_point() - _eye_position() + Vector3.UP * 6.0).normalized() # toward the catch, a little raised
	_hold_start = _time
	_catch_from = _player.global_position
	_hold_blend = 0.0
	_struggle = 0.0
	_player.set_captured(true)
	_play(_grab_sound)
	EventBus.camera_shake_requested.emit(catch_shake)

func _state_hold_time() -> float:
	return _time - _hold_start

## The prey in the coil: swung about, dragged along. Every jump / swim_up
## press loosens the grip a little; the arms win it back all the time, faster
## the more of them hold on. Drowned, there is no more fighting.
func _update_hold(delta: float) -> void:
	var holders := 0
	for arm in _arms:
		if arm.role == KrakenArm.Role.HOLD:
			holders += 1
	if holders == 0 or _carrier == null or _carrier.role != KrakenArm.Role.HOLD:
		_break_free() # never leave the player captured with nothing holding them
		return
	var unconscious: bool = _player.get(&'unconscious')
	if not unconscious and (Input.is_action_just_pressed(&'jump') or Input.is_action_just_pressed(&'swim_up')):
		_struggle += struggle_per_press / sqrt(float(holders)) * _fish_grip_bonus()
		EventBus.camera_shake_requested.emit(struggle_shake)
	_struggle = maxf(_struggle - grip_regain * holders * delta / _fish_grip_bonus(), 0.0)
	if not unconscious:
		EventBus.camera_shake_requested.emit(held_shake) # trapped: a steady tremor through the arm
	if _struggle >= 1.0:
		_break_free()
		return

	var w := TAU / maxf(hold_sway_period, 0.1)
	var sway := global_basis.x * sin(_time * w) + global_basis.y * sin(_time * w * 0.73 + 1.0) * 0.6
	if state == State.BOAT:
		_hold_point = global_transform * (hold_offset_with_ship * _scale) + sway * hold_sway
	else:
		# held out in front of its eyes, along a direction fixed at the catch
		# (not along the gaze: the body turns its eyes onto the prey, and a hold
		# point that turned with it would make it chase its own tail)
		var side := _hold_dir.cross(Vector3.UP)
		side = side.normalized() if side.length() > 0.1 else Vector3.RIGHT
		var lift := side.cross(_hold_dir).normalized()
		var world_sway := side * sin(_time * w) + lift * sin(_time * w * 0.73 + 1.0) * 0.6
		_hold_point = _eye_position() + _hold_dir * gaze_hold_distance * _scale + world_sway * hold_sway
	_hold_point.y = minf(_hold_point.y, _surface_y(_hold_point) - hold_min_depth)
	# The carrier arm swings the prey about; the prey rides in its coil. As
	# they struggle the coil loosens, visibly.
	for arm in _arms:
		if arm.role == KrakenArm.Role.HOLD:
			_coil(arm)
	_hold_blend = minf(_hold_blend + delta / 1.5, 1.0)
	var s := _hold_blend * _hold_blend * (3.0 - 2.0 * _hold_blend)
	var held := _carrier.coil_center() + Vector3.DOWN * 1.0 # the coil round the chest
	held.y = minf(held.y, _surface_y(held) - hold_min_depth)
	_player.global_position = _catch_from.lerp(held, s)

## The tip coils round the held body: tighter when the grip is firm.
func _coil(arm: KrakenArm) -> void:
	arm.curl_from = arm.length - coil_length
	arm.curl_rate = 1.0 / (coil_radius * (1.0 + _struggle * 0.6))

func _break_free() -> void:
	_holding = false
	_carrier = null
	for arm in _arms:
		if arm.role == KrakenArm.Role.HOLD or arm.role == KrakenArm.Role.REACH:
			arm.set_role(KrakenArm.Role.RECOIL)
	_player.set_captured(false)
	var away := (_player.global_position - global_position).normalized()
	if &'velocity' in _player:
		_player.velocity = away * throw_speed
	_cooldown = regrab_cooldown
	_reach_start = -1.0
	_play(_struggle_sound)
	if state == State.BOAT or _ship_kept or _sated:
		_player_ignored = true # busy with the ship: let them go

## Where an arm aims at the player: their chest.
func _prey_point() -> Vector3:
	return _player.global_position + Vector3.UP * 1.0

func _player_beyond_leash() -> bool:
	return _player.global_position.distance_to(perch.global_position) > leash_distance

## The ship the player is standing on or steering, if any.
func _ship_under_player() -> RigidBody3D:
	if _player.has_method(&'ship_aboard'):
		return _player.ship_aboard() as RigidBody3D
	return null

func _throw_player_off() -> void:
	_thrown = true
	if _ship_under_player() == _ship and _player.has_method(&'throw_off'):
		var side := _ship.global_basis.z.normalized() * _ship_roll_sign
		_player.throw_off(side * 7.0 + Vector3.UP * 4.0)

## ---- the ship ----------------------------------------------------------------

## Grip routes down both sides of the hull, alternating, spread along her
## length, laid on her real shape (HullShape) so the arms wrap round her
## instead of through her.
func _assign_ship_arms() -> void:
	for arm in _arms:
		if arm.role == KrakenArm.Role.BOAT:
			return # already done
	var hull := _hull_shape(_ship)
	var free: Array[KrakenArm] = []
	for arm in _arms:
		if arm.role == KrakenArm.Role.FREE or arm.role == KrakenArm.Role.RECOIL:
			free.append(arm)
	# Grip spots placed by hand win: Marker3D nodes named KrakenGrip* on the ship
	# (position along her and side from where it stands, its height = the hook).
	var markers: Array[Vector3] = []
	for node in _ship.find_children("KrakenGrip*", "Node3D", true, false):
		markers.append(_ship.to_local(node.global_position))
	var count := mini(markers.size() if not markers.is_empty() else ship_arms, free.size())
	for i in count:
		var x := lerpf(hull.x_min, hull.x_max, lerpf(0.14, 0.86, float(i) / maxf(count - 1, 1)))
		var side := 0 if i % 2 == 0 else 1
		var hook := NAN
		if not markers.is_empty():
			x = markers[i].x
			side = 0 if markers[i].z >= 0.0 else 1
			hook = markers[i].y
		var path := _hull_path(hull, x, side, hook)
		# the arm whose middle is nearest that side of her takes it
		var world := _ship.to_global(path[path.size() / 2])
		var best := 0
		for j in free.size():
			if free[j].points[free[j].points.size() / 2].distance_to(world) < free[best].points[free[best].points.size() / 2].distance_to(world):
				best = j
		var arm := free[best]
		free.remove_at(best)
		arm.set_role(KrakenArm.Role.BOAT)
		arm.hull_path = path

## The route of one arm onto her, in her local space, tip end first: hooked
## over the top of her rail, then down the outside of the hull hugging its
## curve, out under the keel's edge — where the arm comes up from below.
func _hull_path(hull: HullShape, x: float, side: int, hook := NAN) -> PackedVector3Array:
	var s := 1.0 if side == 0 else -1.0
	var top := hull.rail(x, side) if is_nan(hook) else hook
	var keel := hull.keel(x)
	var w_top := hull.width(x, top - 0.4, side)
	var path := PackedVector3Array([
		Vector3(x, top + 0.5, s * maxf(w_top - 0.6, 0.0)), # the tip, hooked over the top of the rail
		Vector3(x, top + 0.9, s * (w_top + 0.9)), # curling over its outer edge
	])
	# Down her side, draped: never stepping back in under a bulge, so the arm
	# hangs from her widest point the way a heavy arm would, clear of the
	# plating by enough that its natural curve does not cut her bilge.
	var widest := w_top
	var y := top - 0.6
	while y > keel:
		widest = maxf(widest, hull.width(x, y, side))
		path.append(Vector3(x, y, s * (widest + 2.0)))
		y -= 1.0
	path.append(Vector3(x, keel - 1.5, s * (widest + 3.0)))
	path.append(Vector3(x, keel - 4.5, s * (widest + 4.5))) # where it comes up from below
	return path

## Her shape, measured once per ship from her visible meshes.
func _hull_shape(ship: RigidBody3D) -> HullShape:
	var id := ship.get_instance_id()
	if not _hull_shapes.has(id):
		_hull_shapes[id] = HullShape.new(ship, _ship_box())
	return _hull_shapes[id]

## A ship's real outline, for the arms to grip: from every vertex of her
## visible meshes, in her local space (x along her, y up, z across), her
## half-width on each side per 2 m slice of length and 1 m of height, the
## height of her rail on each side (the top of what stands at her outer
## edge, so the cabin in the middle does not count) and her keel. The big
## collider box round her is only the fallback. Measured once; any model.
class HullShape:
	const DX := 2.0
	const DY := 1.0
	var x_min := 0.0
	var x_max := 0.0
	var y_min := 0.0
	var nx := 1
	var ny := 1
	var _width: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()] # per side, [ix * ny + iy], -1 = nothing there
	var _rail: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()] # per side, per slice
	var _keel := PackedFloat32Array() # per slice
	var _box: AABB

	func _init(ship: Node3D, box: AABB) -> void:
		_box = box
		var to_ship := ship.global_transform.affine_inverse()
		var verts := PackedVector3Array()
		for node in ship.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null or not mi.is_visible_in_tree():
				continue # the physics rig's cells and volumes are hidden meshes
			var xf := to_ship * mi.global_transform
			for surface in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(surface)
				for v: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
					verts.append(xf * v)
		var bounds := AABB(box.position, box.size)
		if not verts.is_empty():
			bounds = AABB(verts[0], Vector3.ZERO)
			for v in verts:
				bounds = bounds.expand(v)
		x_min = bounds.position.x
		x_max = bounds.end.x
		y_min = bounds.position.y
		nx = maxi(1, ceili(bounds.size.x / DX))
		ny = maxi(1, ceili(bounds.size.y / DY))
		for side in 2:
			_width[side].resize(nx * ny)
			_width[side].fill(-1.0)
			_rail[side].resize(nx)
			_rail[side].fill(-INF)
		_keel.resize(nx)
		_keel.fill(INF)
		for v in verts:
			var ix := _ix(v.x)
			var iy := clampi(int((v.y - y_min) / DY), 0, ny - 1)
			var side := 0 if v.z >= 0.0 else 1
			_width[side][ix * ny + iy] = maxf(_width[side][ix * ny + iy], absf(v.z))
			_keel[ix] = minf(_keel[ix], v.y)
		# The rail: the highest point standing near her outer edge in each slice.
		var widest: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
		for side in 2:
			widest[side].resize(nx)
			for ix in nx:
				var w := 0.0
				for iy in ny:
					w = maxf(w, _width[side][ix * ny + iy])
				widest[side][ix] = w
		for v in verts:
			var ix := _ix(v.x)
			var side := 0 if v.z >= 0.0 else 1
			if absf(v.z) >= widest[side][ix] * 0.85:
				_rail[side][ix] = maxf(_rail[side][ix], v.y)

	func _ix(x: float) -> int:
		return clampi(int((x - x_min) / DX), 0, nx - 1)

	## Half-width of the hull on a side (0 = +z, 1 = -z) at x and height y:
	## the widest of what was measured there or just above/below.
	func width(x: float, y: float, side: int) -> float:
		var ix := _ix(x)
		var iy := clampi(int((y - y_min) / DY), 0, ny - 1)
		var best := -1.0
		for d in [0, -1, 1, -2, 2]:
			var j: int = iy + d
			if j >= 0 and j < ny:
				best = maxf(best, _width[side][ix * ny + j])
		return best if best >= 0.0 else _box.size.z * 0.5

	func rail(x: float, side: int) -> float:
		var r := _rail[side][_ix(x)]
		return r if r > -INF else _box.end.y

	func keel(x: float) -> float:
		var k := _keel[_ix(x)]
		return k if k < INF else _box.position.y

## Her hull box in her local space (the big collider round the whole vessel).
func _ship_box() -> AABB:
	for shape: CollisionShape3D in _ship.find_children("*", "CollisionShape3D", false, false):
		if shape.shape is BoxShape3D:
			var size: Vector3 = shape.shape.size
			return AABB(shape.position - size * 0.5, size)
	return AABB(Vector3(-20, -4, -6), Vector3(40, 8, 12))

## From here the ship is moved by hand: frozen, kinematic, posed every frame.
func _begin_shake() -> void:
	boat_phase = BoatPhase.SHAKE
	_state_time = 0.0
	_ship.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_ship.freeze = true
	_ship.linear_velocity = Vector3.ZERO
	_ship.angular_velocity = Vector3.ZERO
	_ship_base = _ship.global_transform
	_ship_draft = _ship_base.origin.y - _surface_y(_ship_base.origin)
	_ship_roll = 0.0
	_thrown = false
	_play(_hull_sound)
	EventBus.camera_shake_requested.emit(catch_shake)

## Shaking and rolling: her pose at the grab, riding the waves, rolled about
## her long axis (x) and pulled down by heave meters.
func _pose_ship(heave: float) -> void:
	var origin := _ship_base.origin
	origin.y = _surface_y(origin) + _ship_draft - heave
	var pitch := sin(_time * TAU * shake_frequency * 1.3 + 1.0) * minf(absf(_ship_roll), deg_to_rad(shake_roll.y)) * 0.15
	var basis := _ship_base.basis * Basis(Vector3.RIGHT, _ship_roll) * Basis(Vector3.BACK, pitch)
	_ship.global_transform = Transform3D(basis.orthonormalized(), origin)

## Dragged: she trails the body at the offset she had when the roll finished,
## following softly rather than welded on.
func _follow_with_ship(delta: float) -> void:
	var target := global_transform * _ship_offset
	var k := 1.0 - exp(-0.8 * delta)
	var current := _ship.global_transform
	_ship.global_transform = Transform3D(
		Basis(current.basis.get_rotation_quaternion().slerp(target.basis.get_rotation_quaternion(), k)),
		current.origin.lerp(target.origin, k))

## Home with her: she hangs off the rock in its arms, upside down.
func _carry_kept_ship() -> void:
	if not is_instance_valid(_ship):
		return
	var pose := _perch_pose()
	var out := _perch_out()
	var up := perch.global_basis.y.normalized()
	var side := up.cross(out).normalized()
	var target_origin := pose.origin + (side * kept_ship_offset.x + up * kept_ship_offset.y + out * kept_ship_offset.z) * _scale
	var flipped := Basis(side, up, out).orthonormalized() * Basis(Vector3.RIGHT, PI)
	var k := 1.0 - exp(-0.5 * get_physics_process_delta_time())
	var current := _ship.global_transform
	_ship.global_transform = Transform3D(
		Basis(current.basis.get_rotation_quaternion().slerp(flipped.get_rotation_quaternion(), k)),
		current.origin.lerp(target_origin, k))
	_hold_ship_arms()

## Keep the gripping arms' tips on their hull points as she moves.
func _hold_ship_arms() -> void:
	for arm in _arms:
		if arm.role == KrakenArm.Role.BOAT:
			arm.tip_target = _clamp_reach(arm, _ship.to_global(arm.hull_path[0]))

func _release_ship_arms() -> void:
	for arm in _arms:
		if arm.role == KrakenArm.Role.BOAT:
			arm.set_role(KrakenArm.Role.RECOIL)

## Hand her back to the physics (a new morning, or it gave up before the roll).
func _release_ship() -> void:
	if is_instance_valid(_ship):
		_submerge_ship(false)
		_ship.freeze = false
	_ship = null
	_ship_kept = false

## Under the water her dry interior and calm patch would show as a hole in
## the sea: switched off while she is down there.
func _submerge_ship(under: bool) -> void:
	if under:
		_ship_disabled.clear()
		for node in _ship.find_children("*", "", true, false):
			if (node.is_in_group(&'dry_volume') or node.is_in_group(&'wave_blocker')) and &'enabled' in node and node.enabled:
				node.enabled = false
				_ship_disabled.append(node)
	else:
		for node in _ship_disabled:
			if is_instance_valid(node):
				node.enabled = true
		_ship_disabled.clear()

## ---- arms ----------------------------------------------------------------------

func _update_arms(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var far := cam != null and cam.global_position.distance_to(global_position) > arm_cull_distance
	if far and (state == State.PERCHED or (state == State.FISH and _fish_phase == FishPhase.FEED)):
		return # nobody can see it from there
	for arm in _arms:
		arm.timer += delta
		if arm.role == KrakenArm.Role.RECOIL and arm.timer >= recoil_time:
			arm.set_role(KrakenArm.Role.FREE)
	_loose_timer += delta
	if _loose_timer >= loose_swap_time:
		_pick_loose_arms()
	_set_arm_goals(delta)
	for arm in _arms:
		var response := arm_response
		arm.inertia = 0.0
		match arm.role:
			KrakenArm.Role.REACH: response *= reach_response
			KrakenArm.Role.HOLD: response *= hold_response
			KrakenArm.Role.BOAT: response *= ship_response
			_:
				if not _perched_pose_wanted():
					arm.inertia = arm_drag # loose in open water: it trails
		arm.response = response
		# On a rolling hull the gripping arms must keep up with her or cut
		# through her: the speed caps are lifted for them.
		var on_ship := arm.role == KrakenArm.Role.BOAT
		# the swimming arms of an attack sweep hard on the power stroke
		var swimming := _attacking and arm.role == KrakenArm.Role.FREE and not _top_arms.has(arm.index)
		arm.smooth_passes = 0 if on_ship else 2
		arm.max_joint_speed = deg_to_rad(arm_max_joint_speed) * (5.0 if on_ship else (3.0 if swimming else 1.0))
		arm.max_tip_speed = arm_max_tip_speed * (3.0 if on_ship or swimming else 1.0)
		if swimming:
			response = arm_response * 2.5
			arm.response = response
		# the jet home: one big open-and-snap of all the arms together
		if state == State.RETURN and _settle_from == Transform3D() and arm.role == KrakenArm.Role.FREE and _jet != Jet.GLIDE:
			arm.max_joint_speed = deg_to_rad(arm_max_joint_speed) * 4.0
			arm.max_tip_speed = arm_max_tip_speed * 4.0
			arm.response = arm_response * 3.0
		# a lash at a fish is the one fast thing it does; a coil must keep up with a
		# thrashing body
		if arm.role == KrakenArm.Role.FISH:
			arm.response = arm_response * (2.5 if arm.gripped else 4.0)
			arm.max_joint_speed = deg_to_rad(arm_max_joint_speed) * (4.0 if arm.gripped else 5.0)
			arm.max_tip_speed = arm_max_tip_speed * (3.0 if arm.gripped else 5.0)
			arm.smooth_passes = 0 if arm.gripped else 2
		arm.pin_tip = arm.role == KrakenArm.Role.BOAT and arm.gripped
		arm.simulate(delta)
		if not far:
			arm.apply_to_skeleton()

func _perched_pose_wanted() -> bool:
	return state == State.PERCHED or (state == State.RETURN and _settle_from != Transform3D()) \
		or (state == State.FISH and _fish_phase >= FishPhase.SETTLE)

## Every arm's goal shape for this frame, by its role and the body's state.
func _set_arm_goals(_delta: float) -> void:
	_update_anchor_arms()
	var crown := global_position
	var axis := global_basis.z.normalized() # out of the crown, toward the arms
	var open := _stroke_open()
	var surface_y := _surface_y(crown)
	for arm in _arms:
		var out := arm.root() - crown
		out = (out - axis * out.dot(axis)).normalized()
		var phase := _time * 0.45 + arm.index * 0.8
		match arm.role:
			KrakenArm.Role.REACH:
				arm.goals_reach(arm.tip_target, out)
			KrakenArm.Role.HOLD:
				# the carrier swings the prey to the hold point; the others hug the prey
				var aim := _hold_point if arm == _carrier else _prey_point()
				arm.goals_reach(_clamp_reach(arm, aim), out)
			KrakenArm.Role.BOAT:
				# its route onto her, carried with her; until the tip has hold, the
				# route is shifted to where the tip has got to on its way there
				var xf := _ship.global_transform
				var shift := arm.tip_target - xf * arm.hull_path[0]
				var route := PackedVector3Array()
				for p in arm.hull_path:
					var w := xf * p + shift
					# coming from below, it lies along her only as far as the route
					# keeps going down: rolled over, it just holds her rail
					if route.size() >= 2 and w.y > route[-1].y + 0.5:
						break
					route.append(w)
				arm.goals_path(route)
			KrakenArm.Role.FISH:
				if arm.gripped and is_instance_valid(_fish):
					arm.goals_path(_fish_ring(arm)) # coiled round its body
				else:
					arm.goals_reach(arm.tip_target, out) # the lash
			KrakenArm.Role.RECOIL:
				arm.goals_spread(axis, out, 0.8, 4.0, _time * 1.2 + arm.index, 1.0)
			_:
				if _perched_pose_wanted() and not _loose.has(arm.index):
					_wrap_goals(arm)
				elif _perched_pose_wanted():
					# the restless ones: lifted off the rock, curling slowly
					arm.goals_spread(axis, out, 0.45, 3.0, _time * 0.2 + arm.index * 2.0, 0.8)
				elif state == State.WAKING:
					arm.goals_spread(axis, out, 0.6, 3.0, phase, 0.6)
				elif _anchor_arms.has(arm.index):
					_wrap_goals(arm) # holding on to the rock while it wrestles
				elif state == State.RETURN:
					arm.goals_spread(axis, out, _jet_spread, 1.0, phase, 0.3) # the umbrella: open, shut, trailing
				elif state == State.HUNT and _attacking:
					_attack_goals(arm, crown, open, phase)
				else:
					arm.goals_spread(axis, out, lerpf(0.1, 0.45, open), 2.5 + open * 1.5, phase, 0.35 + open * 0.4)
		if arm.role == KrakenArm.Role.FREE or arm.role == KrakenArm.Role.RECOIL:
			_keep_under_surface(arm, surface_y)

## The attack: reared up, the top arms opened toward the prey like an
## umbrella, the bottom arms trailing behind it and swimming — swung slowly
## forward under the body as the stroke opens, then swept hard back as it
## shuts, when the body surges forward (_stroke_thrust).
func _attack_goals(arm: KrakenArm, crown: Vector3, open: float, phase: float) -> void:
	var to_prey := _prey_point() - crown
	var flat := Vector3(to_prey.x, 0.0, to_prey.z)
	flat = flat.normalized() if flat.length() > 0.1 else -global_basis.z
	var out := arm.root() - crown
	if _top_arms.has(arm.index):
		var axis := to_prey.normalized()
		out = (out - axis * out.dot(axis)).normalized()
		arm.goals_spread(axis, out, lerpf(0.4, 0.65, open), 2.0, phase, 0.5)
	else:
		# recovery (stroke opening): forward and down under the body; power
		# (stroke shutting): straight back, away from the prey
		var sweep := deg_to_rad(lerpf(swim_power_angle, swim_recovery_angle, open))
		var axis := (-flat * cos(sweep) + Vector3.DOWN * sin(sweep)).normalized()
		out = (out - axis * out.dot(axis)).normalized()
		arm.goals_spread(axis, out, 0.15, 1.0, phase, 0.2)

## Loose arms stay in the sea: they spread just under the surface rather than
## rising out of it. Only an arm reaching the prey or gripping a hull breaks it.
func _keep_under_surface(arm: KrakenArm, surface_y: float) -> void:
	for i in arm.goals.size():
		arm.goals[i].y = minf(arm.goals[i].y, surface_y - 1.5)

## While it wrestles a fish, up to fish_anchor_arms of its free arms that can
## reach the rock take hold of it — the nearest first. Kept while still in
## reach (with some slack), so they do not let go and grab again.
func _update_anchor_arms() -> void:
	if state != State.FISH or perch_column_radius <= 0.0 or not _rock_measured:
		_anchor_arms.clear()
		return
	var keep: Array[int] = []
	for arm in _arms:
		if _anchor_arms.has(arm.index) and arm.role == KrakenArm.Role.FREE and _rock_gap(arm.root()) < arm.length * 0.75:
			keep.append(arm.index)
	while keep.size() < fish_anchor_arms:
		var best: KrakenArm = null
		var best_gap := INF
		for arm in _arms:
			if arm.role != KrakenArm.Role.FREE or keep.has(arm.index):
				continue
			var gap := _rock_gap(arm.root())
			if gap < arm.length * 0.6 and gap < best_gap:
				best_gap = gap
				best = arm
		if best == null:
			break
		keep.append(best.index)
	_anchor_arms = keep

## How far a point is from the rock's surface (its measured shape), flat.
func _rock_gap(p: Vector3) -> float:
	var up := perch.global_basis.y.normalized()
	var rel := p - perch.global_position
	var h := rel.dot(up)
	var flat := rel - up * h
	var a := atan2(flat.dot(_rock_e2), flat.dot(_rock_e1))
	return flat.length() - float(_rock_radius.call(h, a))

## Wrapped round the rock: each arm winds its own way, creeping slowly.
func _wrap_goals(arm: KrakenArm) -> void:
	var drift := sin(_time * 0.1 + arm.index * 1.3) * idle_drift
	if perch_column_radius > 0.0:
		var up := perch.global_basis.y.normalized()
		var side := global_basis.x
		var turn := 1.0 if (arm.root() - global_position).dot(side) >= 0.0 else -1.0
		const PITCHES := [-0.25, -0.45, -0.1, -0.6, 0.2, -0.35, -0.15, 0.3]
		var pitch: float = PITCHES[arm.index % PITCHES.size()] + drift
		arm.goals_wrap_column(perch.global_position, up, _rock_e1, _rock_e2, _rock_radius, turn, pitch, -1.25, drift * 0.5)
	else:
		var normal := perch.global_basis.y.normalized()
		var out := arm.root() - global_position
		arm.goals_wrap_plane(perch.global_position, normal, out, (0.6 + 0.3 * sin(arm.index * 2.1)) * (1.0 if arm.index % 2 == 0 else -1.0) + drift)

## ---- the rock -------------------------------------------------------------

## The column's real shape round the perch, found once with rays from outside
## toward its center line (layer 1): ROCK_LEVELS heights x ROCK_ANGLES
## directions. Where a ray finds nothing, perch_column_radius stands in.
## Whatever the user's rock looks like, the arms wind round its surface.
func _measure_rock() -> void:
	_rock_measured = true
	var up := perch.global_basis.y.normalized()
	_rock_e1 = _perch_out()
	_rock_e2 = up.cross(_rock_e1).normalized()
	_rock_grid.resize(ROCK_LEVELS * ROCK_ANGLES)
	var space := get_world_3d().direct_space_state
	var reach := perch_column_radius * 3.0 + 30.0
	for l in ROCK_LEVELS:
		var h := ROCK_BELOW + l * ROCK_STEP
		var axis_point := perch.global_position + up * h
		for k in ROCK_ANGLES:
			var a := TAU * k / ROCK_ANGLES
			var dir := _rock_e1 * cos(a) + _rock_e2 * sin(a)
			var query := PhysicsRayQueryParameters3D.create(axis_point + dir * reach, axis_point, 1)
			var hit := space.intersect_ray(query)
			_rock_grid[l * ROCK_ANGLES + k] = (hit.position - axis_point).dot(dir) if hit else perch_column_radius
	_rock_radius = _rock_radius_at

## The rock's radius at a height along the column (from the perch) and an
## angle round it (from _rock_e1), blended between the measured samples.
func _rock_radius_at(h: float, a: float) -> float:
	var lf := clampf((h - ROCK_BELOW) / ROCK_STEP, 0.0, ROCK_LEVELS - 1.001)
	var af := fposmod(a, TAU) / TAU * ROCK_ANGLES
	var l0 := int(lf)
	var k0 := int(af) % ROCK_ANGLES
	var k1 := (k0 + 1) % ROCK_ANGLES
	var tl := lf - l0
	var ta := af - floorf(af)
	var lo := lerpf(_rock_grid[l0 * ROCK_ANGLES + k0], _rock_grid[l0 * ROCK_ANGLES + k1], ta)
	var hi := lerpf(_rock_grid[(l0 + 1) * ROCK_ANGLES + k0], _rock_grid[(l0 + 1) * ROCK_ANGLES + k1], ta)
	return lerpf(lo, hi, tl)

func _pick_loose_arms() -> void:
	_loose_timer = 0.0
	_loose.clear()
	var start := randi() % maxi(_arms.size(), 1)
	for i in mini(loose_arms, _arms.size()):
		_loose.append((start + i * 3) % _arms.size())

## Keep a pinned tip within the arm's length of its root (a straight arm).
func _clamp_reach(arm: KrakenArm, target: Vector3) -> Vector3:
	var root := arm.root()
	var d := target - root
	var max_len := arm.length * 0.98
	return root + d.limit_length(max_len)

## 0 = arms closed, 1 = open. They open slowly over most of the stroke, then
## snap shut — the push.
func _stroke_open() -> float:
	if _stroke < 0.75:
		return smoothstep(0.0, 0.75, _stroke)
	return 1.0 - smoothstep(0.75, 1.0, _stroke)

## Speed through the stroke: coasting while the arms open, a surge as they shut.
func _stroke_thrust() -> float:
	var push := 0.0
	if _stroke >= 0.75:
		push = sin(PI * (_stroke - 0.75) / 0.25)
	return 0.7 + jet_boost * push

## ---- body movement -------------------------------------------------------------

## Move toward a point, never faster than max_speed (pulsed by the stroke),
## easing in on arrival. face: the direction the arms should point (Vector3),
## null to swim mantle first along the way it is going, or false to leave
## the body's turning to someone else (the look at a held prey).
func _swim_toward(target: Vector3, max_speed: float, face: Variant, delta: float, accel_scale := 1.0) -> void:
	var to := target - global_position
	var dist := to.length()
	var speed := minf(max_speed * _stroke_thrust(), dist * 0.4)
	var desired := to.normalized() * speed if dist > 0.01 else Vector3.ZERO
	_velocity = _velocity.move_toward(desired, acceleration * accel_scale * delta)
	var pos := global_position + _velocity * delta
	pos.y = minf(pos.y, _surface_y(pos) - surface_clearance * _scale)
	pos.y = maxf(pos.y, _floor_height(delta) + floor_clearance * _scale)
	_move_body(pos)

	var crown_dir: Vector3
	if face is Vector3:
		crown_dir = face
	elif face == null and _velocity.length() > 0.4:
		crown_dir = -_velocity.normalized() # mantle first, arms streaming behind
	else:
		return
	_turn_crown_toward(crown_dir, delta)
	_push_body_out(delta) # turning swings the head and mantle: never into rock

## Its eyes sit high on the sides of the head, so it "looks at" something by
## turning the top of its head toward it — both eyes on it. Once it has the
## prey it rolls its whole body round, slowly, pivoting at the head, until
## the prey hangs in front of its eyes (the hold point rides on the gaze, so
## the arm carries the prey into view as it turns). Easing off as it lines up.
func _look_at_prey(delta: float) -> void:
	var eye := _eye_position()
	var eye_local := global_transform.affine_inverse() * eye
	var want := _prey_point() - eye
	if want.length() < 0.5:
		return
	want = want.normalized()
	var gaze := _gaze()
	var angle := gaze.angle_to(want)
	if angle < 0.002:
		return
	var axis := gaze.cross(want)
	if axis.length() < 1e-5:
		axis = global_basis.x
	var step := minf(angle, look_turn_rate * delta * clampf(angle / 0.35, 0.15, 1.0))
	global_basis = (Basis(axis.normalized(), step) * global_basis).orthonormalized()
	global_position = eye - global_basis * eye_local # pivot at the head, not the crown

## Between the eyes, in the world.
func _eye_position() -> Vector3:
	return _skeleton.global_transform * eye_center # eye_center is in the model's own space

## Which way its eyes look, in the world.
func _gaze() -> Vector3:
	return (_skeleton.global_basis * gaze_direction).normalized()

## Turn the body so its arms (+Z) point along dir, at turn_rate at most,
## keeping its back (+Y) as near up as it can.
func _turn_crown_toward(dir: Vector3, delta: float) -> void:
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.95 else global_basis.y
	var desired := Basis.looking_at(-dir, up).get_rotation_quaternion()
	var current := global_basis.get_rotation_quaternion()
	var angle := current.angle_to(desired)
	if angle < 0.0005:
		return
	global_basis = Basis(current.slerp(desired, minf(1.0, turn_rate * delta / angle)))

## ---- helpers -------------------------------------------------------------------

## Its pose on the rock: against the column's side, back to the sea, mantle
## up, arms down the column; or lying on a flat perch, crown to the ground.
func _perch_pose() -> Transform3D:
	var up := perch.global_basis.y.normalized()
	if perch_column_radius > 0.0:
		var out := _perch_out()
		var z := -up
		var x := out.cross(z).normalized()
		return Transform3D(Basis(x, out, z), perch.global_position + out * (float(_rock_radius.call(0.0, 0.0)) + 3.6 * _scale))
	var fwd := -perch.global_basis.z.normalized()
	var z := (-up * 0.8 - fwd * 0.6).normalized() # crown to the ground, mantle tipped back
	var y := (up - z * up.dot(z)).normalized()
	var x := y.cross(z).normalized()
	return Transform3D(Basis(x, y, z), perch.global_position + up * 4.0)

## Out from the rock, toward the side it clings to.
func _perch_out() -> Vector3:
	var up := perch.global_basis.y.normalized()
	if perch_column_radius <= 0.0:
		return up
	var out := perch.global_basis.z
	return (out - up * out.dot(up)).normalized()

func _surface_y(at: Vector3) -> float:
	return _water.get_wave_height(at) if _water else 0.0

## Sea floor under the body, re-checked twice a second (one ray, layer 1).
func _floor_height(delta: float) -> float:
	_floor_check -= delta
	if _floor_check <= 0.0:
		_floor_check = 0.5
		var from := global_position
		var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 400.0, 1)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		_floor_y = hit.position.y if hit else -INF
	return _floor_y

## Is the point inside any of guard_area's shapes?
func _in_guard_area(point: Vector3) -> bool:
	if guard_area == null:
		return false
	for shape: CollisionShape3D in guard_area.find_children("*", "CollisionShape3D", false, false):
		if shape.disabled or shape.shape == null:
			continue
		var p := shape.global_transform.affine_inverse() * point
		var s := shape.shape
		if s is BoxShape3D:
			var h: Vector3 = s.size * 0.5
			if absf(p.x) <= h.x and absf(p.y) <= h.y and absf(p.z) <= h.z:
				return true
		elif s is SphereShape3D:
			if p.length() <= s.radius:
				return true
		elif s is CylinderShape3D:
			if Vector2(p.x, p.z).length() <= s.radius and absf(p.y) <= s.height * 0.5:
				return true
		elif s is CapsuleShape3D:
			var half: float = maxf(s.height * 0.5 - s.radius, 0.0)
			if Vector3(p.x, p.y - clampf(p.y, -half, half), p.z).length() <= s.radius:
				return true
	return false

func _breathe() -> void:
	if _mantle_bone < 0:
		return
	var b := sin(_time * TAU / maxf(breath_period, 0.5)) * breath_amount
	_skeleton.set_bone_pose_scale(_mantle_bone, Vector3(1.0 + b, 1.0 + b * 0.3, 1.0 + b))

## A rumble for the player, only if they are near enough to feel it.
func _shake_near(trauma: float, reach: float) -> void:
	if _player and _player.global_position.distance_to(global_position) < reach:
		EventBus.camera_shake_requested.emit(trauma)

func _play(sound: AudioStreamPlayer3D) -> void:
	if sound and sound.stream:
		sound.play()

func _stop(sound: AudioStreamPlayer3D) -> void:
	if sound:
		sound.stop()
